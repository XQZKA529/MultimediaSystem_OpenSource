// FAT32 read-only service for a 512-byte SD block stream.
// SPDX-License-Identifier: MIT
//
// Operations are serialized.  The module supports a FAT32 superfloppy or the
// first FAT32 MBR partition, root-directory VFAT/SFN enumeration, and file
// streaming through fragmented cluster chains.  UTF-16 characters outside
// printable ASCII are reported as '?'.
//
// 错误码宏唯一出处：rtl/pkg/fat_err_codes.vh（值与历史版本一一对应）。
`include "../pkg/fat_err_codes.vh"

module fat32_ro #(
    parameter integer FILE_MAX_BURST = 4,
    // 块读挂死看门狗（S_RD_REQ 等 grant / S_RD_WAIT 等数据）。
    // ★ 2026-09-28 由 28'd100_000_000（100 MHz 下 1 s）收到 28'd5_000_000（50 ms）。
    //   取值口径：最长的一记突发 = 64 扇区 @25 MHz ≈ 2.6 ms，加上 CMD18/CMD12
    //   与卡侧访问时间，留 18 倍余量 ⇒ 50 ms 既不会误判健康读，又把"卡住"的代价
    //   从**秒级**压到 50 ms。原来那 1 s 是"整张图重读"放大链里最贵的一环：
    //   fat32_ro 超时 → FAT_E_TIMEOUT → fat_bmp_controller 整张图重来（LOAD_RETRY_MAX=2）。
    //   为什么 sdio_core 的 DATA_TIMEOUT=60 ms 只管不住这一段：它只覆盖"发出读命令后
    //   等数据起始令牌"，**不覆盖"等 SD 通道授权（S_RD_REQ 里的 blk_grant）"**，
    //   而后者一旦仲裁卡住就完全没有其它时限。
    //   注意：本参数被 sim/tb_fat32_timeout.v 显式覆写成 200 来造超时场景，
    //   改这里的默认值不影响该 TB（它按自己的 TMO 断言）。
    parameter [27:0] IO_TIMEOUT_CYCLES = 28'd5_000_000
) (
    input  wire        clk,
    input  wire        rst,

    output reg         blk_req,
    output reg [31:0]  blk_lba,
    output reg [15:0]  blk_count,
    input  wire        blk_grant,
    input  wire [7:0]  blk_data,
    input  wire        blk_data_valid,
    input  wire        blk_end,
    input  wire        blk_error,

    input  wire        mount_start,
    output reg         mount_done,
    output reg         mount_ok,
    output reg [7:0]   fat_error_code,

    input  wire        dir_start,
    output reg         dir_entry_start,
    output reg         dir_name_valid,
    output reg [7:0]   dir_name_char,
    output reg [7:0]   dir_name_index,
    output reg         dir_entry_end,
    output reg [7:0]   dir_entry_name_len,
    output reg [31:0]  dir_entry_first_cluster,
    output reg [31:0]  dir_entry_size,
    output reg [7:0]   dir_entry_attr,
    output reg         dir_entry_is_dir,
    output reg         dir_entry_is_lfn,
    output reg         dir_done,
    output reg         dir_ok,

    input  wire        file_start,
    input  wire [31:0] file_first_cluster,
    input  wire [31:0] file_size,
    input  wire [31:0] file_read_limit,
    // Sampled only between bursts.  An SD data burst itself is never paused.
    input  wire        file_read_ready,
    input  wire        file_abort,
    output wire        file_busy,
    output wire operation_idle,

    // ---- 簇链→LBA 段表（map 模式：只走 FAT，不读文件数据）----
    input  wire        map_start,
    input  wire [31:0] map_first_cluster,
    input  wire [31:0] map_size,
    input  wire        map_abort,
    output wire        map_busy,
    output reg         map_accept,       // 1拍：walker 实际启动 map（map_wr_clear 用）
    output reg         map_done,
    output reg         map_ok,
    output reg         map_entry_valid,
    output reg  [31:0] map_entry_lba,
    output reg  [31:0] map_entry_nsec,
    output reg         map_entry_last,

    output reg [7:0]   file_data,
    output reg         file_data_valid,
    output reg         file_done,
    output reg         file_ok,

    output wire [7:0]  dbg_fat_state,
    output reg [31:0]  dbg_dir_entry_count
);

reg [7:0] blk_data_i;
reg blk_data_valid_i,blk_end_i,blk_error_i;
always @(posedge clk or posedge rst) begin
    if(rst) begin blk_data_i<=0;blk_data_valid_i<=0;blk_end_i<=0;blk_error_i<=0;end
    else begin blk_data_i<=blk_data;blk_data_valid_i<=blk_data_valid;blk_end_i<=blk_end;blk_error_i<=blk_error;end
end

localparam S_IDLE          = 8'd0;
localparam S_RD_REQ        = 8'd1;
localparam S_RD_WAIT       = 8'd2;
localparam S_MOUNT_SECTOR0 = 8'd3;
localparam S_MOUNT_DBR     = 8'd4;
localparam S_MOUNT_GEOM1   = 8'd5;
localparam S_MOUNT_GEOM2   = 8'd6;
localparam S_MOUNT_GEOM3   = 8'd7;
localparam S_MOUNT_MBR     = 8'd8;
localparam S_MOUNT_MBR_CHK = 8'd9;
localparam S_DIR_READ      = 8'd32;
localparam S_DIR_ENTRY     = 8'd33;
localparam S_LFN_CHAR      = 8'd34;
localparam S_SFN_CSUM      = 8'd35;
localparam S_SFN_BUILD     = 8'd36;
localparam S_EMIT_START    = 8'd37;
localparam S_EMIT_NAME     = 8'd38;
localparam S_EMIT_END      = 8'd39;
localparam S_EMIT_ADDR     = 8'd49;   // name_ram 同步读：给地址
localparam S_EMIT_WAIT     = 8'd50;   // name_ram 同步读：等数据出口
localparam S_DIR_ADVANCE   = 8'd40;
localparam S_DIR_LOAD_WAIT = 8'd41;
localparam S_FAT_REQ       = 8'd64;
localparam S_FAT_EVAL      = 8'd65;
localparam S_FAT_WAIT      = 8'd66;
localparam S_DIR_LOAD      = 8'd42;
localparam S_DIR_DECODE    = 8'd43;
localparam S_LFN_WRITE     = 8'd44;
localparam S_FILE_PREP1    = 8'd67;
localparam S_FILE_PREP2    = 8'd68;
localparam S_FILE_PREP3    = 8'd69;
localparam S_MOUNT_GEOM4   = 8'd10;
localparam S_FILE_READ     = 8'd70;
localparam S_FILE_AFTER    = 8'd71;
localparam S_MOUNT_GEOM5   = 8'd11;
localparam S_DIR_LBA       = 8'd45;
localparam S_FILE_LBA      = 8'd72;
localparam S_SFN_CSUM_EVAL = 8'd46;
localparam S_MOUNT_VALIDATE1= 8'd12;
localparam S_MOUNT_VALIDATE2= 8'd13;
localparam S_FAT_CHECK      = 8'd73;
localparam S_SFN_WRITE      = 8'd47;
localparam S_SFN_PREP       = 8'd48;
localparam S_FAT_REQ_READY  = 8'd74;
localparam S_FILE_SELECT    = 8'd75;
localparam S_FILE_CHECK     = 8'd76;
localparam S_FILE_ISSUE     = 8'd77;
localparam S_MOUNT_GEOM3_CHECK = 8'd17;
localparam S_FAIL           = 8'd16;   // 错误收尾拍（见 fail_operation 注释）

localparam FAT_FOR_DIR  = 1'b0;
localparam FAT_FOR_FILE = 1'b1;
localparam OP_MOUNT = 2'd0;
localparam OP_DIR   = 2'd1;
localparam OP_FILE  = 2'd2;
localparam OP_MAP   = 2'd3;
localparam S_MAP_SELECT = 8'd96;
localparam S_MAP_ACC    = 8'd97;
localparam S_MAP_EMIT   = 8'd98;
localparam S_MAP_FAT    = 8'd99;
localparam S_MAP_FAT_WAIT = 8'd100;
localparam S_MAP_FAT_GET  = 8'd101;
localparam S_MAP_FAT_CHK  = 8'd102;
localparam S_MAP_DONE     = 8'd103;
localparam S_MAP_FAT_REQ  = 8'd104;
localparam S_MAP_LBA      = 8'd105;   // 算 (map_cluster-2)<<shift（移位单独一拍）
localparam S_MAP_USE      = 8'd106;   // 算本簇 map_use_bytes/nsec（从 S_MAP_SELECT 拆出）
localparam S_MOUNT_ISFS   = 8'd14;   // superfloppy/MBR 判定拆拍
localparam S_MAP_LBA2     = 8'd107;   // 算 data_lba+map_cluster_off（加法单独一拍）
localparam S_MOUNT_GEOM4B = 8'd15;   // GEOM5 判定用的 +1/<<2/<<9 预计算
localparam S_MOUNT_GEOM4C = 8'd18;   // GEOM5 判定第二轮（x4 与 fat_bytes 比较）
localparam S_MOUNT_GEOM4D = 8'd19;   // GEOM5 判定第三轮（使用已稳定的 cluster_x4）
localparam S_MOUNT_GEOM4E = 8'd20;   // GEOM5 判定第四轮（使用流水化后的 x4）
localparam RD_MOUNT  = 2'd0;
localparam RD_FILE   = 2'd1;
localparam RD_FAT    = 2'd2;
localparam RD_DIR    = 2'd3;

// Compact private control codes; legacy numeric diagnostics remain unchanged.
localparam S_FAT_LATCH=8'd120,S_MAP_FAT_LATCH=8'd121;
reg [6:0] control_state,rd_return_encoded;
reg [7:0] state;
// Keep the legacy diagnostic alias used by debug ports and invariant benches.
wire [6:0] state_encoded=state[6:0];
always @* begin
 case(control_state)
  7'd0:state=8'd0;
  7'd1:state=8'd1;
  7'd2:state=8'd2;
  7'd3:state=8'd3;
  7'd4:state=8'd4;
  7'd5:state=8'd5;
  7'd6:state=8'd6;
  7'd7:state=8'd7;
  7'd8:state=8'd8;
  7'd9:state=8'd9;
  7'd32:state=8'd10;
  7'd33:state=8'd11;
  7'd34:state=8'd12;
  7'd35:state=8'd13;
  7'd36:state=8'd14;
  7'd37:state=8'd15;
  7'd38:state=8'd16;
  7'd39:state=8'd17;
  7'd40:state=8'd18;
  7'd41:state=8'd19;
  7'd64:state=8'd20;
  7'd65:state=8'd21;
  7'd66:state=8'd22;
  7'd42:state=8'd23;
  7'd43:state=8'd24;
  7'd44:state=8'd25;
  7'd67:state=8'd26;
  7'd68:state=8'd27;
  7'd69:state=8'd28;
  7'd10:state=8'd29;
  7'd70:state=8'd30;
  7'd71:state=8'd31;
  7'd11:state=8'd32;
  7'd45:state=8'd33;
  7'd72:state=8'd34;
  7'd46:state=8'd35;
  7'd12:state=8'd36;
  7'd13:state=8'd37;
  7'd73:state=8'd38;
  7'd47:state=8'd39;
  7'd48:state=8'd40;
  7'd74:state=8'd41;
  7'd75:state=8'd42;
  7'd76:state=8'd43;
  7'd77:state=8'd44;
  7'd96:state=8'd45;
  7'd97:state=8'd46;
  7'd98:state=8'd47;
  7'd99:state=8'd48;
  7'd100:state=8'd49;
  7'd101:state=8'd50;
  7'd102:state=8'd51;
  7'd103:state=8'd52;
  7'd104:state=8'd53;
  7'd105:state=8'd54;
  7'd106:state=8'd55;
  7'd14:state=8'd56;
  7'd107:state=8'd57;
  7'd15:state=8'd58;
  7'd16:state=8'd59;
  7'd49:state=8'd60;
  7'd50:state=8'd61;
  7'd17:state=8'd62;
  7'd18:state=8'd63;
  7'd51:state=8'd64;
  7'd52:state=8'd65;
  7'd53:state=8'd66;
  7'd54:state=8'd67;
  7'd55:state=8'd68;
  7'd56:state=8'd69;
  7'd57:state=8'd70;
  7'd58:state=8'd71;
  7'd19:state=8'd72;
  7'd20:state=8'd73;
  7'd120:state=8'd21;
  7'd121:state=8'd50;
  default:state=8'hff;
 endcase
end

reg [1:0] active_op;
reg [1:0] rd_kind;
reg [9:0] rd_index;
reg [$clog2(IO_TIMEOUT_CYCLES+1)-1:0] io_timeout;
// 超时判定预寄存：原「io_timeout>=IO_TIMEOUT_CYCLES-1」的 28 位比较在
// S_RD_REQ/S_RD_WAIT 里直达 fail_operation 的 fat_error_code/done CE
// （布线后 -0.107ns，net 占 62%）。改为在计数拍算出「下一拍到期」，
// 检查拍只看寄存器位（代价：总等待少 1 拍，1 秒量级无影响）。
reg        io_timeout_last;
// The request/wait counter stops when the registered last flag is set.
// Before the counter can wrap, (count+1>=N-1) is exactly count>=N-2.
// Preserve the original N=0 (disabled) and N=1/2 startup behavior as well.
wire io_timeout_next_last=(IO_TIMEOUT_CYCLES==0) ? 1'b0:
    (IO_TIMEOUT_CYCLES<=2) ? 1'b1:(io_timeout>=IO_TIMEOUT_CYCLES-2);

// 错误收尾拍（S_FAIL）锁存的错误码（见 fail_operation 注释）
reg [7:0]  fail_code_r;
reg [7:0] sector_buf [0:511] /* fehdl force_ram=1, ram_style="bram" */;
reg [8:0] sector_addr;
reg [7:0] sector_q;
// Directory parsing retains ownership of sector_buf for the entire entry.
// Only metadata needed concurrently is captured; names use its synchronous port.
// Assemble metadata directly into the output bank before entry_start. It stays
// unchanged from entry_start through entry_end, including gaps between names.
reg [7:0] entry_first,entry_ntres,entry_checksum,lfn_low;
wire [7:0] lfn_base_table,lfn_length_table;
reg entry_ext_nonblank;
localparam S_LFN_WAIT1=8'd51,S_LFN_WAIT2=8'd52,S_LFN_WAIT3=8'd53,S_LFN_WAIT4=8'd54,
           S_CSUM_WAIT1=8'd55,S_CSUM_WAIT2=8'd56,S_BUILD_WAIT1=8'd57,S_BUILD_WAIT2=8'd58;
reg [4:0] entry_load_count;

reg geom3_bad,mount_range_bad,file_has_data,dir_more_sectors;
reg boot_capture,walk_valid,map_first_valid;
reg geom4_write,geom4b_write;

reg [6:0] fat_addr;
wire [31:0] fat_q;
// Isolate the native cache's clock-to-Q from classification/comparison logic.
// One internal lookup cycle is added; payload order and the SD/link handshakes
// remain unchanged. Cooperative cancellation still precedes all case bodies.
reg [27:0] fat_link_data;
always @(posedge clk or posedge rst)
    if(rst) fat_link_data<=0;
    else if((control_state==S_FAT_LATCH) || (control_state==S_MAP_FAT_LATCH))
        fat_link_data<=fat_q[27:0];
reg [23:0] fat_assemble;
// 名字缓冲：原实现只有「组合读」(S_EMIT_NAME 里 name_ram[emit_pos] 同拍出字符)，
// 综合器无法推断 BRAM ⇒ 摊成 **2048 个触发器**（256×8），是 fat32_ro 里
// 最大的一块软面积（2026-09-26 面积复核：fat32_ro 3599 LUT / 2884 FF）。
// 改为同步读（单写口 + 单读口，标准 SDP）并显式 force_ram ⇒ 进 BRAM，
// 代价是每个字符多 2 拍（S_EMIT_ADDR / S_EMIT_WAIT），只在目录枚举时发生。
reg [7:0] name_ram [0:255] /* fehdl force_ram=1, ram_style="bram" */;
reg [7:0] name_rd_addr;
reg [7:0] name_q;
reg name_write;
reg [7:0] name_write_addr,name_write_data;
reg fat_cache_valid;
reg [31:0] fat_cache_lba;

reg [31:0] partition_lba,partition_sectors,root_cluster;wire [31:0] fat_lba,data_lba,max_cluster;
reg [7:0] sectors_per_cluster;
// Valid FAT32 clusters have 1..128 sectors, so the datapath shifts by 0..7.
// Keep invalid geometry in a separate flag rather than a wide shift operand.
reg [2:0] cluster_shift;
reg cluster_shift_bad;
reg [31:0] total_sectors,fat_sectors;
reg [15:0] reserved_sectors;
reg [7:0] num_fats;

// One working context belongs to active_op. A queued map request has its
// separate map_pend_* storage and may take ownership only from S_IDLE.
reg [31:0] walk_cluster,walk_remaining;
reg [23:0] walk_hops, walk_hops_next;
wire [31:0] dir_cluster=walk_cluster;
wire [31:0] file_cluster=walk_cluster;
wire [31:0] map_cluster=walk_cluster;
wire [31:0] fat_query_cluster=walk_cluster;
wire [31:0] file_remaining=walk_remaining;
wire [31:0] map_remaining=walk_remaining;
wire [23:0] file_hops=walk_hops;
wire [19:0] map_hops=walk_hops[19:0];
wire [23:0] file_hops_next=walk_hops_next;
wire [19:0] map_hops_next=walk_hops_next[19:0];
reg [7:0] dir_sector;
reg [8:0] entry_off;
reg [7:0] lfn_expected, lfn_checksum, lfn_len, lfn_ord;
reg lfn_active, lfn_valid;
reg [3:0] lfn_char_no;
reg [7:0] lfn_base;
reg [15:0] lfn_char_value;
reg [7:0] lfn_write_index;
reg [3:0] sfn_pos, sfn_next_pos;
reg [7:0] sfn_len, sfn_checksum, sfn_ntres;
reg [7:0] sfn_raw_char, sfn_build_char;
reg sfn_build_write, sfn_build_last, sfn_build_lower, sfn_build_extmark;
reg [7:0] emit_pos;
// S_EMIT_NAME 的「emit_pos+1 >= dir_entry_name_len」比较锥曾直达 fat_bmp_controller
// 的 o_wav_entry_size.ce / file_browser.ext_play_cluster（布线后 -0.186ns / -0.131ns）。
// 把加法拆到前一级（S_EMIT_ADDR 拍，emit_pos 本就稳定）寄存，S_EMIT_NAME 只看
// 「预加值 vs 长度」的纯比较。emit_pos_next 相对 emit_pos 早一拍稳定，
// 但 S_EMIT_NAME 用到的正是"最后一次加完"的那个值，语义不变。
reg [7:0]  emit_pos_p1;
reg        emit_last;
always @(posedge clk or posedge rst) begin
    if (rst) begin emit_pos_p1<=8'd0; emit_last<=1'b0; end
    else begin
        emit_pos_p1 <= emit_pos + 8'd1;
        emit_last   <= (emit_pos + 8'd1) >= dir_entry_name_len;
    end
end
reg [31:0] dir_hops;
reg        mbr_found;

reg boot_sig0_ok, boot_sig1_ok, bpb_root_entries_nonzero, bpb_fat16_nonzero;
reg [7:0] bpb_spc;
reg bpb_bps_512;
reg [15:0] bpb_tot16;


reg fat_context;
reg [31:0] fat_req_lba;
// fat_addr and the cache contents remain stable through the following CHECK.
wire [31:0] fat_next_cluster={4'd0,fat_link_data[27:0]};
// FAT32 file <= 0xffffffff bytes; >=512 bytes/cluster => <=2^23 hops.
reg [23:0] file_hop_limit;
// +1 results pre-registered in S_FAT_EVAL so S_FAT_CHECK only compares;
// the fused add+compare shared one 100 MHz cycle and left no setup slack.
reg [23:0] cycle_lam_next;
reg [31:0] captured_file_size,captured_read_limit;
// File and map walkers are mutually exclusive; share their Brent state.
// Initial file/map clusters are validated before comparing this bank;
// subsequent FAT links have already been masked to 28 bits.
reg [27:0] cycle_tortoise;
reg [23:0] cycle_power, cycle_lam;
reg [7:0] file_cluster_sector;
reg [7:0] file_read_sectors;
reg       file_abort_pending;
// file 路径判定预寄存（S_FAT_EVAL 拍落地，S_FAT_CHECK 只看寄存器 ——
// 与 map 路径 E3 同款收口：原先 EOC/valid/cycle 三棵 32 位比较树在
// S_FAT_CHECK 一拍里直出，直达 fail_operation / state 次态 mux）：
reg        fat_next_eoc, fat_next_valid, fat_next_cycle;
reg        cycle_lam_eq_power;          // cycle_lam_next==cycle_power（Brent 翻倍点）
reg        file_hop_high_gt,file_hop_high_eq;
reg        dir_hops_max;                // dir_hops>=max_cluster（DIR 上下文）
reg        fat_file_rem_zero;           // file_remaining==0（FAT 走查期间稳定）
// file_last_in_cluster：S_FILE_ISSUE 拍算好，S_FILE_AFTER 不再做
// 「8 位加+比较」组合（该锥曾直达 file_cluster_sector.ce / state mux）：
reg        file_last_in_cluster;

reg [31:0] tmp32a,tmp32b,data_sectors;
wire [31:0] cluster_count;
reg [31:0] fat_area_sectors,data_start_offset,cluster_lba_offset;
reg [23:0] file_sector_count;
reg [15:0] tmp16;
reg [7:0] tmp8;

reg [31:0] map_run_lba;
reg [23:0] map_run_nsec;
reg [19:0] map_hop_limit; // fixed 1,000,000-hop guard
reg        map_have_run;
reg        map_abort_pending;
reg [31:0] map_use_bytes;
reg [7:0] map_use_nsec; // one cluster, 1..128 sectors
reg [31:0] map_cluster_prev;
reg        map_prev_full;
// bug3: 1-deep pending map request (map_start while busy is latched, not dropped)
reg        map_pending;
wire [31:0] map_pend_cluster,map_pend_size;
// bug4: segment counter — overflow past MAP_DEPTH is an error (C1)
reg [8:0]  map_seg_count;
localparam [8:0] MAP_DEPTH_C = 9'd256;

// ---- map/挂载 重定时寄存器（布线后 100 MHz setup 违例的收口）----
// 挂载期一次性预计算，走表时不再现场做「零扩展+变移位」：
reg [31:0] bytes_per_cluster;       // sectors_per_cluster << 9
reg [15:0] spc_nsec;                // {8'd0, sectors_per_cluster}
// S_MAP_ACC 只做寄存器对寄存器比较，prev+1 预先加好存起来：
// A validated map cluster is below 0x0ffffff0; its successor fits 28 bits.
reg [27:0] map_cluster_prev_p1;
// Compare while computing the LBA, before the run-length update's CE mux.
reg map_acc_write,map_acc_merge,map_cluster_matches_prev;
// 当前簇的起始 LBA；拆成 S_MAP_LBA（移位）+ S_MAP_LBA2（加法）两拍，
// 对齐 file 路径 S_FILE_LBA→S_FILE_ISSUE 的既有分拍模式：
reg [31:0] map_cur_lba;          // 当前簇起始 LBA（S_MAP_LBA2 的结果）
// Directory, file and map operations are serialized by the service FSM.
// Select the operand before shifting and reuse the offset register so that
// each operation does not instantiate its own 32-bit subtractor/shifter.
wire [31:0] lba_cluster_offset=(walk_cluster-32'd2)<<cluster_shift;
// The operation is serialized: retain the selected numerator in a register
// before the shared barrel shifter, rather than selecting from the FSM here.
wire [23:0] file_hop_rounded=file_sector_count+{16'd0,sectors_per_cluster}-24'd1;
wire [31:0] geometry_clusters=data_sectors>>cluster_shift;
assign cluster_count=geometry_clusters;
// 挂载扇区 0 的判定拆拍（寄存比较结果，再进主状态 mux）：
reg        mount_sig_bad, mount_fs_cand;
// GEOM5 判定锥预计算（原 cluster_count→dir_ok 布线后 -0.324ns）：
// max_cluster is the same mount working result; it is valid only after mount_ok.
//     // cluster_count + 1
reg [31:0] cluster_x4;           // (cluster_count + 2) << 2
reg [31:0] fat_bytes;            // fat_sectors << 9
// GEOM5 四项判定预寄存（原 root_cluster>max_cluster 比较锥直达
// max_cluster.ce / mount_done，布线后 -0.155ns/-0.137ns）：GEOM4B 拍算好
// 单比特结果，GEOM5 只看寄存器。
reg        geom5_bad;
// Compare two 16-bit halves while the future maximum is captured in 4C.
// GEOM4D consumes their lexicographic result without a wide compare tree.
reg root_hi_gt,root_hi_eq,root_lo_gt;
reg fat_hi_gt,fat_hi_eq,fat_lo_gt;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        root_hi_gt<=0;root_hi_eq<=0;root_lo_gt<=0;
        fat_hi_gt<=0;fat_hi_eq<=0;fat_lo_gt<=0;
    end else begin
        if((control_state==S_MOUNT_GEOM4C)) begin
            root_hi_gt<=root_cluster[31:16]>cluster_x4[31:16];
            root_hi_eq<=root_cluster[31:16]==cluster_x4[31:16];
            root_lo_gt<=root_cluster[15:0]>cluster_x4[15:0];
        end
        if((control_state==S_MOUNT_GEOM4E)) begin
            fat_hi_gt<=cluster_x4[31:16]>fat_bytes[31:16];
            fat_hi_eq<=cluster_x4[31:16]==fat_bytes[31:16];
            fat_lo_gt<=cluster_x4[15:0]>fat_bytes[15:0];
        end
    end
end
// map 走表 FAT 下一簇预判定（E3）：S_MAP_FAT_GET 拍算好，S_MAP_FAT_CHK 只看寄存器
localparam [1:0] MAP_NEXT_VALID   = 2'd0;
localparam [1:0] MAP_NEXT_EOC     = 2'd1;
localparam [1:0] MAP_NEXT_INVALID = 2'd2;
localparam [1:0] MAP_NEXT_CYCLE   = 2'd3;
reg [1:0]  map_next_result;
// map 走表 cycle 末尾判定与 remaining 归零判定预寄存：
//   map_cycle_last —— S_MAP_FAT_WAIT 拍算好（lam/power 只在 CHK 变），
//                     S_MAP_FAT_CHK 不再做「32 位减+比较」；
//   map_rem_zero   —— S_MAP_ACC 拍用「map_remaining==map_use_bytes」等价
//                     判定（减法结果下拍才可见，等值比较本拍即可），
//                     S_MAP_SELECT/S_MAP_EMIT 不再做 32 位归零比较
//                     （map_remaining→state 次态曾是布线后最差路径之一）。
reg        map_cycle_last;
reg        map_rem_zero;

assign dbg_fat_state = state;
// file_busy / map_busy 打一拍再出模块：原来它们是 state 的组合函数，直接
// 扇出到 file_browser / fat_wav_controller 的 FSM 使能锥，布线后形成
// fat32_ro→file_browser→fat32_ro→lba_stream1 的跨模块长组合路径。
// 消费者全部是「等空闲」的电平语义，晚一拍无害。
reg file_busy_r, map_busy_r;
reg dir_start_i,file_abort_i;
assign operation_idle=((control_state==S_IDLE)) && !map_pending && !dir_start_i;
always @(posedge clk or posedge rst) begin
    if(rst) begin dir_start_i<=0;file_abort_i<=0;end
    else begin dir_start_i<=dir_start;file_abort_i<=file_abort;end
end
// Request pulses stay local to the service FSM. The one-cycle admission
// pipeline removes cross-module directory/abort decode from its result mux.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        file_busy_r <= 1'b0;
        map_busy_r  <= 1'b0;
    end else begin
        file_busy_r <= (active_op == OP_FILE) && (!((control_state==S_IDLE)));
        map_busy_r  <= map_pending || ((active_op == OP_MAP) && (!((control_state==S_IDLE))));
    end
end
assign file_busy = file_busy_r;
assign map_busy  = map_busy_r;

function [4:0] lfn_offset;
 input [3:0] n;
 begin case(n)
  0:lfn_offset=1;1:lfn_offset=3;2:lfn_offset=5;3:lfn_offset=7;4:lfn_offset=9;
  5:lfn_offset=14;6:lfn_offset=16;7:lfn_offset=18;8:lfn_offset=20;9:lfn_offset=22;
  10:lfn_offset=24;11:lfn_offset=28;default:lfn_offset=30;
 endcase end
endfunction
function [7:0] spc_to_shift;
    input [7:0] spc;
    begin
        case (spc)
          8'd1:spc_to_shift=0; 8'd2:spc_to_shift=1; 8'd4:spc_to_shift=2;
          8'd8:spc_to_shift=3; 8'd16:spc_to_shift=4; 8'd32:spc_to_shift=5;
          8'd64:spc_to_shift=6; 8'd128:spc_to_shift=7;
          default:spc_to_shift=8'hff;
        endcase
    end
endfunction
function is_fat32_type;
    input [7:0] t;
    begin is_fat32_type=(t==8'h0b)||(t==8'h0c)||(t==8'h1b)||(t==8'h1c); end
endfunction

function [7:0] lower_ascii;
    input [7:0] c;
    begin lower_ascii=((c>="A")&&(c<="Z")) ? c+8'd32 : c; end
endfunction
function valid_data_cluster;
    input [31:0] c;
    begin valid_data_cluster=(c>=2)&&(c<=max_cluster)&&(c<32'h0ffffff0); end
endfunction

task start_buffer_read;
    input [31:0] lba;
    input [15:0] count;
    input [7:0] ret;
    input [1:0] kind;
    begin
        blk_lba<=lba; blk_count<=count; rd_return_encoded<=ret[6:0]; rd_kind<=kind;
        rd_index<=0; io_timeout<=0; io_timeout_last<=1'b0; control_state<=S_RD_REQ;
        if (kind==RD_MOUNT) begin
            bpb_root_entries_nonzero<=0;
            bpb_fat16_nonzero<=0;
        end
    end
endtask

// 错误收尾：判定拍只登记（fail_code_r / control_state<=S_FAIL），下一拍由 S_FAIL
// 统一落「fat_error_code + 对应 op 的 done/ok 位」。
//
// 为什么拆这一拍（2026-09-26 sd 域时序收口）：
//   原先本 task 在同一拍里做 5 件事（写错误码 + 按 active_op 四选一的
//   done/ok + 回 IDLE）。它有 25 个调用点，于是 fat_error_code / *_done
//   的 CE 是一棵「25 个状态×条件的 OR 树」，布线后是 sd 域最深的一条
//   （seed_15 的唯一违规：state_b[2] → fat_error_code[2].a[0]，-0.482ns，
//   cell 3.4ns / net 6.8ns）。拆拍后 CE 退化成 ((control_state[S_FAIL])) 的单状态
//   译码；错误路径多 1 拍（10 ns）对"播放停止/报错"这类语义无影响。
//   注：几处旁路点（S_IDLE 的 map 队满/abort 拒绝、dir_start 未挂载、
//   file_abort 即时中止、S_MAP_SELECT 的 abort、GEOM5 成功清零）保持原样，
//   它们本是独立小锥，改动它们会碰 state 多写优先级问题，得不偿失。
task fail_operation;
    input [7:0] code;
    begin
        fail_code_r <= code;
        control_state<=S_FAIL;
    end
endtask

// 启动 map：立即执行或作为 pending 排队（bug3）
task start_map_now;
    begin
        active_op<=OP_MAP;
        map_accept<=1'b1;
        map_abort_pending<=0;
        map_ok<=0; fat_error_code<=0; map_have_run<=0;
        map_seg_count<=0;
        walk_remaining<=map_size;
        map_rem_zero<=(map_size==32'd0);   // 直达 S_MAP_SELECT，绕开 ACC 的预寄存
        walk_cluster<=map_first_cluster;
        map_first_valid<=valid_data_cluster(map_first_cluster);
        walk_hops<=0; map_hop_limit<=32'd1_000_000;
        cycle_tortoise<=map_first_cluster; cycle_power<=1; cycle_lam<=0;
        control_state<=S_MAP_SELECT;
    end
endtask

// Synchronous read ports keep both 512-byte directory storage and the FAT
// cache in embedded block RAM instead of thousands of flip-flops/LUT muxes.
always @(posedge clk) begin
    sector_q <= sector_buf[sector_addr];

    name_q   <= name_ram[name_rd_addr];
    if(name_write && !rst) name_ram[name_write_addr]<=name_write_data;
    
end

// Directory name writes cannot be canceled by a BMP or WAV request. Stage
// their address/data beside the BRAM instead of routing the shared abort/FSM
// mux into its write port. The existing EMIT_START/ADDR/WAIT stages cover the
// final delayed SFN write before the first character is consumed.
always @(posedge clk or posedge rst) begin
    if(rst) begin name_write<=0;name_write_addr<=0;name_write_data<=0;end
    else begin
        name_write<=(((control_state==S_LFN_WRITE)) && lfn_char_value!=0 && lfn_char_value!=16'hffff) ||
                    (((control_state==S_SFN_WRITE)) && sfn_build_write);
        name_write_addr<=((control_state==S_LFN_WRITE)) ? lfn_write_index:sfn_len;
        name_write_data<=((control_state==S_LFN_WRITE)) ?
            (((lfn_char_value>=16'h20)&&(lfn_char_value<=16'h7e)) ? lfn_char_value[7:0]:8'h3f):sfn_build_char;
    end
end

// Predict only the directory capture state; unrelated file/map cancellation
// must not feed the 256-bit entry capture enable.
always @(posedge clk or posedge rst) begin
    if(rst) begin geom3_bad<=0;mount_range_bad<=0;dir_more_sectors<=0;boot_capture<=0;walk_valid<=0;end
    else begin

        geom3_bad<=data_start_offset>=total_sectors;
        // total_sectors is captured in DBR; VALIDATE1 supplies a complete
        // settling cycle before VALIDATE2 consumes this range classification.
        mount_range_bad<=bpb_root_entries_nonzero || bpb_fat16_nonzero ||
            (partition_sectors!=0 && total_sectors>partition_sectors);
        boot_capture<=((control_state==S_RD_WAIT)) && rd_kind==RD_MOUNT;
        // FILE_SELECT gives the captured cluster a settling cycle. For maps,
        // the first cluster is classified at acceptance; subsequent clusters
        // have already passed MAP_FAT_CHK before returning to MAP_SELECT.
        walk_valid<=valid_data_cluster(file_cluster);
        // These arguments settle before ADVANCE/EVAL. Keep the adder and
        // wide comparison out of the shared operation state's next-state mux.
        dir_more_sectors<=({1'b0,dir_sector}+9'd1)<{1'b0,sectors_per_cluster};
    end
end

// Prepare the map-run write enable before S_MAP_ACC. File aborts cannot
// cancel OP_MAP, so they need not feed these private accumulator registers.
// This also removes the shared walker's broad state/abort mux from their CE.
always @(posedge clk or posedge rst) begin
    if(rst) begin map_acc_write<=0;map_acc_merge<=0;map_cluster_matches_prev<=0;end
    else begin
        // Resolve the 32-bit cluster equality in its own register. The map
        // cluster and previous-run boundary are stable before S_MAP_LBA2, so
        // the accumulator CE no longer combines this compare with state and
        // capacity selection on the same path.
        map_cluster_matches_prev<=map_cluster==map_cluster_prev_p1;
        map_acc_write<=((control_state==S_MAP_LBA2)) && active_op==OP_MAP &&
            (!map_have_run || (map_cluster_matches_prev && map_prev_full) || map_seg_count<MAP_DEPTH_C);
        map_acc_merge<=map_have_run && map_cluster_matches_prev && map_prev_full;
        if(map_acc_write) begin
            if(map_acc_merge) map_run_nsec<=map_run_nsec+map_use_nsec;
            else begin map_run_lba<=map_cur_lba;map_run_nsec<=map_use_nsec;end
        end
    end
end

// Mount arithmetic has a private write enable prepared in the preceding
// state. A file/map cancel cannot interrupt OP_MOUNT. Keep the main shared
// operation-state mux out of these wide adder register enables.
always @(posedge clk or posedge rst) begin
    if(rst) begin
        geom4_write<=0;geom4b_write<=0;
        cluster_x4<=0;fat_bytes<=0;
    end else begin
        geom4_write<=((control_state==S_MOUNT_GEOM3_CHECK)) && !geom3_bad;
        // Compute (max_cluster+1)<<2 one cycle after max_cluster is captured.
        geom4b_write<=((control_state==S_MOUNT_GEOM4C));
        
        if((control_state==S_MOUNT_GEOM4)) begin
            // Register the barrel-shift result first. The increment is placed
            // in the following state so it does not share the shift path.
            cluster_x4<=geometry_clusters;
        end else if((control_state==S_MOUNT_GEOM4B)) begin
            cluster_x4<=cluster_x4+32'd1;
        end else if(geom4b_write) begin
            cluster_x4<=(max_cluster+32'd1)<<2;
            fat_bytes<=fat_sectors<<9;
        end
    end
end

always @(posedge clk or posedge rst) begin
  if (rst) begin
    control_state<=S_IDLE; active_op<=0; blk_req<=0; blk_lba<=0; blk_count<=1; rd_index<=0; io_timeout<=0;
    io_timeout_last<=1'b0;
    file_read_sectors<=1; file_abort_pending<=0;file_has_data<=0;
    mount_done<=0; mount_ok<=0; fat_error_code<=0;
    dir_entry_start<=0; dir_name_valid<=0; dir_entry_end<=0; dir_done<=0; dir_ok<=0;
    dir_name_char<=0; dir_name_index<=0; dir_entry_name_len<=0;
    dir_entry_first_cluster<=0; dir_entry_size<=0; dir_entry_attr<=0;
    dir_entry_is_dir<=0; dir_entry_is_lfn<=0;
    file_data<=0; file_data_valid<=0; file_done<=0; file_ok<=0;
    map_done<=0; map_ok<=0; map_entry_valid<=0; map_entry_lba<=0;
    map_entry_nsec<=0; map_entry_last<=0; map_have_run<=0; map_abort_pending<=0;
    map_pending<=0;  
    map_accept<=0; map_seg_count<=0;
    partition_lba<=0; partition_sectors<=0;   root_cluster<=0; 
    sectors_per_cluster<=0; cluster_shift<=0; cluster_shift_bad<=0; fat_cache_valid<=0;
    bytes_per_cluster<=0; spc_nsec<=0; map_cluster_prev_p1<=0; map_cur_lba<=0;
    mbr_found<=0;
    mount_sig_bad<=0; mount_fs_cand<=0; geom5_bad<=0;
    map_next_result<=MAP_NEXT_INVALID;
    fat_next_eoc<=0; fat_next_valid<=0; fat_next_cycle<=0;
    cycle_lam_eq_power<=0; dir_hops_max<=0; fat_file_rem_zero<=0;
    file_last_in_cluster<=0; map_cycle_last<=0; map_rem_zero<=0;
    map_first_valid<=0;
    fail_code_r<=0;
    name_rd_addr<=0;
    
    dbg_dir_entry_count<=0; lfn_active<=0; lfn_valid<=0;
  end else begin
    if(boot_capture && blk_data_valid_i) begin
        if(rd_index==14) reserved_sectors[7:0]<=blk_data_i;
        if(rd_index==15) reserved_sectors[15:8]<=blk_data_i;
    end
    mount_done<=0; dir_done<=0; file_done<=0; map_done<=0; map_entry_valid<=0;
    map_accept<=0;
    dir_entry_start<=0; dir_name_valid<=0; dir_entry_end<=0; file_data_valid<=0;
    // bug3: latch map_start while walker busy (queue 1-deep) instead of dropping
    if (map_start && !((control_state==S_IDLE))) begin
      if (!map_pending && !((active_op==OP_MAP)&&(!((control_state==S_IDLE))))) begin
        map_pending     <= 1'b1;
        
        
      end else begin
        // queue full (pending or map already running): reject with map_done
        map_done<=1'b1; map_ok<=1'b0; fat_error_code<=`FAT_E_MAP_FULL;
      end
    end
    // bug3: map_abort clears pending request as well
    if (map_abort && map_pending && !((active_op==OP_MAP)&&(!((control_state==S_IDLE))))) begin
      map_pending<=1'b0;
      map_done<=1'b1; map_ok<=1'b0; fat_error_code<=`FAT_E_ABORT;
    end
    // A file abort is cooperative: if an SD burst has already been granted,
    // consume and discard the remainder of that short burst before returning
    // idle.  This keeps the physical SD channel and FAT service synchronized.
    if (file_abort_i && active_op==OP_FILE && !((control_state==S_IDLE)) && !((control_state==S_FAIL))) begin
      file_abort_pending<=1;
      if (!((control_state==S_RD_REQ)) && !((control_state==S_RD_WAIT))) begin
        blk_req<=0; file_done<=1; file_ok<=0; fat_error_code<=`FAT_E_ABORT;
        file_abort_pending<=0; control_state<=S_IDLE;
      end
    end else begin
    case(control_state) // synthesis parallel_case
      S_IDLE: begin
        blk_req<=0;
        if (mount_start) begin
          active_op<=OP_MOUNT;
          mount_ok<=0; fat_error_code<=0; fat_cache_valid<=0; partition_lba<=0; partition_sectors<=0;
          mbr_found<=0;
          start_buffer_read(0,1,S_MOUNT_SECTOR0,RD_MOUNT);
        end else if (dir_start_i) begin
          active_op<=OP_DIR;
          if (!mount_ok) begin dir_done<=1; dir_ok<=0; fat_error_code<=`FAT_E_DIR_NM; end
          else begin
            dir_ok<=0; walk_cluster<=root_cluster; dir_sector<=0; entry_off<=0;
            dir_hops<=0; dbg_dir_entry_count<=0; lfn_active<=0; lfn_valid<=0;
            control_state<=S_DIR_LBA;
          end
        end else if (file_start) begin
          active_op<=OP_FILE;
          file_abort_pending<=0;
          file_ok<=0; fat_error_code<=0;
          captured_file_size<=file_size; captured_read_limit<=file_read_limit;
          walk_cluster<=file_first_cluster; file_cluster_sector<=0; file_read_sectors<=1; walk_hops<=0;
          cycle_tortoise<=file_first_cluster; cycle_power<=1; cycle_lam<=0;
          
          control_state<=S_FILE_SELECT;
        end else if (map_start) begin
          start_map_now;
        end else if (map_pending) begin
          // bug3: promote latched pending map when walker goes idle
          map_pending<=1'b0;
          walk_remaining<=map_pend_size;
          map_rem_zero<=(map_pend_size==32'd0);   // 直达 S_MAP_SELECT
          walk_cluster<=map_pend_cluster;
          map_first_valid<=valid_data_cluster(map_pend_cluster);
          active_op<=OP_MAP;
          map_accept<=1'b1;
          map_abort_pending<=0;
          map_ok<=0; fat_error_code<=0; map_have_run<=0;
          map_seg_count<=0;
          walk_hops<=0; map_hop_limit<=32'd1_000_000;
          cycle_tortoise<=map_pend_cluster; cycle_power<=1; cycle_lam<=0;
          
          control_state<=S_MAP_SELECT;
        end
      end

      // Capture the controller inputs before selecting and validating the
      // read length.  This prevents a cross-module size compare from feeding
      // the large main-state result mux in the same cycle.
      S_FILE_SELECT: begin
        if ((captured_read_limit==0)||(captured_read_limit>captured_file_size)) begin
          walk_remaining<=captured_file_size;
        end else begin
          walk_remaining<=captured_read_limit;
        end
        control_state<=S_FILE_CHECK;
      end
      S_FILE_CHECK: begin
          file_has_data<=file_remaining!=0;
          if (file_remaining==0) begin file_done<=1; file_ok<=1; control_state<=S_IDLE; end
          else if (!mount_ok || !walk_valid) begin
            file_done<=1; file_ok<=0; fat_error_code<=`FAT_E_FILE_BAD;
            control_state<=S_IDLE;
          end else control_state<=S_FILE_PREP1;
      end

      // Compute ceil(file_bytes / bytes_per_cluster) over three short stages.
      // This used to be one add + variable barrel shift in S_IDLE and was one
      // of the 100 MHz setup-critical paths after place and route.
      S_FILE_PREP1: begin
        file_sector_count<=({1'b0,file_remaining}+33'd511)>>9;
        control_state<=S_FILE_PREP2;
      end
      S_FILE_PREP2: begin
        data_sectors<={8'd0,file_hop_rounded};
        control_state<=S_FILE_PREP3;
      end
      S_FILE_PREP3: begin
        file_hop_limit<=geometry_clusters[23:0];
        control_state<=S_FILE_LBA;
      end

      S_RD_REQ: begin
        blk_req<=1;
        if (blk_grant) begin blk_req<=0; io_timeout<=0; io_timeout_last<=1'b0; control_state<=S_RD_WAIT; end
        else if (io_timeout_last) begin blk_req<=0; fail_operation(`FAT_E_TIMEOUT); end
        else begin
          io_timeout<=io_timeout+28'd1;
          io_timeout_last<=io_timeout_next_last;
        end
      end
      S_RD_WAIT: begin
        if (blk_data_valid_i) begin
          if (rd_kind==RD_FILE) begin
            if (file_has_data && !file_abort_pending) begin
              file_data<=blk_data_i; file_data_valid<=1;
              walk_remaining<=file_remaining-1;
              file_has_data<=file_remaining!=1;
            end
          end else if (rd_index<512) begin
            if (rd_kind==RD_DIR)
              sector_buf[rd_index]<=blk_data_i;
            else if (rd_kind==RD_FAT) begin
              case (rd_index[1:0])
                2'd0: fat_assemble[7:0]<=blk_data_i;
                2'd1: fat_assemble[15:8]<=blk_data_i;
                2'd2: fat_assemble[23:16]<=blk_data_i;
                2'd3: begin end // Native cache captures the assembled word on this edge.
              endcase
            end else begin
              case (rd_index)
                11:bpb_bps_512<=blk_data_i==8'd0;
                12:bpb_bps_512<=bpb_bps_512 && blk_data_i==8'd2;
                13:bpb_spc<=blk_data_i;
                16:num_fats<=blk_data_i;
                17,18:bpb_root_entries_nonzero<=bpb_root_entries_nonzero|(blk_data_i!=0);
                19:bpb_tot16[7:0]<=blk_data_i; 20:bpb_tot16[15:8]<=blk_data_i;
                22,23:bpb_fat16_nonzero<=bpb_fat16_nonzero|(blk_data_i!=0);
                32:total_sectors[7:0]<=blk_data_i; 33:total_sectors[15:8]<=blk_data_i;
                34:total_sectors[23:16]<=blk_data_i; 35:total_sectors[31:24]<=blk_data_i;
                36:fat_sectors[7:0]<=blk_data_i; 37:fat_sectors[15:8]<=blk_data_i;
                38:fat_sectors[23:16]<=blk_data_i; 39:fat_sectors[31:24]<=blk_data_i;
                44:root_cluster[7:0]<=blk_data_i; 45:root_cluster[15:8]<=blk_data_i;
                46:root_cluster[23:16]<=blk_data_i; 47:root_cluster[31:24]<=blk_data_i;
                510:boot_sig0_ok<=(blk_data_i==8'h55);
                511:boot_sig1_ok<=(blk_data_i==8'haa);
              endcase
              // Scan the four MBR slots as bytes arrive.  The mount operation
              // is serialized, so partition_lba/partition_sectors also serve
              // as the current-slot assembly bank and retain the first valid
              // FAT32 partition.  This avoids separate 64-bit work and select
              // banks; tmp8 holds the current slot's type until byte 13.
              if ((blk_lba==0) && (rd_index>=446) && (rd_index<510)) begin
                case (rd_index[3:0])
                  2: if (!mbr_found) tmp8<=blk_data_i;
                  6: if (!mbr_found) partition_lba[7:0]<=blk_data_i;
                  7: if (!mbr_found) partition_lba[15:8]<=blk_data_i;
                  8: if (!mbr_found) partition_lba[23:16]<=blk_data_i;
                  9: if (!mbr_found) partition_lba[31:24]<=blk_data_i;
                  10: if (!mbr_found) partition_sectors[7:0]<=blk_data_i;
                  11: if (!mbr_found) partition_sectors[15:8]<=blk_data_i;
                  12: if (!mbr_found) partition_sectors[23:16]<=blk_data_i;
                  13: if (!mbr_found && is_fat32_type(tmp8) &&
                          (partition_lba!=0)) begin
                        partition_sectors[31:24]<=blk_data_i;
                        mbr_found<=1;
                      end
                endcase
              end
            end
            rd_index<=rd_index+1;
          end
        end
        if (blk_end_i) begin
          if (file_abort_pending && active_op==OP_FILE) begin
            file_done<=1; file_ok<=0; fat_error_code<=`FAT_E_ABORT;
            file_abort_pending<=0; control_state<=S_IDLE;
          end else if (blk_error_i) fail_operation(`FAT_E_RD);
          else begin
            if (rd_kind==RD_FAT) fat_cache_valid<=1;
            control_state<=rd_return_encoded;
          end
        end else if (io_timeout_last) fail_operation(`FAT_E_TIMEOUT);
        else begin
          io_timeout<=io_timeout+28'd1;
          io_timeout_last<=io_timeout_next_last;
        end
      end

      S_MOUNT_SECTOR0: begin
        // 判定结果先寄存，下一拍才进主状态 mux：boot_sig/bpb 比较锥不再
        // 与 start_buffer_read 的状态译码同拍（布线后曾是 -0.8ns 路径）。
        mount_sig_bad  <= !boot_sig0_ok || !boot_sig1_ok;
        mount_fs_cand  <= bpb_bps_512 && (spc_to_shift(bpb_spc)!=8'hff) &&
                          (reserved_sectors!=0) && (fat_sectors!=0) && (root_cluster>=2);
        control_state<=S_MOUNT_ISFS;
      end
      S_MOUNT_ISFS: begin
        if (mount_sig_bad) fail_operation(`FAT_E_MBR);
        else if (mount_fs_cand) begin
          partition_lba<=0; partition_sectors<=0; control_state<=S_MOUNT_DBR;
        end else begin
          control_state<=S_MOUNT_MBR;
        end
      end
      S_MOUNT_MBR: begin
        if (mbr_found) begin
          start_buffer_read(partition_lba,1,S_MOUNT_DBR,RD_MOUNT);
        end else fail_operation(`FAT_E_MBR);
      end
      S_MOUNT_DBR: begin
        if (!boot_sig0_ok || !boot_sig1_ok) fail_operation(`FAT_E_MBR);
        else if (!bpb_bps_512) fail_operation(`FAT_E_BPS);
        else begin
          tmp8=spc_to_shift(bpb_spc); tmp16=reserved_sectors;
          tmp32a=(bpb_tot16!=0)?{16'd0,bpb_tot16}:total_sectors;
          tmp32b=fat_sectors;
          sectors_per_cluster<=bpb_spc; cluster_shift<=tmp8[2:0]; cluster_shift_bad<=(tmp8==8'hff);
          reserved_sectors<=tmp16; num_fats<=num_fats;
          total_sectors<=tmp32a; fat_sectors<=tmp32b; root_cluster<=root_cluster;
          control_state<=S_MOUNT_VALIDATE1;
        end
      end
      S_MOUNT_VALIDATE1: begin
        if (cluster_shift_bad||(reserved_sectors==0)||(num_fats==0)||
            (total_sectors==0)||(fat_sectors==0)||(root_cluster<2))
          fail_operation(`FAT_E_DIR_NM);
        else control_state<=S_MOUNT_VALIDATE2;
      end
      S_MOUNT_VALIDATE2: begin
        if (mount_range_bad)
          fail_operation(`FAT_E_DIR_NM);
        else control_state<=S_MOUNT_GEOM1;
      end
      S_MOUNT_GEOM1: begin
        // Register the DSP result before any add/compare logic.  Previously
        // the multiplier, two adders, range compare and error mux were all in
        // one cycle (13.155 ns on a 10 ns clock).
        fat_area_sectors<=fat_sectors*num_fats;
        control_state<=S_MOUNT_GEOM2;
      end
      S_MOUNT_GEOM2: begin
        data_start_offset<={16'd0,reserved_sectors}+fat_area_sectors;
        control_state<=S_MOUNT_GEOM3;
      end
      S_MOUNT_GEOM3: control_state<=S_MOUNT_GEOM3_CHECK;
      S_MOUNT_GEOM3_CHECK: begin
        if (geom3_bad) fail_operation(`FAT_E_DIR_NM);
        else begin
          data_sectors<=total_sectors-data_start_offset;
          
          
          control_state<=S_MOUNT_GEOM4;
        end
      end
      S_MOUNT_GEOM4: begin
        control_state<=S_MOUNT_GEOM4B;
      end
      S_MOUNT_GEOM4B: begin
        control_state<=S_MOUNT_GEOM4C;
      end
      S_MOUNT_GEOM4C: begin
        // max_cluster captures cluster_count+1 on this edge.
        geom5_bad <= (data_sectors==0)||(cluster_x4==32'd1);
        control_state<=S_MOUNT_GEOM4D;
      end
      S_MOUNT_GEOM4D: begin
        // Validate root while the registered (max_cluster+1)<<2 value settles.
        geom5_bad <= geom5_bad || (root_hi_gt || (root_hi_eq && root_lo_gt));
        control_state<=S_MOUNT_GEOM4E;
      end
      S_MOUNT_GEOM4E: begin
        // The half-comparison registers capture this edge; GEOM5 consumes them.
        control_state<=S_MOUNT_GEOM5;
      end
      S_MOUNT_GEOM5: begin
        if (geom5_bad || fat_hi_gt || (fat_hi_eq && fat_lo_gt)) fail_operation(`FAT_E_DIR_NM);
        else begin
          mount_ok<=1; mount_done<=1;
          // map/挂载共用的簇几何预计算收口到这里：走表时不再现场
          // 做「零扩展 + 变量移位」（原 S_MAP_SELECT 的 13 级路径来源之一）。
          bytes_per_cluster<={24'd0,sectors_per_cluster}<<9;
          spc_nsec<={8'd0,sectors_per_cluster};
          fat_error_code<=0; control_state<=S_IDLE;
        end
      end

      S_DIR_READ: begin
        tmp32a=map_cur_lba+dir_sector;
        start_buffer_read(tmp32a,1,S_DIR_ENTRY,RD_DIR);
      end
      S_DIR_LBA: begin
        cluster_lba_offset<=lba_cluster_offset;
        control_state<=S_MAP_LBA2;
      end
      S_DIR_ENTRY: begin
        sector_addr<=entry_off;entry_load_count<=0;entry_ext_nonblank<=0;
        control_state<=S_DIR_LOAD_WAIT;
      end
      S_DIR_LOAD_WAIT: begin control_state<=S_DIR_LOAD;end
      S_DIR_LOAD: begin
        case(entry_load_count)
          0:entry_first<=sector_q;11:dir_entry_attr<=sector_q;
          12:entry_ntres<=sector_q;13:entry_checksum<=sector_q;
          8,9,10:entry_ext_nonblank<=entry_ext_nonblank || sector_q!=8'h20;
          20:dir_entry_first_cluster[23:16]<=sector_q;21:dir_entry_first_cluster[31:24]<=sector_q;
          26:dir_entry_first_cluster[7:0]<=sector_q;27:dir_entry_first_cluster[15:8]<=sector_q;
          28:dir_entry_size[7:0]<=sector_q;29:dir_entry_size[15:8]<=sector_q;
          30:dir_entry_size[23:16]<=sector_q;31:dir_entry_size[31:24]<=sector_q;
        endcase
        if(entry_load_count==31) control_state<=S_DIR_DECODE;
        else begin entry_load_count<=entry_load_count+1'b1;sector_addr<=sector_addr+1'b1;
          control_state<=S_DIR_LOAD_WAIT;end
      end
      S_DIR_DECODE: begin
        if (entry_first==8'h00) begin dir_done<=1; dir_ok<=1; control_state<=S_IDLE; end
        else if (entry_first==8'he5) begin lfn_active<=0; control_state<=S_DIR_ADVANCE; end
        else if (dir_entry_attr==8'h0f) begin
          lfn_ord<=entry_first&8'h1f;
          lfn_base<=lfn_base_table;
          if ((entry_first&8'h40)!=0) begin
            lfn_active<=1; lfn_valid<=((entry_first&8'ha0)==0)&&
                                     ((entry_first&8'h1f)>=1)&&((entry_first&8'h1f)<=20)&&
                                     (entry_ntres==0)&&(dir_entry_first_cluster[15:0]==0);
            lfn_expected<=(entry_first&8'h1f)-1;
            lfn_checksum<=entry_checksum;
            lfn_len<=lfn_length_table;
          end else begin
            if (!lfn_active || ((entry_first&8'he0)!=0) ||
                ((entry_first&8'h1f)!=lfn_expected) ||
                (entry_checksum!=lfn_checksum) || (entry_ntres!=0) ||
                (dir_entry_first_cluster[15:0]!=0)) lfn_valid<=0;
            if (lfn_expected!=0) lfn_expected<=lfn_expected-1;
          end
          lfn_char_no<=0; control_state<=S_LFN_CHAR;
        end else if ((dir_entry_attr&8'h08)!=0) begin lfn_active<=0; control_state<=S_DIR_ADVANCE; end
        else begin
          dir_entry_is_dir<=dir_entry_attr[4];sfn_ntres<=entry_ntres;
          sfn_checksum<=0; sfn_pos<=0; control_state<=S_SFN_CSUM;
        end
      end
      S_LFN_CHAR: begin
        sector_addr<=entry_off+{4'd0,lfn_offset(lfn_char_no)};
        lfn_write_index<=lfn_base+lfn_char_no;control_state<=S_LFN_WAIT1;
      end
      S_LFN_WAIT1:control_state<=S_LFN_WAIT2;
      S_LFN_WAIT2:begin lfn_low<=sector_q;sector_addr<=sector_addr+1'b1;control_state<=S_LFN_WAIT3;end
      S_LFN_WAIT3:control_state<=S_LFN_WAIT4;
      S_LFN_WAIT4:begin lfn_char_value<={sector_q,lfn_low};control_state<=S_LFN_WRITE;end
      S_LFN_WRITE: begin
        if (lfn_char_value==0 && lfn_write_index<lfn_len) lfn_len<=lfn_write_index;
        if (lfn_char_no==12) control_state<=S_DIR_ADVANCE;
        else begin lfn_char_no<=lfn_char_no+1;control_state<=S_LFN_CHAR;end
      end
      S_SFN_CSUM: begin
        sector_addr<=entry_off+{5'd0,sfn_pos};control_state<=S_CSUM_WAIT1;
      end
      S_CSUM_WAIT1:control_state<=S_CSUM_WAIT2;
      S_CSUM_WAIT2:begin
        sfn_checksum<={sfn_checksum[0],sfn_checksum[7:1]}+sector_q;
        if(sfn_pos==10) control_state<=S_SFN_CSUM_EVAL;
        else begin sfn_pos<=sfn_pos+1'b1;control_state<=S_SFN_CSUM;end
      end
      S_SFN_CSUM_EVAL: begin
        if (lfn_active && lfn_valid && (lfn_expected==0) &&
            (sfn_checksum==lfn_checksum)) begin
          dir_entry_name_len<=lfn_len; dir_entry_is_lfn<=1; emit_pos<=0; control_state<=S_EMIT_START;
        end else begin sfn_pos<=0; sfn_len<=0; control_state<=S_SFN_BUILD; end
      end
      S_SFN_BUILD: begin
        if(sfn_pos==8) begin
          sfn_raw_char<=8'h2e;sfn_build_lower<=0;sfn_build_extmark<=1;
          sfn_build_last<=0;sfn_next_pos<=9;control_state<=S_SFN_PREP;
        end else begin
          sector_addr<=entry_off+{5'd0,sfn_pos}-(sfn_pos>8 ? 9'd1:9'd0);
          sfn_build_lower<=sfn_pos<8 ? sfn_ntres[3]:sfn_ntres[4];
          sfn_build_extmark<=0;sfn_build_last<=sfn_pos==11;sfn_next_pos<=sfn_pos+1'b1;
          control_state<=S_BUILD_WAIT1;
        end
      end
      S_BUILD_WAIT1:control_state<=S_BUILD_WAIT2;
      S_BUILD_WAIT2:begin sfn_raw_char<=sector_q;control_state<=S_SFN_PREP;end
      S_SFN_PREP: begin
        tmp8=((sfn_pos==0)&&(sfn_raw_char==8'h05))?8'he5:sfn_raw_char;
        sfn_build_char<=sfn_build_lower?lower_ascii(tmp8):tmp8;
        sfn_build_write<=sfn_build_extmark ?
                         entry_ext_nonblank :
                         (tmp8!=8'h20);
        control_state<=S_SFN_WRITE;
      end
      S_SFN_WRITE: begin
        if (sfn_build_write) begin
          sfn_len<=sfn_len+1;
        end
        if (sfn_build_last) begin
          dir_entry_name_len<=sfn_len+sfn_build_write;
          dir_entry_is_lfn<=0; emit_pos<=0; control_state<=S_EMIT_START;
        end else begin
          sfn_pos<=sfn_next_pos; control_state<=S_SFN_BUILD;
        end
      end
      S_EMIT_START: begin dir_entry_start<=1; control_state<=(dir_entry_name_len==0)?S_EMIT_END:S_EMIT_ADDR; end
      S_EMIT_ADDR:  begin name_rd_addr<=emit_pos; control_state<=S_EMIT_WAIT; end
      S_EMIT_WAIT:  begin control_state<=S_EMIT_NAME; end    // name_q 在本拍末变为 name_ram[emit_pos]
      S_EMIT_NAME: begin
        dir_name_valid<=1; dir_name_char<=name_q; dir_name_index<=emit_pos;
        if (emit_last) control_state<=S_EMIT_END;
        else begin emit_pos<=emit_pos+1; control_state<=S_EMIT_ADDR; end
      end
      S_EMIT_END: begin
        dir_entry_end<=1; dbg_dir_entry_count<=dbg_dir_entry_count+1; lfn_active<=0; lfn_valid<=0;
        control_state<=S_DIR_ADVANCE;
      end
      S_DIR_ADVANCE: begin
        if (entry_off<480) begin entry_off<=entry_off+32; control_state<=S_DIR_ENTRY; end
        else begin
          entry_off<=0;
          if (dir_more_sectors) begin dir_sector<=dir_sector+1; control_state<=S_DIR_READ; end
          else begin fat_context<=FAT_FOR_DIR; control_state<=S_FAT_REQ; end
        end
      end

      S_FAT_REQ: begin
        fat_req_lba<=fat_lba+(fat_query_cluster>>7);
        // +1 加法从 S_FAT_EVAL 前移到本拍（file_hops/cycle_lam 只在
        // S_FAT_CHECK 才变，整个 FAT 走查期间稳定），EVAL 拍只剩比较树：
        walk_hops_next<=file_hops+32'd1;
        cycle_lam_next<=cycle_lam+32'd1;
        control_state<=S_FAT_REQ_READY;
      end
      S_FAT_REQ_READY: begin
        // Split the 24-bit hop-limit comparator across the RAM wait states.
        // The high-byte relation is ready before EVAL, which only compares the
        // low 16 bits instead of placing one full-width compare on its path.
        file_hop_high_gt<=walk_hops_next[23:16]>file_hop_limit[23:16];
        file_hop_high_eq<=walk_hops_next[23:16]==file_hop_limit[23:16];
        if (fat_cache_valid && fat_cache_lba==fat_req_lba) begin
          fat_addr<=fat_query_cluster[6:0]; control_state<=S_FAT_WAIT;
        end
        else begin
          fat_cache_lba<=fat_req_lba; fat_cache_valid<=0; fat_addr<=fat_query_cluster[6:0];
          start_buffer_read(fat_req_lba,1,S_FAT_WAIT,RD_FAT);
        end
      end
      S_FAT_WAIT: begin
        fat_addr<=fat_query_cluster[6:0]; control_state<=S_FAT_LATCH;
      end
      S_FAT_LATCH: control_state<=S_FAT_EVAL;
      S_FAT_EVAL: begin
        if (fat_cache_valid) begin
          // file 路径判定预寄存（map 路径 E3 的 file 版）：三棵 32 位
          // 比较树在本拍落地成单比特，S_FAT_CHECK 只看寄存器——原先
          // 该锥直达 fail_operation 的错误mux 与 state 次态。
          // 注：fat_link_data[27:0] 零扩展后恒 < 32'h0ffffff0，
          //     valid_data_cluster 的第三条件恒真，此处省略。
          fat_next_eoc   <= (fat_link_data[27:0] >= 28'h0ffffff8);
          fat_next_valid <= (fat_link_data[27:0] >= 28'd2) &&
                            ({4'd0,fat_link_data[27:0]} <= max_cluster);
          fat_next_cycle <= ({4'd0,fat_link_data[27:0]} == cycle_tortoise) ||
                            file_hop_high_gt ||
                            (file_hop_high_eq &&
                             walk_hops_next[15:0]>=file_hop_limit[15:0]);
          cycle_lam_eq_power <= (cycle_lam_next == cycle_power);
          dir_hops_max       <= (dir_hops >= max_cluster);
          fat_file_rem_zero  <= (file_remaining == 32'd0);
          control_state<=S_FAT_CHECK;
        end else fail_operation(`FAT_E_TIMEOUT);
      end
      S_FAT_CHECK: begin
          if (fat_next_eoc) begin
            if (fat_context==FAT_FOR_DIR) begin dir_done<=1; dir_ok<=1; control_state<=S_IDLE; end
            else if (fat_file_rem_zero) begin file_done<=1; file_ok<=1; control_state<=S_IDLE; end
            else fail_operation(`FAT_E_CLUSTER);
          end else if (!fat_next_valid) fail_operation(`FAT_E_NDATA);
          else if (fat_context==FAT_FOR_DIR) begin
            if (dir_hops_max) fail_operation(`FAT_E_DIR_HOPS);
            else begin walk_cluster<=fat_next_cluster; dir_sector<=0; entry_off<=0; dir_hops<=dir_hops+1; control_state<=S_DIR_LBA; end
          end else begin
            if (fat_next_cycle) fail_operation(`FAT_E_CYCLE);
            else begin walk_cluster<=fat_next_cluster; file_cluster_sector<=0; walk_hops<=file_hops_next; control_state<=S_FILE_LBA; end
            if (cycle_lam_eq_power) begin
              cycle_tortoise<=fat_next_cluster; cycle_power<=cycle_power<<1; cycle_lam<=0;
            end else cycle_lam<=cycle_lam_next;
          end
      end

      S_FILE_READ: begin
        // Non-preemptible bursts obey the configured consumer credit bound.
        // The media scaler uses one sector; standalone default remains four.
        // Never cross a cluster boundary.
        if (file_read_ready) begin
          tmp32a=({1'b0,file_remaining}+33'd511)>>9;
          if (tmp32a>FILE_MAX_BURST)
            file_read_sectors<=FILE_MAX_BURST;
          else
            file_read_sectors<=tmp32a[7:0];
          if ((sectors_per_cluster-file_cluster_sector)<FILE_MAX_BURST &&
              (sectors_per_cluster-file_cluster_sector)<tmp32a)
            file_read_sectors<=sectors_per_cluster-file_cluster_sector;
          control_state<=S_FILE_ISSUE;
        end
      end
      S_FILE_ISSUE: begin
        // 「本簇是否读完」预寄存：S_FILE_AFTER 只剩寄存器判断。
        // file_read_sectors 经 S_FILE_READ 钳位后恒有
        // file_cluster_sector+file_read_sectors<=sectors_per_cluster，
        // 故 !file_last_in_cluster ≡ 原 sum<spc 的活比较。
        file_last_in_cluster <= ({2'd0,file_cluster_sector}+{2'd0,file_read_sectors}
                                 >= {2'd0,sectors_per_cluster});
        start_buffer_read(map_cur_lba+
                          {24'd0,file_cluster_sector},
                          {8'd0,file_read_sectors},S_FILE_AFTER,RD_FILE);
      end
      S_FILE_LBA: begin
        cluster_lba_offset<=lba_cluster_offset;
        control_state<=S_MAP_LBA2;
      end
      S_FILE_AFTER: begin
        if (file_remaining==0) begin file_done<=1; file_ok<=1; control_state<=S_IDLE; end
        else if (!file_last_in_cluster) begin
          file_cluster_sector<=file_cluster_sector+file_read_sectors;
          control_state<=S_FILE_READ;
        end else begin
          fat_context<=FAT_FOR_FILE; control_state<=S_FAT_REQ;
        end
      end

      // ---- map 走表：只查 FAT，把连续簇合并成 {lba,nsec} 段 ----
      // 重定时（布线后 WNS -1.018ns 的收口）：原 S_MAP_SELECT 在一拍里做
      // 「零扩展+变量移位+比较+选择」，S_MAP_ACC 又做「32 位加法+比较+变移位
      // LBA 计算+多路选择」，且 map_done/map_ok 直接扇出到模块外。现在：
      //   S_MAP_SELECT —— 只做寄存器判定与分发；
      //   S_MAP_USE    —— 用挂载期预计算的 bytes_per_cluster/spc_nsec 算本簇用量；
      //   S_MAP_LBA    —— 独立算当前簇起始 LBA（变移位+加法只此一处）；
      //   S_MAP_ACC    —— 只剩 prev_p1 比较（加法在上一拍算好）与段累计。
      S_MAP_SELECT: begin
        if (map_abort) begin
          map_abort_pending<=1; map_ok<=0; fat_error_code<=`FAT_E_ABORT;
          map_done<=1; control_state<=S_IDLE;
        end else if (map_rem_zero) begin
          if (map_have_run) begin
            if (map_seg_count >= MAP_DEPTH_C) fail_operation(`FAT_E_MAP_OVF);
            else begin
              map_entry_lba<=map_run_lba; map_entry_nsec<=map_run_nsec; map_entry_last<=1;
              map_entry_valid<=1; map_seg_count<=map_seg_count+1'b1; control_state<=S_MAP_DONE;
            end
          end else begin
            map_ok<=1; map_done<=1; control_state<=S_IDLE;
          end
        end else if (!mount_ok || !map_first_valid) begin
          fail_operation(`FAT_E_DIR_NM);
        end else begin
          control_state<=S_MAP_USE;
        end
      end

      S_MAP_USE: begin
        if (map_remaining >= bytes_per_cluster) begin
          map_use_bytes <= bytes_per_cluster;
          map_use_nsec  <= spc_nsec;
        end else begin
          map_use_bytes <= map_remaining;
          map_use_nsec  <= map_remaining[25:9] + |map_remaining[8:0];
        end
        control_state<=S_MAP_LBA;
      end

      S_MAP_LBA: begin
        cluster_lba_offset <= lba_cluster_offset;
        control_state<=S_MAP_LBA2;
      end

      S_MAP_LBA2: begin
        map_cur_lba <= data_lba + cluster_lba_offset;
        // File, directory and map operations share this registered base LBA.
        // Request issue adds only the sector offset, never a second 32-bit sum.
        control_state<=active_op==OP_FILE ? S_FILE_READ:active_op==OP_DIR ? S_DIR_READ:S_MAP_ACC;
      end

      S_MAP_ACC: begin
        if (map_have_run && !map_acc_merge && map_seg_count >= MAP_DEPTH_C) begin
          fail_operation(`FAT_E_MAP_OVF);
        end else begin
          // The dedicated accumulator updates at this same edge. Emitted
          // metadata still sees the preceding run before nonblocking updates.
          if (map_have_run && !map_acc_merge) begin
            map_entry_lba  <= map_run_lba;
            map_entry_nsec <= map_run_nsec;
            map_entry_last <= 0;
            map_entry_valid<= 1;
            map_seg_count  <= map_seg_count + 1'b1;
          end
        map_have_run<=1;
        map_cluster_prev    <= map_cluster;
        map_cluster_prev_p1 <= map_cluster + 32'd1;
        map_prev_full       <= (map_use_nsec == spc_nsec);
        walk_remaining      <= map_remaining - map_use_bytes;
        // 归零判定预寄存：新 remaining==0 ⟺ 本拍 remaining==use_bytes
        // （等值比较不需等减法结果，use_bytes 恒 >0 已由 SELECT/USE 保证）
        map_rem_zero        <= (map_remaining == map_use_bytes);
        walk_hops_next      <= {4'd0,map_hops} + 24'd1;
        control_state<=S_MAP_EMIT;
        end
      end

      S_MAP_EMIT: begin
        map_entry_valid<=0;
        if (map_rem_zero) begin
          if (map_have_run) begin
            if (map_seg_count >= MAP_DEPTH_C) fail_operation(`FAT_E_MAP_OVF);
            else begin
              map_entry_lba<=map_run_lba; map_entry_nsec<=map_run_nsec; map_entry_last<=1;
              map_entry_valid<=1; map_seg_count<=map_seg_count+1'b1; control_state<=S_MAP_DONE;
            end
          end else begin
            map_ok<=1; map_done<=1; control_state<=S_IDLE;
          end
        end else begin
          control_state<=S_MAP_FAT;
        end
      end

      S_MAP_FAT: begin
        // 先寄存 FAT 扇区地址，切断 map_cluster 经加法、cache 比较和
        // start_buffer_read 状态译码形成的 100 MHz 长组合路径。
        fat_req_lba<=fat_lba+(map_cluster>>7);
        fat_addr<=map_cluster[6:0];
        control_state<=S_MAP_FAT_REQ;
      end

      S_MAP_FAT_REQ: begin
        // 独立查 FAT[map_cluster] → map_cluster
        if (fat_cache_valid && fat_cache_lba==fat_req_lba) begin
          control_state<=S_MAP_FAT_WAIT;
        end else begin
          fat_cache_lba<=fat_req_lba; fat_cache_valid<=0;
          start_buffer_read(fat_req_lba,1,S_MAP_FAT_WAIT,RD_FAT);
        end
      end

      S_MAP_FAT_WAIT: begin
        fat_addr<=map_cluster[6:0];
        // Precompute lam+1 while the synchronous FAT RAM read is in flight.
        // GET compares that registered value to power, avoiding a decrement
        // and equality tree on the cycle that also updates the cycle flags.
        cycle_lam_next<=cycle_lam+24'd1;
        control_state<=S_MAP_FAT_LATCH;
      end

      S_MAP_FAT_LATCH: control_state<=S_MAP_FAT_GET;
      S_MAP_FAT_GET: begin
        // 预判定（E3）：valid_data_cluster/cycle 两棵 32 位比较树在本拍
        // 落地成单比特，S_MAP_FAT_CHK 只看寄存器——原先该锥直达
        // fat_error_code / map_run_lba / map_entry_nsec 的 CE，
        // 布线后 -91~-152ps。
        if (fat_link_data[27:0]>=32'h0ffffff8)
          map_next_result<=MAP_NEXT_EOC;
        else if (!((fat_link_data[27:0]>=28'd2) &&
                   ({4'd0,fat_link_data[27:0]}<=max_cluster) &&
                   (fat_link_data[27:0]<32'h0ffffff0)))
          map_next_result<=MAP_NEXT_INVALID;
        else if ((fat_link_data[27:0]==cycle_tortoise) || (map_hops_next>=map_hop_limit))
          map_next_result<=MAP_NEXT_CYCLE;
        else map_next_result<=MAP_NEXT_VALID;
        map_cycle_last  <= (cycle_lam_next==cycle_power);
        control_state<=S_MAP_FAT_CHK;
      end

      S_MAP_FAT_CHK: begin
        case (map_next_result)
          MAP_NEXT_EOC: begin
            if (map_rem_zero) begin
              if (map_have_run) control_state<=S_MAP_EMIT;
              else begin map_ok<=1; map_done<=1; control_state<=S_IDLE; end
            end else fail_operation(`FAT_E_CLUSTER);
          end
          MAP_NEXT_INVALID: fail_operation(`FAT_E_NDATA);
          MAP_NEXT_CYCLE: fail_operation(`FAT_E_CYCLE);
          default: begin
            walk_cluster<=fat_next_cluster;
            walk_hops<={4'd0,map_hops_next};
            if (map_cycle_last) begin
              cycle_tortoise<=fat_next_cluster;
              cycle_power<=cycle_power<<1;
              cycle_lam<=0;
            end else cycle_lam<=cycle_lam+1;
            control_state<=S_MAP_SELECT;
          end
        endcase
      end

      S_MAP_DONE: begin
        map_ok<=1;
        map_done<=1;
        map_have_run<=0;
        control_state<=S_IDLE;
      end

      // 错误收尾拍：把所有（25 处）fail_operation 调用点的落码/done 动作
      // 收到这里一处，CE 锥从多状态 OR 树变成单状态译码。
      // active_op 在判定拍已定，到这里仍保持原值。
      S_FAIL: begin
        blk_req<=0;
        fat_error_code<=fail_code_r;
        if (active_op==OP_DIR)       begin dir_done<=1;   dir_ok<=0;   end
        else if (active_op==OP_FILE) begin file_done<=1;  file_ok<=0;  end
        else if (active_op==OP_MAP)  begin map_done<=1;   map_ok<=0;   end
        else                         begin mount_done<=1; mount_ok<=0; end
        control_state<=S_IDLE;
      end

      default: control_state<=S_IDLE;
    endcase
    end
  end
end

    // Mirror the existing main-FSM guard exactly, including cooperative abort.
    wire context_case_enable=!(file_abort_i && active_op==OP_FILE &&
      !(control_state==S_IDLE) && !(control_state==S_FAIL));
    // Mount is a separate operation and cannot be canceled by file_abort_i;
    // keep the wide DSP capture enables local to the mount state decode.

    wire cache_refill_write=!rst && context_case_enable && (control_state==S_RD_WAIT) &&
      blk_data_valid_i && rd_kind==RD_FAT && rd_index<512 && rd_index[1:0]==2'd3;
    resource_fat_cache32 u_fat_cache(.clk(clk),.write(cache_refill_write),
      .write_address(rd_index[8:2]),.read_address(fat_addr),
      .din({blk_data_i,fat_assemble}),.q(fat_q));
    wire geometry_capture=((control_state==S_MOUNT_GEOM3_CHECK)) && !geom3_bad;
    wire maximum_capture=((control_state==S_MOUNT_GEOM4C));
    wire pending_capture=map_start && !(control_state==S_IDLE) && !map_pending &&
      !(active_op==OP_MAP && !(control_state==S_IDLE));
    resource_fat_geometry_hold #(.WIDTH(64)) u_geometry(.clk(clk),.rst(rst),.enable(geometry_capture),
      .din({partition_lba+{16'd0,reserved_sectors},partition_lba+data_start_offset}),.q({fat_lba,data_lba}));
    // max_cluster feeds 32-bit comparisons, so the capture register is a plain
    // flip-flop: the DSP hold used here until 2026-10-26 put a 3.563 ns
    // combinational MULT18 between D and Q and was the worst routed path
    // (-0.522 ns on 2026-10-22).
    resource_fat_ff_hold #(.WIDTH(32)) u_maximum(.clk(clk),.rst(rst),.enable(maximum_capture),
      .din(cluster_x4),.q(max_cluster));
    // This bank remains separate from active operation state; no lifecycle merge.
    resource_fat_dsp_hold #(.WIDTH(64)) u_pending(.clk(clk),.rst(rst),.enable(pending_capture),
      .din({map_first_cluster,map_size}),.q({map_pend_cluster,map_pend_size}));
    // Metadata byte zero precedes DIR_DECODE by the complete entry scan.
    resource_fat_lfn_table u_lfn_table(.clk(clk),.a({5'd0,entry_first[4:0]}),
      .b({4'd0,1'b1,entry_first[4:0]}),.qa(lfn_base_table),.qb(lfn_length_table));

endmodule

// Fabric flip-flop hold with the same interface as resource_fat_dsp_hold.
// Used where the captured value drives wide comparisons: the DSP form costs a
// full combinational MULT18 (measured 3.563 ns) between D and Q.
module resource_fat_ff_hold #(parameter WIDTH=64)(
 input wire clk,rst,enable,input wire [WIDTH-1:0] din,output reg [WIDTH-1:0] q);
always @(posedge clk or posedge rst)
  if(rst) q<={WIDTH{1'b0}};
  else if(enable) q<=din;
endmodule

module resource_fat_dsp_hold #(parameter WIDTH=64)(
 input wire clk,rst,enable,input wire [WIDTH-1:0] din,output wire [WIDTH-1:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [WIDTH-1:0] held;
 always @(posedge clk or posedge rst) if(rst) held<=0;else if(enable) held<=din;
 assign q=held;
`else
 localparam LANES=(WIDTH+17)/18;
 wire [LANES*18-1:0] padded={{(LANES*18-WIDTH){1'b0}},din};
 wire [LANES*18-1:0] held;
 assign q=held[WIDTH-1:0];
 genvar i;
 generate for(i=0;i<LANES;i=i+1)begin:lane
  wire [35:0] product;
  assign held[i*18+:18]=product[17:0];
  EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("ENABLE"),
   .SRMODE("ASYNC"),.MODE("MULT18X18C")) u_hold(
   .clk(clk),.a(padded[i*18+:18]),.b(18'd1),.acin(18'd0),.bcin(18'd0),
   .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
   .cea(1'b0),.ceb(1'b0),.cepd(enable),.rstan(1'b1),.rstbn(1'b1),.rstpdn(!rst),
   .acout(),.bcout(),.p(product));
 end endgenerate
`endif
endmodule

module resource_fat_cache32(input wire clk,write,input wire [6:0] write_address,read_address,
 input wire [31:0] din,output wire [31:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [31:0] mem[0:127],qr;
 assign q=qr;
 always @(posedge clk)if(write)mem[write_address]<=din;else qr<=mem[read_address];
`else
 wire [6:0] address=write ? write_address:read_address;
 // Each half uses a disjoint 1024-word physical bank, as in the proven
 // 25-bit Goertzel history. No simultaneous read/write of a physical word.
 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG")) u_cache(
  .clka(clk),.addra({4'd0,address}),.doa(q[15:0]),.dia(din[15:0]),
  .bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(write),.rsta(1'b0),.ocea(1'b1),
  .clkb(clk),.addrb({4'b1000,address}),.dob(q[31:16]),.dib(din[31:16]),
  .byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(write),.rstb(1'b0),.oceb(1'b1));
`endif
endmodule

// Use the already allocated DSP's input registers for the geometry pre-stage.
// GEOM3 supplies the input-register clock before GEOM3_CHECK captures PREG.
// The sums are unchanged and no fabric FFs, extra DSPs or FSM cycles are added.
module resource_fat_geometry_hold #(parameter WIDTH=64)(
 input wire clk,rst,enable,input wire [WIDTH-1:0] din,output wire [WIDTH-1:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [WIDTH-1:0] prefetched,held;
 always @(posedge clk or posedge rst)
  if(rst)begin prefetched<=0;held<=0;end
  else begin prefetched<=din;if(enable)held<=prefetched;end
 assign q=held;
`else
 localparam LANES=(WIDTH+17)/18;
 wire [LANES*18-1:0] padded={{(LANES*18-WIDTH){1'b0}},din};
 wire [LANES*18-1:0] held;
 assign q=held[WIDTH-1:0];
 genvar i;
 generate for(i=0;i<LANES;i=i+1)begin:lane
  wire [35:0] product;
  assign held[i*18+:18]=product[17:0];
  EG_PHY_MULT18 #(.INPUTREGA("ENABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("ENABLE"),
   .SRMODE("ASYNC"),.MODE("MULT18X18C")) u_hold(
   .clk(clk),.a(padded[i*18+:18]),.b(18'd1),.acin(18'd0),.bcin(18'd0),
   .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
   .cea(1'b1),.ceb(1'b0),.cepd(enable),.rstan(!rst),.rstbn(1'b1),.rstpdn(!rst),
   .acout(),.bcout(),.p(product));
 end endgenerate
`endif
endmodule

module resource_fat_lfn_table(input wire clk,input wire [9:0] a,b,output wire [7:0] qa,qb);
`ifdef DB_BEHAVIORAL_RAM
reg [7:0] mem[0:1023],ra,rb;assign qa=ra;assign qb=rb;
initial begin
mem[0]=8'd247;
mem[1]=8'd0;
mem[2]=8'd13;
mem[3]=8'd26;
mem[4]=8'd39;
mem[5]=8'd52;
mem[6]=8'd65;
mem[7]=8'd78;
mem[8]=8'd91;
mem[9]=8'd104;
mem[10]=8'd117;
mem[11]=8'd130;
mem[12]=8'd143;
mem[13]=8'd156;
mem[14]=8'd169;
mem[15]=8'd182;
mem[16]=8'd195;
mem[17]=8'd208;
mem[18]=8'd221;
mem[19]=8'd234;
mem[20]=8'd247;
mem[21]=8'd247;
mem[22]=8'd247;
mem[23]=8'd247;
mem[24]=8'd247;
mem[25]=8'd247;
mem[26]=8'd247;
mem[27]=8'd247;
mem[28]=8'd247;
mem[29]=8'd247;
mem[30]=8'd247;
mem[31]=8'd247;
mem[32]=8'd0;
mem[33]=8'd13;
mem[34]=8'd26;
mem[35]=8'd39;
mem[36]=8'd52;
mem[37]=8'd65;
mem[38]=8'd78;
mem[39]=8'd91;
mem[40]=8'd104;
mem[41]=8'd117;
mem[42]=8'd130;
mem[43]=8'd143;
mem[44]=8'd156;
mem[45]=8'd169;
mem[46]=8'd182;
mem[47]=8'd195;
mem[48]=8'd208;
mem[49]=8'd221;
mem[50]=8'd234;
mem[51]=8'd247;
mem[52]=8'd255;
mem[53]=8'd17;
mem[54]=8'd30;
mem[55]=8'd43;
mem[56]=8'd56;
mem[57]=8'd69;
mem[58]=8'd82;
mem[59]=8'd95;
mem[60]=8'd108;
mem[61]=8'd121;
mem[62]=8'd134;
mem[63]=8'd147;
mem[64]=8'd0;
mem[65]=8'd0;
mem[66]=8'd0;
mem[67]=8'd0;
mem[68]=8'd0;
mem[69]=8'd0;
mem[70]=8'd0;
mem[71]=8'd0;
mem[72]=8'd0;
mem[73]=8'd0;
mem[74]=8'd0;
mem[75]=8'd0;
mem[76]=8'd0;
mem[77]=8'd0;
mem[78]=8'd0;
mem[79]=8'd0;
mem[80]=8'd0;
mem[81]=8'd0;
mem[82]=8'd0;
mem[83]=8'd0;
mem[84]=8'd0;
mem[85]=8'd0;
mem[86]=8'd0;
mem[87]=8'd0;
mem[88]=8'd0;
mem[89]=8'd0;
mem[90]=8'd0;
mem[91]=8'd0;
mem[92]=8'd0;
mem[93]=8'd0;
mem[94]=8'd0;
mem[95]=8'd0;
mem[96]=8'd0;
mem[97]=8'd0;
mem[98]=8'd0;
mem[99]=8'd0;
mem[100]=8'd0;
mem[101]=8'd0;
mem[102]=8'd0;
mem[103]=8'd0;
mem[104]=8'd0;
mem[105]=8'd0;
mem[106]=8'd0;
mem[107]=8'd0;
mem[108]=8'd0;
mem[109]=8'd0;
mem[110]=8'd0;
mem[111]=8'd0;
mem[112]=8'd0;
mem[113]=8'd0;
mem[114]=8'd0;
mem[115]=8'd0;
mem[116]=8'd0;
mem[117]=8'd0;
mem[118]=8'd0;
mem[119]=8'd0;
mem[120]=8'd0;
mem[121]=8'd0;
mem[122]=8'd0;
mem[123]=8'd0;
mem[124]=8'd0;
mem[125]=8'd0;
mem[126]=8'd0;
mem[127]=8'd0;
mem[128]=8'd0;
mem[129]=8'd0;
mem[130]=8'd0;
mem[131]=8'd0;
mem[132]=8'd0;
mem[133]=8'd0;
mem[134]=8'd0;
mem[135]=8'd0;
mem[136]=8'd0;
mem[137]=8'd0;
mem[138]=8'd0;
mem[139]=8'd0;
mem[140]=8'd0;
mem[141]=8'd0;
mem[142]=8'd0;
mem[143]=8'd0;
mem[144]=8'd0;
mem[145]=8'd0;
mem[146]=8'd0;
mem[147]=8'd0;
mem[148]=8'd0;
mem[149]=8'd0;
mem[150]=8'd0;
mem[151]=8'd0;
mem[152]=8'd0;
mem[153]=8'd0;
mem[154]=8'd0;
mem[155]=8'd0;
mem[156]=8'd0;
mem[157]=8'd0;
mem[158]=8'd0;
mem[159]=8'd0;
mem[160]=8'd0;
mem[161]=8'd0;
mem[162]=8'd0;
mem[163]=8'd0;
mem[164]=8'd0;
mem[165]=8'd0;
mem[166]=8'd0;
mem[167]=8'd0;
mem[168]=8'd0;
mem[169]=8'd0;
mem[170]=8'd0;
mem[171]=8'd0;
mem[172]=8'd0;
mem[173]=8'd0;
mem[174]=8'd0;
mem[175]=8'd0;
mem[176]=8'd0;
mem[177]=8'd0;
mem[178]=8'd0;
mem[179]=8'd0;
mem[180]=8'd0;
mem[181]=8'd0;
mem[182]=8'd0;
mem[183]=8'd0;
mem[184]=8'd0;
mem[185]=8'd0;
mem[186]=8'd0;
mem[187]=8'd0;
mem[188]=8'd0;
mem[189]=8'd0;
mem[190]=8'd0;
mem[191]=8'd0;
mem[192]=8'd0;
mem[193]=8'd0;
mem[194]=8'd0;
mem[195]=8'd0;
mem[196]=8'd0;
mem[197]=8'd0;
mem[198]=8'd0;
mem[199]=8'd0;
mem[200]=8'd0;
mem[201]=8'd0;
mem[202]=8'd0;
mem[203]=8'd0;
mem[204]=8'd0;
mem[205]=8'd0;
mem[206]=8'd0;
mem[207]=8'd0;
mem[208]=8'd0;
mem[209]=8'd0;
mem[210]=8'd0;
mem[211]=8'd0;
mem[212]=8'd0;
mem[213]=8'd0;
mem[214]=8'd0;
mem[215]=8'd0;
mem[216]=8'd0;
mem[217]=8'd0;
mem[218]=8'd0;
mem[219]=8'd0;
mem[220]=8'd0;
mem[221]=8'd0;
mem[222]=8'd0;
mem[223]=8'd0;
mem[224]=8'd0;
mem[225]=8'd0;
mem[226]=8'd0;
mem[227]=8'd0;
mem[228]=8'd0;
mem[229]=8'd0;
mem[230]=8'd0;
mem[231]=8'd0;
mem[232]=8'd0;
mem[233]=8'd0;
mem[234]=8'd0;
mem[235]=8'd0;
mem[236]=8'd0;
mem[237]=8'd0;
mem[238]=8'd0;
mem[239]=8'd0;
mem[240]=8'd0;
mem[241]=8'd0;
mem[242]=8'd0;
mem[243]=8'd0;
mem[244]=8'd0;
mem[245]=8'd0;
mem[246]=8'd0;
mem[247]=8'd0;
mem[248]=8'd0;
mem[249]=8'd0;
mem[250]=8'd0;
mem[251]=8'd0;
mem[252]=8'd0;
mem[253]=8'd0;
mem[254]=8'd0;
mem[255]=8'd0;
mem[256]=8'd0;
mem[257]=8'd0;
mem[258]=8'd0;
mem[259]=8'd0;
mem[260]=8'd0;
mem[261]=8'd0;
mem[262]=8'd0;
mem[263]=8'd0;
mem[264]=8'd0;
mem[265]=8'd0;
mem[266]=8'd0;
mem[267]=8'd0;
mem[268]=8'd0;
mem[269]=8'd0;
mem[270]=8'd0;
mem[271]=8'd0;
mem[272]=8'd0;
mem[273]=8'd0;
mem[274]=8'd0;
mem[275]=8'd0;
mem[276]=8'd0;
mem[277]=8'd0;
mem[278]=8'd0;
mem[279]=8'd0;
mem[280]=8'd0;
mem[281]=8'd0;
mem[282]=8'd0;
mem[283]=8'd0;
mem[284]=8'd0;
mem[285]=8'd0;
mem[286]=8'd0;
mem[287]=8'd0;
mem[288]=8'd0;
mem[289]=8'd0;
mem[290]=8'd0;
mem[291]=8'd0;
mem[292]=8'd0;
mem[293]=8'd0;
mem[294]=8'd0;
mem[295]=8'd0;
mem[296]=8'd0;
mem[297]=8'd0;
mem[298]=8'd0;
mem[299]=8'd0;
mem[300]=8'd0;
mem[301]=8'd0;
mem[302]=8'd0;
mem[303]=8'd0;
mem[304]=8'd0;
mem[305]=8'd0;
mem[306]=8'd0;
mem[307]=8'd0;
mem[308]=8'd0;
mem[309]=8'd0;
mem[310]=8'd0;
mem[311]=8'd0;
mem[312]=8'd0;
mem[313]=8'd0;
mem[314]=8'd0;
mem[315]=8'd0;
mem[316]=8'd0;
mem[317]=8'd0;
mem[318]=8'd0;
mem[319]=8'd0;
mem[320]=8'd0;
mem[321]=8'd0;
mem[322]=8'd0;
mem[323]=8'd0;
mem[324]=8'd0;
mem[325]=8'd0;
mem[326]=8'd0;
mem[327]=8'd0;
mem[328]=8'd0;
mem[329]=8'd0;
mem[330]=8'd0;
mem[331]=8'd0;
mem[332]=8'd0;
mem[333]=8'd0;
mem[334]=8'd0;
mem[335]=8'd0;
mem[336]=8'd0;
mem[337]=8'd0;
mem[338]=8'd0;
mem[339]=8'd0;
mem[340]=8'd0;
mem[341]=8'd0;
mem[342]=8'd0;
mem[343]=8'd0;
mem[344]=8'd0;
mem[345]=8'd0;
mem[346]=8'd0;
mem[347]=8'd0;
mem[348]=8'd0;
mem[349]=8'd0;
mem[350]=8'd0;
mem[351]=8'd0;
mem[352]=8'd0;
mem[353]=8'd0;
mem[354]=8'd0;
mem[355]=8'd0;
mem[356]=8'd0;
mem[357]=8'd0;
mem[358]=8'd0;
mem[359]=8'd0;
mem[360]=8'd0;
mem[361]=8'd0;
mem[362]=8'd0;
mem[363]=8'd0;
mem[364]=8'd0;
mem[365]=8'd0;
mem[366]=8'd0;
mem[367]=8'd0;
mem[368]=8'd0;
mem[369]=8'd0;
mem[370]=8'd0;
mem[371]=8'd0;
mem[372]=8'd0;
mem[373]=8'd0;
mem[374]=8'd0;
mem[375]=8'd0;
mem[376]=8'd0;
mem[377]=8'd0;
mem[378]=8'd0;
mem[379]=8'd0;
mem[380]=8'd0;
mem[381]=8'd0;
mem[382]=8'd0;
mem[383]=8'd0;
mem[384]=8'd0;
mem[385]=8'd0;
mem[386]=8'd0;
mem[387]=8'd0;
mem[388]=8'd0;
mem[389]=8'd0;
mem[390]=8'd0;
mem[391]=8'd0;
mem[392]=8'd0;
mem[393]=8'd0;
mem[394]=8'd0;
mem[395]=8'd0;
mem[396]=8'd0;
mem[397]=8'd0;
mem[398]=8'd0;
mem[399]=8'd0;
mem[400]=8'd0;
mem[401]=8'd0;
mem[402]=8'd0;
mem[403]=8'd0;
mem[404]=8'd0;
mem[405]=8'd0;
mem[406]=8'd0;
mem[407]=8'd0;
mem[408]=8'd0;
mem[409]=8'd0;
mem[410]=8'd0;
mem[411]=8'd0;
mem[412]=8'd0;
mem[413]=8'd0;
mem[414]=8'd0;
mem[415]=8'd0;
mem[416]=8'd0;
mem[417]=8'd0;
mem[418]=8'd0;
mem[419]=8'd0;
mem[420]=8'd0;
mem[421]=8'd0;
mem[422]=8'd0;
mem[423]=8'd0;
mem[424]=8'd0;
mem[425]=8'd0;
mem[426]=8'd0;
mem[427]=8'd0;
mem[428]=8'd0;
mem[429]=8'd0;
mem[430]=8'd0;
mem[431]=8'd0;
mem[432]=8'd0;
mem[433]=8'd0;
mem[434]=8'd0;
mem[435]=8'd0;
mem[436]=8'd0;
mem[437]=8'd0;
mem[438]=8'd0;
mem[439]=8'd0;
mem[440]=8'd0;
mem[441]=8'd0;
mem[442]=8'd0;
mem[443]=8'd0;
mem[444]=8'd0;
mem[445]=8'd0;
mem[446]=8'd0;
mem[447]=8'd0;
mem[448]=8'd0;
mem[449]=8'd0;
mem[450]=8'd0;
mem[451]=8'd0;
mem[452]=8'd0;
mem[453]=8'd0;
mem[454]=8'd0;
mem[455]=8'd0;
mem[456]=8'd0;
mem[457]=8'd0;
mem[458]=8'd0;
mem[459]=8'd0;
mem[460]=8'd0;
mem[461]=8'd0;
mem[462]=8'd0;
mem[463]=8'd0;
mem[464]=8'd0;
mem[465]=8'd0;
mem[466]=8'd0;
mem[467]=8'd0;
mem[468]=8'd0;
mem[469]=8'd0;
mem[470]=8'd0;
mem[471]=8'd0;
mem[472]=8'd0;
mem[473]=8'd0;
mem[474]=8'd0;
mem[475]=8'd0;
mem[476]=8'd0;
mem[477]=8'd0;
mem[478]=8'd0;
mem[479]=8'd0;
mem[480]=8'd0;
mem[481]=8'd0;
mem[482]=8'd0;
mem[483]=8'd0;
mem[484]=8'd0;
mem[485]=8'd0;
mem[486]=8'd0;
mem[487]=8'd0;
mem[488]=8'd0;
mem[489]=8'd0;
mem[490]=8'd0;
mem[491]=8'd0;
mem[492]=8'd0;
mem[493]=8'd0;
mem[494]=8'd0;
mem[495]=8'd0;
mem[496]=8'd0;
mem[497]=8'd0;
mem[498]=8'd0;
mem[499]=8'd0;
mem[500]=8'd0;
mem[501]=8'd0;
mem[502]=8'd0;
mem[503]=8'd0;
mem[504]=8'd0;
mem[505]=8'd0;
mem[506]=8'd0;
mem[507]=8'd0;
mem[508]=8'd0;
mem[509]=8'd0;
mem[510]=8'd0;
mem[511]=8'd0;
mem[512]=8'd0;
mem[513]=8'd0;
mem[514]=8'd0;
mem[515]=8'd0;
mem[516]=8'd0;
mem[517]=8'd0;
mem[518]=8'd0;
mem[519]=8'd0;
mem[520]=8'd0;
mem[521]=8'd0;
mem[522]=8'd0;
mem[523]=8'd0;
mem[524]=8'd0;
mem[525]=8'd0;
mem[526]=8'd0;
mem[527]=8'd0;
mem[528]=8'd0;
mem[529]=8'd0;
mem[530]=8'd0;
mem[531]=8'd0;
mem[532]=8'd0;
mem[533]=8'd0;
mem[534]=8'd0;
mem[535]=8'd0;
mem[536]=8'd0;
mem[537]=8'd0;
mem[538]=8'd0;
mem[539]=8'd0;
mem[540]=8'd0;
mem[541]=8'd0;
mem[542]=8'd0;
mem[543]=8'd0;
mem[544]=8'd0;
mem[545]=8'd0;
mem[546]=8'd0;
mem[547]=8'd0;
mem[548]=8'd0;
mem[549]=8'd0;
mem[550]=8'd0;
mem[551]=8'd0;
mem[552]=8'd0;
mem[553]=8'd0;
mem[554]=8'd0;
mem[555]=8'd0;
mem[556]=8'd0;
mem[557]=8'd0;
mem[558]=8'd0;
mem[559]=8'd0;
mem[560]=8'd0;
mem[561]=8'd0;
mem[562]=8'd0;
mem[563]=8'd0;
mem[564]=8'd0;
mem[565]=8'd0;
mem[566]=8'd0;
mem[567]=8'd0;
mem[568]=8'd0;
mem[569]=8'd0;
mem[570]=8'd0;
mem[571]=8'd0;
mem[572]=8'd0;
mem[573]=8'd0;
mem[574]=8'd0;
mem[575]=8'd0;
mem[576]=8'd0;
mem[577]=8'd0;
mem[578]=8'd0;
mem[579]=8'd0;
mem[580]=8'd0;
mem[581]=8'd0;
mem[582]=8'd0;
mem[583]=8'd0;
mem[584]=8'd0;
mem[585]=8'd0;
mem[586]=8'd0;
mem[587]=8'd0;
mem[588]=8'd0;
mem[589]=8'd0;
mem[590]=8'd0;
mem[591]=8'd0;
mem[592]=8'd0;
mem[593]=8'd0;
mem[594]=8'd0;
mem[595]=8'd0;
mem[596]=8'd0;
mem[597]=8'd0;
mem[598]=8'd0;
mem[599]=8'd0;
mem[600]=8'd0;
mem[601]=8'd0;
mem[602]=8'd0;
mem[603]=8'd0;
mem[604]=8'd0;
mem[605]=8'd0;
mem[606]=8'd0;
mem[607]=8'd0;
mem[608]=8'd0;
mem[609]=8'd0;
mem[610]=8'd0;
mem[611]=8'd0;
mem[612]=8'd0;
mem[613]=8'd0;
mem[614]=8'd0;
mem[615]=8'd0;
mem[616]=8'd0;
mem[617]=8'd0;
mem[618]=8'd0;
mem[619]=8'd0;
mem[620]=8'd0;
mem[621]=8'd0;
mem[622]=8'd0;
mem[623]=8'd0;
mem[624]=8'd0;
mem[625]=8'd0;
mem[626]=8'd0;
mem[627]=8'd0;
mem[628]=8'd0;
mem[629]=8'd0;
mem[630]=8'd0;
mem[631]=8'd0;
mem[632]=8'd0;
mem[633]=8'd0;
mem[634]=8'd0;
mem[635]=8'd0;
mem[636]=8'd0;
mem[637]=8'd0;
mem[638]=8'd0;
mem[639]=8'd0;
mem[640]=8'd0;
mem[641]=8'd0;
mem[642]=8'd0;
mem[643]=8'd0;
mem[644]=8'd0;
mem[645]=8'd0;
mem[646]=8'd0;
mem[647]=8'd0;
mem[648]=8'd0;
mem[649]=8'd0;
mem[650]=8'd0;
mem[651]=8'd0;
mem[652]=8'd0;
mem[653]=8'd0;
mem[654]=8'd0;
mem[655]=8'd0;
mem[656]=8'd0;
mem[657]=8'd0;
mem[658]=8'd0;
mem[659]=8'd0;
mem[660]=8'd0;
mem[661]=8'd0;
mem[662]=8'd0;
mem[663]=8'd0;
mem[664]=8'd0;
mem[665]=8'd0;
mem[666]=8'd0;
mem[667]=8'd0;
mem[668]=8'd0;
mem[669]=8'd0;
mem[670]=8'd0;
mem[671]=8'd0;
mem[672]=8'd0;
mem[673]=8'd0;
mem[674]=8'd0;
mem[675]=8'd0;
mem[676]=8'd0;
mem[677]=8'd0;
mem[678]=8'd0;
mem[679]=8'd0;
mem[680]=8'd0;
mem[681]=8'd0;
mem[682]=8'd0;
mem[683]=8'd0;
mem[684]=8'd0;
mem[685]=8'd0;
mem[686]=8'd0;
mem[687]=8'd0;
mem[688]=8'd0;
mem[689]=8'd0;
mem[690]=8'd0;
mem[691]=8'd0;
mem[692]=8'd0;
mem[693]=8'd0;
mem[694]=8'd0;
mem[695]=8'd0;
mem[696]=8'd0;
mem[697]=8'd0;
mem[698]=8'd0;
mem[699]=8'd0;
mem[700]=8'd0;
mem[701]=8'd0;
mem[702]=8'd0;
mem[703]=8'd0;
mem[704]=8'd0;
mem[705]=8'd0;
mem[706]=8'd0;
mem[707]=8'd0;
mem[708]=8'd0;
mem[709]=8'd0;
mem[710]=8'd0;
mem[711]=8'd0;
mem[712]=8'd0;
mem[713]=8'd0;
mem[714]=8'd0;
mem[715]=8'd0;
mem[716]=8'd0;
mem[717]=8'd0;
mem[718]=8'd0;
mem[719]=8'd0;
mem[720]=8'd0;
mem[721]=8'd0;
mem[722]=8'd0;
mem[723]=8'd0;
mem[724]=8'd0;
mem[725]=8'd0;
mem[726]=8'd0;
mem[727]=8'd0;
mem[728]=8'd0;
mem[729]=8'd0;
mem[730]=8'd0;
mem[731]=8'd0;
mem[732]=8'd0;
mem[733]=8'd0;
mem[734]=8'd0;
mem[735]=8'd0;
mem[736]=8'd0;
mem[737]=8'd0;
mem[738]=8'd0;
mem[739]=8'd0;
mem[740]=8'd0;
mem[741]=8'd0;
mem[742]=8'd0;
mem[743]=8'd0;
mem[744]=8'd0;
mem[745]=8'd0;
mem[746]=8'd0;
mem[747]=8'd0;
mem[748]=8'd0;
mem[749]=8'd0;
mem[750]=8'd0;
mem[751]=8'd0;
mem[752]=8'd0;
mem[753]=8'd0;
mem[754]=8'd0;
mem[755]=8'd0;
mem[756]=8'd0;
mem[757]=8'd0;
mem[758]=8'd0;
mem[759]=8'd0;
mem[760]=8'd0;
mem[761]=8'd0;
mem[762]=8'd0;
mem[763]=8'd0;
mem[764]=8'd0;
mem[765]=8'd0;
mem[766]=8'd0;
mem[767]=8'd0;
mem[768]=8'd0;
mem[769]=8'd0;
mem[770]=8'd0;
mem[771]=8'd0;
mem[772]=8'd0;
mem[773]=8'd0;
mem[774]=8'd0;
mem[775]=8'd0;
mem[776]=8'd0;
mem[777]=8'd0;
mem[778]=8'd0;
mem[779]=8'd0;
mem[780]=8'd0;
mem[781]=8'd0;
mem[782]=8'd0;
mem[783]=8'd0;
mem[784]=8'd0;
mem[785]=8'd0;
mem[786]=8'd0;
mem[787]=8'd0;
mem[788]=8'd0;
mem[789]=8'd0;
mem[790]=8'd0;
mem[791]=8'd0;
mem[792]=8'd0;
mem[793]=8'd0;
mem[794]=8'd0;
mem[795]=8'd0;
mem[796]=8'd0;
mem[797]=8'd0;
mem[798]=8'd0;
mem[799]=8'd0;
mem[800]=8'd0;
mem[801]=8'd0;
mem[802]=8'd0;
mem[803]=8'd0;
mem[804]=8'd0;
mem[805]=8'd0;
mem[806]=8'd0;
mem[807]=8'd0;
mem[808]=8'd0;
mem[809]=8'd0;
mem[810]=8'd0;
mem[811]=8'd0;
mem[812]=8'd0;
mem[813]=8'd0;
mem[814]=8'd0;
mem[815]=8'd0;
mem[816]=8'd0;
mem[817]=8'd0;
mem[818]=8'd0;
mem[819]=8'd0;
mem[820]=8'd0;
mem[821]=8'd0;
mem[822]=8'd0;
mem[823]=8'd0;
mem[824]=8'd0;
mem[825]=8'd0;
mem[826]=8'd0;
mem[827]=8'd0;
mem[828]=8'd0;
mem[829]=8'd0;
mem[830]=8'd0;
mem[831]=8'd0;
mem[832]=8'd0;
mem[833]=8'd0;
mem[834]=8'd0;
mem[835]=8'd0;
mem[836]=8'd0;
mem[837]=8'd0;
mem[838]=8'd0;
mem[839]=8'd0;
mem[840]=8'd0;
mem[841]=8'd0;
mem[842]=8'd0;
mem[843]=8'd0;
mem[844]=8'd0;
mem[845]=8'd0;
mem[846]=8'd0;
mem[847]=8'd0;
mem[848]=8'd0;
mem[849]=8'd0;
mem[850]=8'd0;
mem[851]=8'd0;
mem[852]=8'd0;
mem[853]=8'd0;
mem[854]=8'd0;
mem[855]=8'd0;
mem[856]=8'd0;
mem[857]=8'd0;
mem[858]=8'd0;
mem[859]=8'd0;
mem[860]=8'd0;
mem[861]=8'd0;
mem[862]=8'd0;
mem[863]=8'd0;
mem[864]=8'd0;
mem[865]=8'd0;
mem[866]=8'd0;
mem[867]=8'd0;
mem[868]=8'd0;
mem[869]=8'd0;
mem[870]=8'd0;
mem[871]=8'd0;
mem[872]=8'd0;
mem[873]=8'd0;
mem[874]=8'd0;
mem[875]=8'd0;
mem[876]=8'd0;
mem[877]=8'd0;
mem[878]=8'd0;
mem[879]=8'd0;
mem[880]=8'd0;
mem[881]=8'd0;
mem[882]=8'd0;
mem[883]=8'd0;
mem[884]=8'd0;
mem[885]=8'd0;
mem[886]=8'd0;
mem[887]=8'd0;
mem[888]=8'd0;
mem[889]=8'd0;
mem[890]=8'd0;
mem[891]=8'd0;
mem[892]=8'd0;
mem[893]=8'd0;
mem[894]=8'd0;
mem[895]=8'd0;
mem[896]=8'd0;
mem[897]=8'd0;
mem[898]=8'd0;
mem[899]=8'd0;
mem[900]=8'd0;
mem[901]=8'd0;
mem[902]=8'd0;
mem[903]=8'd0;
mem[904]=8'd0;
mem[905]=8'd0;
mem[906]=8'd0;
mem[907]=8'd0;
mem[908]=8'd0;
mem[909]=8'd0;
mem[910]=8'd0;
mem[911]=8'd0;
mem[912]=8'd0;
mem[913]=8'd0;
mem[914]=8'd0;
mem[915]=8'd0;
mem[916]=8'd0;
mem[917]=8'd0;
mem[918]=8'd0;
mem[919]=8'd0;
mem[920]=8'd0;
mem[921]=8'd0;
mem[922]=8'd0;
mem[923]=8'd0;
mem[924]=8'd0;
mem[925]=8'd0;
mem[926]=8'd0;
mem[927]=8'd0;
mem[928]=8'd0;
mem[929]=8'd0;
mem[930]=8'd0;
mem[931]=8'd0;
mem[932]=8'd0;
mem[933]=8'd0;
mem[934]=8'd0;
mem[935]=8'd0;
mem[936]=8'd0;
mem[937]=8'd0;
mem[938]=8'd0;
mem[939]=8'd0;
mem[940]=8'd0;
mem[941]=8'd0;
mem[942]=8'd0;
mem[943]=8'd0;
mem[944]=8'd0;
mem[945]=8'd0;
mem[946]=8'd0;
mem[947]=8'd0;
mem[948]=8'd0;
mem[949]=8'd0;
mem[950]=8'd0;
mem[951]=8'd0;
mem[952]=8'd0;
mem[953]=8'd0;
mem[954]=8'd0;
mem[955]=8'd0;
mem[956]=8'd0;
mem[957]=8'd0;
mem[958]=8'd0;
mem[959]=8'd0;
mem[960]=8'd0;
mem[961]=8'd0;
mem[962]=8'd0;
mem[963]=8'd0;
mem[964]=8'd0;
mem[965]=8'd0;
mem[966]=8'd0;
mem[967]=8'd0;
mem[968]=8'd0;
mem[969]=8'd0;
mem[970]=8'd0;
mem[971]=8'd0;
mem[972]=8'd0;
mem[973]=8'd0;
mem[974]=8'd0;
mem[975]=8'd0;
mem[976]=8'd0;
mem[977]=8'd0;
mem[978]=8'd0;
mem[979]=8'd0;
mem[980]=8'd0;
mem[981]=8'd0;
mem[982]=8'd0;
mem[983]=8'd0;
mem[984]=8'd0;
mem[985]=8'd0;
mem[986]=8'd0;
mem[987]=8'd0;
mem[988]=8'd0;
mem[989]=8'd0;
mem[990]=8'd0;
mem[991]=8'd0;
mem[992]=8'd0;
mem[993]=8'd0;
mem[994]=8'd0;
mem[995]=8'd0;
mem[996]=8'd0;
mem[997]=8'd0;
mem[998]=8'd0;
mem[999]=8'd0;
mem[1000]=8'd0;
mem[1001]=8'd0;
mem[1002]=8'd0;
mem[1003]=8'd0;
mem[1004]=8'd0;
mem[1005]=8'd0;
mem[1006]=8'd0;
mem[1007]=8'd0;
mem[1008]=8'd0;
mem[1009]=8'd0;
mem[1010]=8'd0;
mem[1011]=8'd0;
mem[1012]=8'd0;
mem[1013]=8'd0;
mem[1014]=8'd0;
mem[1015]=8'd0;
mem[1016]=8'd0;
mem[1017]=8'd0;
mem[1018]=8'd0;
mem[1019]=8'd0;
mem[1020]=8'd0;
mem[1021]=8'd0;
mem[1022]=8'd0;
mem[1023]=8'd0;
end
always @(posedge clk)begin ra<=mem[a];rb<=mem[b];end
`else
wire [8:0] ra,rb;assign qa=ra[7:0];assign qb=rb[7:0];
EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),.GSR("DISABLE"),
.INIT_00(256'hf7f7f7f7f7f7f7f7f7f7f7f7eaddd0c3b6a99c8f8275685b4e4134271a0d00f7),
.INIT_01(256'h9386796c5f5245382b1e11fff7eaddd0c3b6a99c8f8275685b4e4134271a0d00),
.INIT_02(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_03(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_04(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_05(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_06(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_07(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_08(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_09(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_0A(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_0B(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_0C(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_0D(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_0E(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_0F(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_10(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_11(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_12(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_13(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_14(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_15(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_16(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_17(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_18(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_19(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_1A(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_1B(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_1C(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_1D(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_1E(256'h0000000000000000000000000000000000000000000000000000000000000000),
.INIT_1F(256'h0000000000000000000000000000000000000000000000000000000000000000)) u_rom(
.clka(clk),.cea(1'b1),.ocea(1'b1),.rsta(1'b0),.wea(1'b0),.csa(3'b111),.addra({a,3'b000}),.dia(9'd0),.doa(ra),
.clkb(clk),.ceb(1'b1),.oceb(1'b1),.rstb(1'b0),.web(1'b0),.csb(3'b111),.addrb({b,3'b000}),.dib(9'd0),.dob(rb));
`endif
endmodule
