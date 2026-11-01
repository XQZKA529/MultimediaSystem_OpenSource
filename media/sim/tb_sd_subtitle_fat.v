`timescale 1ns/1ps
`include "pkg/fat_dir_bus.vh"
// Real FAT32 MBR/VFAT walker and serialized service, with a byte SD block model.
module tb_sd_subtitle_fat;
 reg clk=0,vc=0,rst=1,vs=0;always #5 clk=~clk;always #7 vc=~vc;
 always begin #10000;vs=1;#100;vs=0;end
 reg mount=0;wire mounted,mount_ok;wire [7:0] error;
 wire block_req;wire [31:0] lba;wire [15:0] count;
 reg grant=0,bdv=0,bend=0,berror=0;reg [7:0] bd=0;
 reg [7:0] disk[0:16383];reg reading=0,fail_read=0;integer pos=0,total=0,base=0;
 wire idle,dreq,dgnt,dstart,fstart,fvalid,fdone,fok;
 wire [`VDIR_DBUS_W-1:0] dir;wire [31:0] fcluster,fsize;wire [7:0] fdata;
 reg load=0,at=0,dt=0,clear=0,present=0;reg [31:0] lc=4,ls=600;
 wire enable,auto_enable,busy,ack,reject;wire [3:0] status;
 wire mv,mr,wv,wr,applied,video_commit;wire [31:0] revision,word,arev;wire [1:0] result;
 reg [7:0] addr=0;wire [7:0] text;wire [14:0] meta;wire selected;
 integer acks=0,rejects=0,bmp_bytes=0,map_segments=0;
 reg bmp_start=0,map_start=0,bmp_ready=0;
 wire [7:0] bmp_data;wire bmp_valid,bmp_done,bmp_ok,map_done,map_ok,map_entry;
 wire [1:0] unused_gnt;
 storage_service #(.FILE_MAX_BURST(1)) storage(.clk(clk),.rst(rst),
 .blk_req(block_req),.blk_lba(lba),.blk_count(count),.blk_grant(grant),.blk_data(bd),.blk_data_valid(bdv),.blk_end(bend),.blk_error(berror),
 .mount_start(mount),.mount_done(mounted),.mount_ok(mount_ok),.fat_error_code(error),
 .file_start(bmp_start),.file_first_cluster(32'd8),.file_size(32'd600),.file_read_limit(32'd0),.file_abort(1'b0),.file_read_ready(bmp_ready),
 .file_data(bmp_data),.file_data_valid(bmp_valid),.file_done(bmp_done),.file_ok(bmp_ok),
 .map_start(map_start),.map_first_cluster(32'd4),.map_size(32'd600),.map_abort(1'b0),.map_bank(1'b1),.map_done(map_done),.map_ok(map_ok),.map_wr_en(map_entry),
 .dir_owner_req({dreq,2'b00}),.dir_owner_gnt({dgnt,unused_gnt}),.c0_dir_start(1'b0),.c1_dir_start(1'b0),.c2_dir_start(dstart),.c2_dir_dat(dir),
 .txt_file_start(fstart),.txt_file_cluster(fcluster),.txt_file_size(fsize),.txt_file_data(fdata),.txt_file_valid(fvalid),.txt_file_done(fdone),.txt_file_ok(fok),.operation_idle(idle));
 sd_subtitle_controller #(.CLK_HZ(100000)) controller(.clk(clk),.rst(rst),.link_up(1'b1),.session_reset(1'b0),.storage_idle(idle),
 .display_toggle(dt),.auto_toggle(at),.clear_manual(clear),.display_enable(enable),.auto_enable(auto_enable),.status(status),.busy(busy),
 .load_req(load),.load_cluster(lc),.load_size(ls),.load_ack(ack),.load_rejected(reject),
 .image_presented(present),.image_cluster(32'd3),.image_size(32'd1234),.image_id(32'd12),
 .image_suppress_audio(1'b0),
 .dir_req(dreq),.dir_gnt(dgnt),.dir_start(dstart),.dir_dat(dir),
 .file_start(fstart),.file_cluster(fcluster),.file_size(fsize),.file_data(fdata),.file_valid(fvalid),.file_done(fdone),.file_ok(fok),
 .message_valid(mv),.message_ready(mr),.message_revision(revision),.word_valid(wv),.word_ready(wr),.word_data(word),
 .applied(applied),.applied_revision(arev),.applied_result(result));
 sd_subtitle_view view(.clk(clk),.rst(rst),.session_reset(1'b0),.start(mv && mr),.revision(revision),.start_ready(mr),
 .data_valid(wv),.data(word),.last(controller.tx_word==65),.data_ready(wr),.applied(applied),.applied_ready(1'b1),.applied_revision(arev),.applied_result(result),
 .video_clk(vc),.video_rst(rst),.vs(vs),.display_image_id(32'd12),.image_valid(1'b1),.mix_active(1'b0),
 .text_addr(addr),.text_data(text),.metadata(meta),.selected(selected),.video_commit(video_commit));
 always @(posedge clk) begin
  grant<=0;bdv<=0;bend<=0;berror<=0;
  if(block_req && !reading) begin reading<=1;grant<=1;base<=lba*512;pos<=0;total<=count*512;if(count!=1) $fatal(1,"unbounded SD burst");end
  else if(reading) begin
   if(pos<total) begin bd<=disk[base+pos];bdv<=1;pos<=pos+1;end
   else begin bend<=1;berror<=fail_read;reading<=0;end
  end
  if(ack) acks=acks+1;if(reject) rejects=rejects+1;
  if(map_entry) map_segments=map_segments+1;
  if(bmp_valid) begin if(bmp_data!==bmp_bytes[7:0]) $fatal(1,"BMP response ownership");bmp_bytes=bmp_bytes+1;end
 end
 task tick;input integer n;begin repeat(n) @(negedge clk);end endtask
 task put16;input integer a;input [15:0] v;begin disk[a]=v[7:0];disk[a+1]=v[15:8];end endtask
 task put32;input integer a;input [31:0] v;begin disk[a]=v[7:0];disk[a+1]=v[15:8];disk[a+2]=v[23:16];disk[a+3]=v[31:24];end endtask
 function [7:0] csum;input [87:0] s;integer j;reg [7:0] q;begin q=0;for(j=0;j<11;j=j+1)q=((q&1)?8'h80:0)+(q>>1)+s[(10-j)*8+:8];csum=q;end endfunction
 task lfnchar;input integer ent,n;input [15:0] v;integer o;begin
  case(n)0:o=1;1:o=3;2:o=5;3:o=7;4:o=9;5:o=14;6:o=16;7:o=18;8:o=20;9:o=22;10:o=24;11:o=28;default:o=30;endcase put16(ent+o,v);
 end endtask
 task long_entry;input integer off;input [127:0] name;input [87:0] sfn;input integer cluster,size;
 integer j;reg [7:0] sum;begin
  sum=csum(sfn);disk[off]=8'h42;disk[off+11]=15;disk[off+13]=sum;
  for(j=0;j<13;j=j+1) lfnchar(off,j,j<3 ? {8'd0,name[(2-j)*8+:8]}:j==3 ? 16'd0:16'hffff);
  off=off+32;disk[off]=1;disk[off+11]=15;disk[off+13]=sum;
  for(j=0;j<13;j=j+1) lfnchar(off,j,{8'd0,name[(15-j)*8+:8]});
  off=off+32;for(j=0;j<11;j=j+1)disk[off+j]=sfn[(10-j)*8+:8];disk[off+11]=32;put16(off+26,cluster);put32(off+28,size);
 end endtask
 task request;input integer cluster,size;begin @(negedge clk);lc=cluster;ls=size;load=1;tick(1);load=0;end endtask
 task byte_check;input [7:0] index;input [7:0] expected;begin @(negedge vc);addr=index;repeat(2) @(negedge vc);if(text!==expected) $fatal(1,"FAT subtitle byte index=%0d got=%h expected=%h status=%0d auto=%0d len=%0d",index,text,expected,status,auto_enable,meta[8:0]);end endtask
 integer i;
 initial begin
  for(i=0;i<16384;i=i+1) disk[i]=0;
  disk[510]=8'h55;disk[511]=8'haa;disk[450]=8'h0c;put32(454,10);put32(458,1000);
  base=10*512;put16(base+11,512);disk[base+13]=1;put16(base+14,1);disk[base+16]=1;
  put32(base+32,1000);put32(base+36,8);put32(base+44,2);disk[base+510]=8'h55;disk[base+511]=8'haa;
  base=11*512;for(i=0;i<10;i=i+1)put32(base+i*4,32'h0fffffff);put32(base+16,7);put32(base+32,9);
  long_entry(19*512,"Long Picture.TXT","LONGPI~1TXT",5,10);
  long_entry(19*512+96,"Long Picture.BMP","LONGPI~1BMP",3,1234);
  for(i=0;i<260;i=i+1) disk[21*512+i]=32;
  for(i=0;i<10;i=i+1) disk[22*512+i]=32;
  disk[21*512]="M";disk[21*512+1]="a";disk[21*512+2]="n";disk[21*512+3]=10;
  disk[22*512]="S";disk[22*512+1]="D";disk[22*512+2]="!";disk[22*512+3]=13;disk[22*512+4]=10;
  disk[23*512]=8'hff;
  for(i=0;i<512;i=i+1)begin disk[25*512+i]=i;disk[26*512+i]=i;end
  tick(5);rst=0;tick(2);mount=1;tick(1);mount=0;wait(mounted);if(!mount_ok) $fatal(1,"mount");tick(20);
  // Requests arriving while BMP owns FAT must survive, with WAV map and TXT
  // sharing the walker and only the BMP consumer seeing its file bytes.
  bmp_start=1;tick(1);bmp_start=0;tick(20);request(4,600);map_start=1;tick(1);map_start=0;
  tick(80);if(bmp_bytes!=0) $fatal(1,"BMP burst ignored credit");bmp_ready=1;
  wait(bmp_done);if(!bmp_ok || bmp_bytes!=600) $fatal(1,"BMP read");
  wait(acks==1);tick(300);if(map_segments!=2 || !map_ok || meta[8:0]!=3) $fatal(1,"queued map/TXT read");byte_check(0,"M");byte_check(2,"n");
  @(negedge clk);present=1;tick(1);present=0;at=1;tick(1);at=0;
  wait(status==3 && !busy);tick(1500);if(!auto_enable || meta[8:0]!=3) $fatal(1,"VFAT auto");byte_check(0,"S");byte_check(2,"!");
  request(6,1);wait(rejects==1);tick(500);byte_check(0,"S");if(!auto_enable) $fatal(1,"bad manual changed AUTO");
  fail_read=1;request(4,600);wait(rejects==2);fail_read=0;tick(500);byte_check(0,"S");
  @(negedge clk);at=1;tick(1);at=0;tick(3000);byte_check(0,"M");
  $display("*** PASS *** real FAT subtitle: MBR/VFAT, TXT before BMP, bounded fragmented prefix, BMP/WAV-map ownership/credit, parse and block failures");$finish;
 end
 initial begin #10000000;$display("DEBUG sub=%0d storage=%0d fat=%0d error=%0d",controller.state,storage.owner,storage.u_fat32_ro.state,error);$fatal(1,"timeout");end
endmodule
