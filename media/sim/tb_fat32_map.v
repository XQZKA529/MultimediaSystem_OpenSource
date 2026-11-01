`timescale 1ns/1ps
`include "pkg/fat_err_codes.vh"
//=============================================================================
// tb_fat32_map — fat32_ro map walker（S_MAP_* 重定时拆拍后）的行为自检
//
//  背景：wav 提交把 map walker 塞进 fat32_ro 后，布线时序曾出现 213 条
//  setup 违例；重定时把 S_MAP_SELECT/ACC 拆成 SELECT→USE→LBA→ACC 四拍。
//  本 TB 专门覆盖 walker 语义不被拆拍破坏。
//
//  ★ fat32_ro 有单扇区 FAT 缓存，挂载后不失效 —— 改 FAT 链必须重新挂载
//    （本 TB 第一版就栽在这里：改 disk[] 不重挂，DUT 走的还是旧链）。
//    因此每个用例都是「写链 → 重挂 → map」的完整序列。
//
//  覆盖：
//    [1] 碎链 3→5→7（spc=1）：断成 3 条段，各自 nsec=1，末条 last=1
//    [2] 尾部短簇（spc=1）：3→5，size=512+100 → 2 段，末段 ceil(100/512)=1
//    [3] EOC 提前（size 超链长）→ error 7，无段输出
//    [4] 环链 3→5→3 → error 9（Brent 检测）
//    [5] 连续链 3→4→5（spc=2）：合并 1 段 nsec=6
//    [6] 连续后断开 3→4→7（spc=2）：2 段（4+2 扇区）
//=============================================================================
module tb_fat32_map;
reg clk=0,rst=1; always #5 clk=~clk;

wire        blk_req;
wire [31:0] blk_lba;
wire [15:0] blk_count;
reg         blk_grant=0;
reg  [7:0]  blk_data=0;
reg         blk_data_valid=0, blk_end=0, blk_error=0;

reg         mount_start=0;
wire        mount_done, mount_ok;
wire [7:0]  fat_error_code;

reg         map_start=0, map_abort=0;
reg  [31:0] map_first_cluster=0, map_size=0;
wire        map_busy, map_done, map_ok, map_accept;
wire        map_entry_valid, map_entry_last;
wire [31:0] map_entry_lba;
wire [31:0] map_entry_nsec;
wire [7:0]  dbg_fat_state;
wire [31:0] dbg_dir_entry_count;

