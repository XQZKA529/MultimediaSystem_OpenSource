`timescale 1ns/1ps
module tb_fat32_ro;
parameter FILE_MAX_BURST=4;
reg clk=0,rst=1; always #5 clk=~clk;
wire [6:0] observed_state=dut.state_encoded;
wire [7:0] observed_diagnostic=dut.state;
wire [7:0] expected_diagnostic={1'b0,observed_state};
always @(negedge clk) if(!rst) begin
 if((observed_state ^ observed_state)!==7'd0 || observed_state>=74)
  $fatal(1,"FAT control state is undefined/out of range: %h",observed_state);
 if(observed_diagnostic!==expected_diagnostic) $fatal(1,"FAT diagnostic state disagrees with control");
end
reg mount_start=0,dir_start=0,file_start=0;
reg [31:0] file_first_cluster=0,file_size=0,file_read_limit=0;
reg file_read_ready=1,file_abort=0;
wire file_busy,operation_idle;
wire blk_req;wire [31:0] blk_lba;wire [15:0] blk_count;
reg blk_grant=0;reg [7:0] blk_data=0;reg blk_data_valid=0,blk_end=0,blk_error=0;
wire mount_done,mount_ok;wire [7:0] fat_error_code;
wire dir_entry_start,dir_name_valid,dir_entry_end,dir_done,dir_ok;
wire [7:0] dir_name_char,dir_name_index,dir_entry_name_len,dir_entry_attr;
wire [31:0] dir_entry_first_cluster,dir_entry_size;
wire dir_entry_is_dir,dir_entry_is_lfn;
wire [7:0] file_data;wire file_data_valid,file_done,file_ok;
reg map_start=0, map_abort=0;
reg [31:0] map_first_cluster=0, map_size=0;
wire map_busy, map_done, map_ok, map_entry_valid, map_entry_last;
wire map_accept;
wire [31:0] map_entry_lba;
wire [31:0] map_entry_nsec;
wire [7:0] dbg_fat_state;wire [31:0] dbg_dir_entry_count;

reg [7:0] disk[0:131071];
reg busy=0;integer pos=0,total=0,base=0;integer errors=0,file_seen=0;integer got=0;reg testing_cycle=0;
reg testing_multiblock=0;
reg expect_lfn=1;
integer max_blk_count=0;
integer map_seen=0;
reg [31:0] queued_map_lba[0:1],queued_map_nsec[0:1];
reg queued_map_last[0:1];
reg [8*255-1:0] name_capture;integer name_len=0;

fat32_ro #(.FILE_MAX_BURST(FILE_MAX_BURST)) dut(.*);

task put16; input integer a;input [15:0]v;begin disk[a]=v[7:0];disk[a+1]=v[15:8];end endtask
task put32; input integer a;input [31:0]v;begin disk[a]=v[7:0];disk[a+1]=v[15:8];disk[a+2]=v[23:16];disk[a+3]=v[31:24];end endtask
function [7:0] csum;
 input [8*11-1:0] s;integer q;reg[7:0]x;begin x=0;for(q=0;q<11;q=q+1)x=((x&1)?8'h80:0)+(x>>1)+s[(10-q)*8+:8];csum=x;end
endfunction
task lfnchar;input integer ent;input integer n;input [15:0]v;integer o;begin
 case(n)0:o=1;1:o=3;2:o=5;3:o=7;4:o=9;5:o=14;6:o=16;7:o=18;8:o=20;9:o=22;10:o=24;11:o=28;default:o=30;endcase
 put16(ent+o,v);end endtask

integer i,geometry,geometry_byte;reg[7:0] sum;reg[8*11-1:0] sfn;
initial begin
 for(i=0;i<131072;i=i+1)disk[i]=0;
 // MBR, FAT32 partition at LBA 10
 disk[510]=8'h55;disk[511]=8'haa;disk[450]=8'h0c;put32(454,10);put32(458,1000);
 // DBR: reserved=1, eight FAT sectors, one sector/cluster, root cluster 2
 base=10*512;put16(base+11,512);disk[base+13]=1;put16(base+14,1);disk[base+16]=1;
 put32(base+32,1000);put32(base+36,8);put32(base+44,2);disk[base+510]=8'h55;disk[base+511]=8'haa;
 // FAT at LBA11: root 2 EOC, file chain 3 -> 5 -> EOC
 base=11*512;put32(base+0,32'h0ffffff8);put32(base+4,32'h0fffffff);
 put32(base+8,32'h0fffffff);put32(base+12,5);put32(base+20,32'h0fffffff);
 // SFN and checksum
 sfn="LONGPI~1BMP";sum=csum(sfn);
 base=19*512;
 // LFN entry ordinal 2 LAST: chars 13..15 = BMP, then terminator
 disk[base]=8'h42;disk[base+11]=8'h0f;disk[base+13]=sum;
 lfnchar(base,0,"B");lfnchar(base,1,"M");lfnchar(base,2,"P");lfnchar(base,3,0);
 for(i=4;i<13;i=i+1)lfnchar(base,i,16'hffff);
 // ordinal 1: "Long Picture."
 base=19*512+32;disk[base]=1;disk[base+11]=8'h0f;disk[base+13]=sum;
 lfnchar(base,0,"L");lfnchar(base,1,"o");lfnchar(base,2,"n");lfnchar(base,3,"g");
 lfnchar(base,4," ");lfnchar(base,5,"P");lfnchar(base,6,"i");lfnchar(base,7,"c");
 lfnchar(base,8,"t");lfnchar(base,9,"u");lfnchar(base,10,"r");lfnchar(base,11,"e");lfnchar(base,12,".");
 // matching SFN
 base=19*512+64;
 disk[base+0]="L";disk[base+1]="O";disk[base+2]="N";disk[base+3]="G";disk[base+4]="P";
 disk[base+5]="I";disk[base+6]="~";disk[base+7]="1";disk[base+8]="B";disk[base+9]="M";disk[base+10]="P";
 disk[base+11]=8'h20;put16(base+26,3);put32(base+28,600);disk[base+32]=0;
 // fragmented file payload
 for(i=0;i<512;i=i+1)disk[20*512+i]=i[7:0];
 for(i=0;i<512;i=i+1)disk[22*512+i]=8'ha0+i[7:0];
 #40 rst=0;#20;mount_start=1;#10 mount_start=0;
 wait(mount_done); if(!mount_ok)begin $display("mount failed %0d",fat_error_code);errors=errors+1;end
 #20 dir_start=1;#10 dir_start=0;wait(dir_done);
 if(!dir_ok||file_seen!=1)begin $display("dir failed ok=%b seen=%0d err=%0d",dir_ok,file_seen,fat_error_code);errors=errors+1;end
 if(name_len!=16)begin $display("LFN length bad %0d",name_len);errors=errors+1;end
 if(name_capture[8*255-1 -: 8*16]!=="Long Picture.BMP")begin
   $display("LFN text mismatch");errors=errors+1;
 end
 // A damaged LFN checksum must fall back to the unchanged 8.3 alias.
 disk[19*512+13]=sum^8'h01;expect_lfn=0;
 #20;dir_start=1;#10 dir_start=0;wait(dir_done);
 if(!dir_ok||name_len!=12||name_capture[8*255-1 -: 8*12]!=="LONGPI~1.BMP")begin
   $display("SFN fallback mismatch len=%0d",name_len);errors=errors+1;
 end
 disk[19*512+13]=sum;expect_lfn=1;
 // Hold downstream flow control closed: file data must not start until one
 // complete sector can be accepted.
 file_read_ready=0;
 #20;file_first_cluster=3;file_size=600;file_read_limit=0;file_start=1;#10 file_start=0;
 repeat(100) @(posedge clk);
 if(got!=0)begin $display("file flow control leaked data got=%0d",got);errors=errors+1;end
 // Queue a map while the file owns the working context. The pending request
 // must preserve its own cluster/length without changing the live file.
 @(negedge clk);map_first_cluster=3;map_size=600;map_start=1;
 @(negedge clk);map_start=0;
 file_read_ready=1;
 wait(file_done);if(!file_ok||got!=600)begin $display("file failed ok=%b got=%0d err=%0d",file_ok,got,fat_error_code);errors=errors+1;end
 wait(map_done);repeat(2)@(negedge clk);
 if(!map_ok||map_seen!=2||queued_map_lba[0]!=20||queued_map_lba[1]!=22||
    queued_map_nsec[0]!=1||queued_map_nsec[1]!=1||queued_map_last[0]||!queued_map_last[1])begin
   $display("queued map context corrupted ok=%b segments=%0d",map_ok,map_seen);errors=errors+1;
 end
 // Read actual data at cluster 3 for every legal FAT32 cluster geometry.
 // This checks both the mount shift and the resulting SD LBA, not only a
 // private register's encoding. Invalid geometries retain their error code.
 testing_multiblock=1;
 for(geometry=0;geometry<8;geometry=geometry+1)begin
   disk[10*512+13]=1<<geometry;
   for(geometry_byte=0;geometry_byte<16;geometry_byte=geometry_byte+1)
     disk[(19+(1<<geometry))*512+geometry_byte]=geometry_byte;
   #20;mount_start=1;#10 mount_start=0;wait(mount_done);
   if(!mount_ok)begin $display("valid cluster geometry rejected %0d",1<<geometry);errors=errors+1;end
   got=0;#20;file_first_cluster=3;file_size=16;file_read_limit=0;file_start=1;#10 file_start=0;
   wait(file_done);
   if(!file_ok||got!=16)begin $display("geometry read failed spc=%0d got=%0d",1<<geometry,got);errors=errors+1;end
 end
 for(geometry=0;geometry<3;geometry=geometry+1)begin
   case(geometry)0:disk[10*512+13]=0;1:disk[10*512+13]=3;default:disk[10*512+13]=255;endcase
   #20;mount_start=1;#10 mount_start=0;wait(mount_done);
   if(mount_ok||fat_error_code!=4)begin
     $display("invalid cluster geometry accepted spc=%0d err=%0d",disk[10*512+13],fat_error_code);errors=errors+1;
   end
 end
 // Re-enter directory traversal after file/map activity. With two sectors
 // per cluster, a full sector of deleted entries must advance to LBA 20.
 // This catches ownership/initialization mistakes in the shared sector index.
 disk[10*512+13]=2;
 for(geometry_byte=0;geometry_byte<16;geometry_byte=geometry_byte+1)
   disk[19*512+geometry_byte*32]=8'he5;
 for(geometry_byte=0;geometry_byte<512;geometry_byte=geometry_byte+1)
   disk[20*512+geometry_byte]=0;
 for(geometry_byte=0;geometry_byte<11;geometry_byte=geometry_byte+1)
   disk[20*512+geometry_byte]=sfn[(10-geometry_byte)*8+:8];
 disk[20*512+11]=8'h20;put16(20*512+26,3);put32(20*512+28,600);
 expect_lfn=0;
 #20;mount_start=1;#10 mount_start=0;wait(mount_done);
 #20;dir_start=1;#10 dir_start=0;wait(dir_done);
 if(!dir_ok||file_seen!=3||name_len!=12||name_capture[8*255-1 -: 8*12]!=="LONGPI~1.BMP")begin
   $display("directory sector advance/context failed seen=%0d len=%0d",file_seen,name_len);errors=errors+1;
 end
 // Remount with the real-card geometry (64 KiB = 128 sectors/cluster) and
 // verify that a 32-KiB file is split into <=4-sector CMD18 bursts.
 disk[10*512+13]=128;put32(11*512+12,32'h0fffffff);
 for(i=0;i<32768;i=i+1)disk[147*512+i]=i[7:0];
 max_blk_count=0;got=0;testing_multiblock=1;
 #20;mount_start=1;#10 mount_start=0;wait(mount_done);
 #20;file_first_cluster=3;file_size=32768;file_read_limit=0;file_start=1;#10 file_start=0;
 wait(file_done);if(!file_ok||got!=32768||max_blk_count!=FILE_MAX_BURST)begin
   $display("multiblock failed ok=%b got=%0d max_count=%0d",file_ok,got,max_blk_count);errors=errors+1;
 end
 // Abort a live burst.  The service must drain the granted physical burst,
 // suppress remaining bytes, then return idle with the dedicated abort code.
 got=0;#20;file_start=1;#10 file_start=0;wait(got>=32);
 file_abort=1;repeat(2)@(posedge clk);file_abort=0;wait(file_done);
 // file_busy 现在是打一拍的空闲指示（RTL 重定时：出模块前寄存）。
// file_done 拍 state 才回 S_IDLE，file_busy_r 在下一沿计算、再下一沿才对
// 本过程可见——共需两个 posedge 后采样。
 repeat(2) @(posedge clk);
 if(file_ok||fat_error_code!=11||file_busy)begin
   $display("abort failed ok=%b err=%0d busy=%b",file_ok,fat_error_code,file_busy);errors=errors+1;
 end
 // Maximum FAT32 file size: ceil(0xffffffff / 65536) must be 65536,
 // and the first read still obeys the four-sector burst credit.
 file_size=32'hffffffff;file_read_limit=0;got=0;
 #20;file_start=1;#10 file_start=0;wait(dut.state==30);#1;
 if(dut.file_hop_limit!=65536)begin $display("max file hop bound overflow %0d",dut.file_hop_limit);errors=errors+1;end
 file_abort=1;repeat(3)@(negedge clk);file_abort=0;wait(file_done);#20;
 // Remount to invalidate the FAT cache, then verify a 3->5->3 loop is rejected.
 disk[10*512+13]=1;
 put32(11*512+12,5);put32(11*512+20,3);testing_cycle=1;testing_multiblock=0;got=0;
 #20;mount_start=1;#10 mount_start=0;wait(mount_done);
 #20;file_first_cluster=3;file_size=2048;file_read_limit=0;file_start=1;#10 file_start=0;
 wait(file_done);if(file_ok||fat_error_code!=9)begin $display("cycle not rejected ok=%b err=%0d",file_ok,fat_error_code);errors=errors+1;end
 // The MBR scanner must find a later slot and reset its choice on remount.
 disk[450]=0;put32(454,0);disk[482]=8'h0c;put32(486,10);put32(490,1000);
 #20;mount_start=1;#10 mount_start=0;wait(mount_done);
 if(!mount_ok||dut.partition_lba!=10)begin
   $display("third MBR slot not selected ok=%b lba=%0d",mount_ok,dut.partition_lba);errors=errors+1;
 end
 put16(10*512+17,1);
 #20;mount_start=1;#10 mount_start=0;wait(mount_done);
 if(mount_ok||fat_error_code!=4)begin
   $display("nonzero root entries accepted ok=%b err=%0d",mount_ok,fat_error_code);errors=errors+1;
 end
 put16(10*512+17,0);
 disk[482]=0;
 #20;mount_start=1;#10 mount_start=0;wait(mount_done);
 if(mount_ok||fat_error_code!=2)begin
   $display("empty MBR accepted ok=%b err=%0d",mount_ok,fat_error_code);errors=errors+1;
 end
 // Sector zero can itself be the VBR. Its boot-code area overlaps the MBR
 // slot offsets and may look like a partition table; the VBR takes priority.
 for(i=0;i<512;i=i+1)disk[i]=disk[10*512+i];
 disk[450]=8'h0c;put32(454,29);put32(458,128);
 for(i=0;i<8*512;i=i+1)disk[512+i]=disk[11*512+i];
 for(i=0;i<512;i=i+1)disk[9*512+i]=0;
 #20;mount_start=1;#10 mount_start=0;wait(mount_done);
 if(!mount_ok || dut.partition_lba!=0 || dut.partition_sectors!=0)begin
   $display("superfloppy boot code polluted partition base ok=%b lba=%0d sectors=%0d",mount_ok,dut.partition_lba,dut.partition_sectors);errors=errors+1;
 end
 #20;dir_start=1;#10 dir_start=0;wait(dir_done);
 if(!dir_ok)begin $display("superfloppy root directory failed err=%0d",fat_error_code);errors=errors+1;end
 // The following partitioned remount must still select its real partition.
 for(i=0;i<512;i=i+1)disk[i]=0;
 disk[510]=8'h55;disk[511]=8'haa;disk[450]=8'h0c;put32(454,10);put32(458,1000);
 #20;mount_start=1;#10 mount_start=0;wait(mount_done);
 if(!mount_ok || dut.partition_lba!=10)begin
   $display("partitioned remount after superfloppy failed ok=%b lba=%0d",mount_ok,dut.partition_lba);errors=errors+1;
 end
 if(errors==0)$display("*** PASS *** FAT32 MBR/LFN/SFN/all cluster geometries/fragmented file/cycle guard/superfloppy boot-code isolation/remount");else $display("*** FAIL *** errors=%0d",errors);
 #20;$finish;
end

always @(posedge clk) begin
 blk_grant<=0;blk_data_valid<=0;blk_end<=0;
 if(blk_req&&!busy)begin
   busy<=1;blk_grant<=1;base<=blk_lba*512;pos<=0;total<=blk_count*512;
   if(blk_count>max_blk_count)max_blk_count=blk_count;
 end
 else if(busy)begin
   if(pos<total)begin blk_data<=disk[base+pos];blk_data_valid<=1;pos<=pos+1;end
   else begin blk_end<=1;busy<=0;end
 end
 if(dir_entry_start)begin name_len=0;name_capture=0;end
 if(map_entry_valid)begin
   if(map_seen<2)begin queued_map_lba[map_seen]=map_entry_lba;queued_map_nsec[map_seen]=map_entry_nsec;queued_map_last[map_seen]=map_entry_last;end
   map_seen=map_seen+1;
 end
 if(dir_name_valid)begin name_capture[(254-name_len)*8+:8]=dir_name_char;name_len=name_len+1;end
 if(dir_entry_end)begin
   file_seen=file_seen+1;
   if(dir_entry_first_cluster!=3||dir_entry_size!=600||dir_entry_is_lfn!=expect_lfn)begin $display("metadata mismatch");errors=errors+1;end
 end
 if(file_data_valid&&!testing_cycle)begin
   if(testing_multiblock)begin
     if(file_data!==got[7:0])begin $display("multiblock data mismatch %0d",got);errors=errors+1;end
   end else if(got<512)begin if(file_data!==got[7:0])begin $display("data mismatch %0d",got);errors=errors+1;end end
   else if(file_data!==(8'ha0+(got-512)))begin $display("fragment mismatch %0d",got);errors=errors+1;end
   got=got+1;
 end
end
initial begin #2000000;$display("*** TIMEOUT *** state=%0d err=%0d got=%0d map_seen=%0d pending=%b op=%0d",dbg_fat_state,fat_error_code,got,map_seen,dut.map_pending,dut.active_op);$finish;end
endmodule