fat32_ro dut (
    .clk(clk), .rst(rst),
    .blk_req(blk_req), .blk_lba(blk_lba), .blk_count(blk_count),
    .blk_grant(blk_grant), .blk_data(blk_data),
    .blk_data_valid(blk_data_valid), .blk_end(blk_end), .blk_error(blk_error),
    .mount_start(mount_start), .mount_done(mount_done), .mount_ok(mount_ok),
    .fat_error_code(fat_error_code),
    .dir_start(1'b0), .dir_entry_start(), .dir_name_valid(), .dir_name_char(),
    .dir_name_index(), .dir_entry_end(), .dir_entry_name_len(),
    .dir_entry_first_cluster(), .dir_entry_size(), .dir_entry_attr(),
    .dir_entry_is_dir(), .dir_entry_is_lfn(), .dir_done(), .dir_ok(),
    .file_start(1'b0), .file_first_cluster(32'd0), .file_size(32'd0),
    .file_read_limit(32'd0), .file_read_ready(1'b1), .file_abort(1'b0),
    .file_busy(), .file_data(), .file_data_valid(), .file_done(), .file_ok(),
    .map_start(map_start), .map_first_cluster(map_first_cluster),
    .map_size(map_size), .map_abort(map_abort),
    .map_busy(map_busy), .map_accept(map_accept),
    .map_done(map_done), .map_ok(map_ok),
    .map_entry_valid(map_entry_valid), .map_entry_lba(map_entry_lba),
    .map_entry_nsec(map_entry_nsec), .map_entry_last(map_entry_last),
    .dbg_fat_state(dbg_fat_state),
    .dbg_dir_entry_count(dbg_dir_entry_count)
);

// ---- 行为级 SD 块设备（与 tb_fat32_ro 同款）----
reg [7:0] disk [0:131071];
integer busy=0, pos=0, total=0, base=0;
integer errors=0;

task put16; input integer a; input [15:0] v;
  begin disk[a]=v[7:0]; disk[a+1]=v[15:8]; end
endtask
task put32; input integer a; input [31:0] v;
  begin disk[a]=v[7:0]; disk[a+1]=v[15:8]; disk[a+2]=v[23:16]; disk[a+3]=v[31:24]; end
endtask

always @(posedge clk) begin
    blk_grant<=0; blk_data_valid<=0; blk_end<=0;
    if (blk_req && !busy) begin
        busy<=1; blk_grant<=1; base<=blk_lba*512; pos<=0; total<=blk_count*512;
    end else if (busy) begin
        if (pos<total) begin
            blk_data<=disk[base+pos]; blk_data_valid<=1; pos<=pos+1;
        end else begin
            blk_end<=1; busy<=0;
        end
    end
end

// ---- 段表捕获（do_map 里同步清零，无跨用例残留）----
integer spc;                 // 当前几何：每簇扇区数（须在 remount/cl2lba 之前声明）
reg [31:0] seg_lba  [0:15];
reg [31:0]  seg_nsec [0:15];
reg         seg_last [0:15];
integer     seg_cnt,last_cnt;

always @(posedge clk) begin
    if (map_entry_valid && seg_cnt < 15) begin
        seg_lba[seg_cnt]  <= map_entry_lba;
        seg_nsec[seg_cnt] <= map_entry_nsec;
        seg_last[seg_cnt] <= map_entry_last;
    end
    if (map_entry_valid) seg_cnt <= seg_cnt + 1;
    if (map_entry_valid && map_entry_last) last_cnt <= last_cnt + 1;
end

task fat_link; input integer c; input [31:0] next_c;
  begin put32(11*512 + c*4, next_c); end
endtask

// 写 MBR/DBR（spc 可变）并重新挂载（清 FAT 缓存）
task remount; input integer spc_in;
  begin
    disk[510]=8'h55; disk[511]=8'haa; disk[450]=8'h0c;
    put32(454,10); put32(458,1000);
    base=10*512; put16(base+11,512); disk[base+13]=spc_in; put16(base+14,1);
    disk[base+16]=1;
    put32(base+32,1000); put32(base+36,8); put32(base+44,2);
    disk[base+510]=8'h55; disk[base+511]=8'haa;
    // FAT @LBA11：簇 2（根目录占位）= EOC
    put32(11*512+8, 32'h0fffffff);
    spc = spc_in;
    @(posedge clk); mount_start=1; @(posedge clk); mount_start=0;
    wait(mount_done);
    if (!mount_ok) begin
      $display("mount failed(spc=%0d) err=%0d", spc_in, fat_error_code);
      errors=errors+1;
    end
  end
endtask

// 一次 map 并等完成
task do_map; input [31:0] first_c; input [31:0] size;
  begin
    @(posedge clk);
    seg_cnt = 0;last_cnt=0;
    map_first_cluster = first_c; map_size = size; map_start = 1;
    @(posedge clk); map_start = 0;
    wait (map_done);
    repeat(2) @(posedge clk);
  end
endtask

task check; input cond; input [8*64-1:0] msg;
  begin
    if (cond !== 1'b1) begin $display("[FAIL] %0s", msg); errors=errors+1; end
    else        $display("[OK]   %0s", msg);
  end
endtask

integer i,geometry;
function [31:0] cl2lba; input [31:0] c;
  begin cl2lba = (10 + 1 + 8) + (c-2)*spc; end
endfunction

initial begin
    for (i=0;i<131072;i=i+1) disk[i]=0;
    #40 rst=0; #20;

    // ===== 几何 A：spc=1，data 起始 LBA = 19 =====
    remount(1);

    // [1] 碎链 3→5→7：3 段各 nsec=1
    fat_link(3,5); fat_link(5,7); fat_link(7,32'h0fffffff);
    remount(1);
    do_map(32'd3, 32'd1536);
    check(map_ok, "[1] fragmented 3->5->7 map_ok");
    check(seg_cnt==3, "[1] three segments emitted");
    check(seg_lba[0]==cl2lba(3) && seg_nsec[0]==32'd1, "[1] seg0 = cluster3 LBA, nsec=1");
    check(seg_lba[1]==cl2lba(5) && seg_nsec[1]==32'd1, "[1] seg1 = cluster5 LBA, nsec=1");
    check(seg_lba[2]==cl2lba(7) && seg_nsec[2]==32'd1, "[1] seg2 = cluster7 LBA, nsec=1");
    check(seg_last[2]==1'b1, "[1] last segment flagged");

    // [2] 尾部短簇：3→5，size = 512 + 100 → 末段 ceil(100/512)=1
    fat_link(3,5); fat_link(5,32'h0fffffff);
    remount(1);
    do_map(32'd3, 32'd612);
    check(map_ok, "[2] tail-short-cluster map_ok");
    check(seg_cnt==2, "[2] two segments");
    check(seg_lba[0]==cl2lba(3) && seg_nsec[0]==32'd1, "[2] seg0 full cluster");
    check(seg_lba[1]==cl2lba(5) && seg_nsec[1]==32'd1, "[2] seg1 = ceil(100/512)=1 sector");
    check(seg_last[1]==1'b1, "[2] last flagged on tail segment");

    // [3] EOC 提前（size 超链长）→ error 7；run 尚未吐段，无段输出
    fat_link(3,32'h0fffffff);
    remount(1);
    do_map(32'd3, 32'd1024);
    check(!map_ok && fat_error_code==8'd7, "[3] premature EOC rejected with code 7");
    check(seg_cnt==0, "[3] no segments emitted before failure");

    // [4] 环链 3→5→3 → error 9（Brent 检测）
    fat_link(3,5); fat_link(5,3);
    remount(1);
    do_map(32'd3, 32'd8192);
    check(!map_ok && fat_error_code==8'd9, "[4] cycle chain rejected with code 9");

    // ===== 几何 B：spc=2，重新挂载 =====
    fat_link(3,4); fat_link(4,5); fat_link(5,32'h0fffffff);
    remount(2);
    do_map(32'd3, 32'd3072);
    check(map_ok, "[5] contiguous chain map_ok");
    check(seg_cnt==1, "[5] merged into ONE segment");
    check(seg_lba[0]==cl2lba(3) && seg_nsec[0]==32'd6, "[5] seg0 covers 3 clusters = 6 sectors");
    check(seg_last[0]==1'b1, "[5] last flagged");

    // [6] 连续后断开：3→4→7 → 2 段（4+2 扇区）
    fat_link(3,4); fat_link(4,7); fat_link(7,32'h0fffffff);
    remount(2);
    do_map(32'd3, 32'd3072);
    check(map_ok && seg_cnt==2, "[6] run-then-break gives 2 segments");
    check(seg_lba[0]==cl2lba(3) && seg_nsec[0]==32'd4, "[6] seg0 = clusters 3-4 (4 sectors)");
    check(seg_lba[1]==cl2lba(7) && seg_nsec[1]==32'd2, "[6] seg1 = cluster 7 (2 sectors)");
    check(seg_last[1]==1'b1, "[6] seg1 is last");

    // Fragmented map LBAs and a one-byte tail for all legal cluster sizes.
    // A cluster-offset register shared with file/directory operations must
    // still emit the correct independent run descriptors on every remount.
    for (geometry=0;geometry<8;geometry=geometry+1) begin
        fat_link(3,5);fat_link(5,32'h0fffffff);
        remount(1<<geometry);
        do_map(32'd3, (512<<geometry)+1);
        check(map_ok && seg_cnt==2, "[7] all geometries fragmented map");
        check(seg_lba[0]==cl2lba(3) && seg_nsec[0]==spc, "[7] full-cluster segment");
        check(seg_lba[1]==cl2lba(5) && seg_nsec[1]==1 && seg_last[1], "[7] one-byte tail LBA/length/last");
    end

    // A fragmented file that requires more descriptors than the destination
    // table can hold must fail without writing entry 257 or a last flag.
    for(i=0;i<258;i=i+1) fat_link(3+2*i,i==257 ? 32'h0fffffff:5+2*i);
    remount(1);do_map(32'd3,32'd132096);
    check(!map_ok && fat_error_code==`FAT_E_MAP_OVF,"[8] fragmented map table overflow rejected");
    check(seg_cnt==256 && last_cnt==0,"[8] no descriptor written beyond table capacity");

    if (errors==0) $display("*** PASS *** tb_fat32_map fragmented/contiguous/cycle/all geometries/table overflow");
    else           $display("*** FAIL *** errors=%0d", errors);
    #20 $finish;
end

initial begin
    #5_000_000;
    $display("*** TIMEOUT *** state=%0d err=%0d", dbg_fat_state, fat_error_code);
    $finish;
end
endmodule
