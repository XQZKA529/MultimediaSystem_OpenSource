`timescale 1ns/1ps
`include "pkg/fat_dir_bus.vh"
`include "pkg/board_link.vh"
// Real FAT32 MBR/VFAT walker and serialized service, with a byte SD block model.
module tb_sd_subtitle_system;
 reg clk=0,vc=0,t0=0,t1=0,rst=1,vs_timer=0,phy=1;always #5 clk=~clk;always #7 vc=~vc;always #4 t0=~t0;always #4.01 t1=~t1;
 parameter FRAME_WORDS=48,EXPORT_FRAMES=1;
 reg capture_frame=0;wire probe_vs;wire vs=capture_frame ? probe_vs:vs_timer;
 always begin #10000;vs_timer=1;#100;vs_timer=0;end
 reg mount=0;wire mounted,mount_ok;wire [7:0] error;
 wire block_req;wire [31:0] lba;wire [15:0] count;
 reg grant=0,bdv=0,bend=0,berror=0;reg [7:0] bd=0;
 reg [7:0] disk[0:16383];reg reading=0,fail_read=0;integer pos=0,total=0,base=0;
 wire idle,dreq,dgnt,dstart,fstart,fvalid,fdone,fok;
 wire [`VDIR_DBUS_W-1:0] dir;wire [31:0] fcluster,fsize;wire [7:0] fdata;
 reg load=0,at=0,dt=0,clear=0,present=0;reg [31:0] lc=4,ls=600;
 wire enable,auto_enable,busy,ack,reject;wire [3:0] status;
 wire mv,mr,wv,wr,applied;wire [31:0] revision,word,arev;wire [1:0] result;
 reg [7:0] addr=0;wire [7:0] probe_addr;wire [7:0] text;wire [14:0] meta;wire selected;
 integer acks=0,rejects=0,bmp_bytes=0,map_segments=0;
 // An already running, deterministic PCM stream shares the actual reliable
 // link scheduler with subtitle work. The WAV reader/PCM playback chain is
 // separately exercised by tb_audio_system; this checks subtitle concurrency.
 reg pcm_running=0,pcm_push=0,pcm_clear=0,pcm_toggle=0,pcm_eof=0;
 reg [31:0] pcm_word=0;
 wire pcm_credit,audio_push;wire [31:0] audio_word;
 integer pcm_sent=0,pcm_received=0,pcm_busy_sent=0;
 always @(negedge clk) begin
  pcm_push=0;pcm_eof=0;
  if(!rst && pcm_running && pcm_sent<256 && pcm_credit) begin
   pcm_word=32'h40000000+pcm_sent;pcm_push=1;pcm_sent=pcm_sent+1;
  end
  else if(!rst && pcm_running && pcm_sent==256) begin pcm_eof=1;pcm_running=0;end
 end
 always @(posedge clk) if(!rst) begin
  if(source.pcm_pop && busy) pcm_busy_sent=pcm_busy_sent+1;
  if(audio_push) begin
   if(audio_word!==(32'h40000000+pcm_received)) $fatal(1,"PCM order/data during subtitle work");
   pcm_received=pcm_received+1;
  end
 end
 reg bmp_start=0,map_start=0,bmp_ready=0;
 wire [7:0] bmp_data;wire bmp_valid,bmp_done,bmp_ok,map_done,map_ok,map_entry;
 wire [1:0] unused_gnt;
    reg drop_forward=0;wire [31:0] retries;
    wire up0,up1,s0,s1;
    reg kp_send=0;reg [5:0] kp_word=0;wire kp_ready,kp_received;wire [5:0] kp_received_data;integer kp_count=0;
    always @(posedge clk) if(kp_received) begin if(kp_received_data!==kp_count[5:0]) $fatal(1,"keypad link order");kp_count=kp_count+1;end
    wire [7:0] macd0,macd1,rd0,rd1;wire macv0,macv1,ma0,ma1,rv0,rv1,rg0,rg1;
    wire mt0,mr0,dt0,dr0,lt0,mt1,mr1,dt1,dr1,lt1;
    wire [7:0] ch0,op0,ch1,op1;wire [31:0] obj0,off0,d0,obj1,off1,d1;wire [15:0] len0,len1;
    wire rm0,rrm0,rvd0,rrd0,rl0,rq0,rm1,rrm1,rvd1,rrd1,rl1,rq1;
    wire [7:0] rch0,rop0,rch1,rop1;wire [31:0] robj0,roff0,rdata0,robj1,roff1,rdata1;wire [15:0] rlen0,rlen1;
    db_link a(.retry_count(retries),.clk(clk),.rst(rst),.phy_ok(phy),.link_up(up0),.session_reset(s0),
        .tx_meta_valid(mt0),.tx_meta_ready(mr0),.tx_channel(ch0),.tx_opcode(op0),.tx_object(obj0),.tx_offset(off0),.tx_length(len0),
        .tx_valid(dt0),.tx_ready(dr0),.tx_data(d0),.tx_last(lt0),
        .rx_meta_valid(rm0),.rx_meta_ready(rrm0),.rx_required(rq0),.rx_channel(rch0),.rx_opcode(rop0),.rx_object(robj0),.rx_offset(roff0),.rx_length(rlen0),
        .rx_valid(rvd0),.rx_ready(rrd0),.rx_data(rdata0),.rx_last(rl0),
        .mac_tx_clk(t0),.mac_tx_data(macd0),.mac_tx_valid(macv0),.mac_tx_ack(ma0),
        .mac_rx_clk(t1),.mac_rx_data(rd0),.mac_rx_valid(rv0),.mac_rx_good(rg0),.mac_rx_bad(1'b0));
    db_link_render #(.ROLE(2),.LOCAL_MAC(`DB_MAC_RENDER),.PEER_MAC(`DB_MAC_MEDIA)) b(
        .clk(clk),.rst(rst),.phy_ok(phy),.link_up(up1),.session_reset(s1),
        .tx_meta_valid(mt1),.tx_meta_ready(mr1),.tx_channel(ch1),.tx_opcode(op1),.tx_object(obj1),.tx_offset(off1),.tx_length(len1),
        .tx_valid(dt1),.tx_ready(dr1),.tx_data(d1),.tx_last(lt1),
        .rx_meta_valid(rm1),.rx_meta_ready(rrm1),.rx_required(rq1),.rx_channel(rch1),.rx_opcode(rop1),.rx_object(robj1),.rx_offset(roff1),.rx_length(rlen1),
        .rx_valid(rvd1),.rx_ready(rrd1),.rx_data(rdata1),.rx_last(rl1),
        .mac_tx_clk(t1),.mac_tx_data(macd1),.mac_tx_valid(macv1),.mac_tx_ack(ma1),
        .mac_rx_clk(t0),.mac_rx_data(rd1),.mac_rx_valid(rv1),.mac_rx_good(rg1),.mac_rx_bad(1'b0));
    tb_mac_client_pipe p0(.clk(t0),.rst(rst),.din(macd0),.valid(macv0),.ack(ma0),.drop_next(drop_forward),.corrupt_next(1'b0),.dout(rd1),.dv(rv1),.good(rg1));
    tb_mac_client_pipe p1(.clk(t1),.rst(rst),.din(macd1),.valid(macv1),.ack(ma1),.drop_next(1'b0),.corrupt_next(1'b0),.dout(rd0),.dv(rv0),.good(rg0));
    always @(posedge t0) if(drop_forward && p0.active) drop_forward<=0;
 storage_service #(.FILE_MAX_BURST(1)) storage(.clk(clk),.rst(rst),
 .blk_req(block_req),.blk_lba(lba),.blk_count(count),.blk_grant(grant),.blk_data(bd),.blk_data_valid(bdv),.blk_end(bend),.blk_error(berror),
 .mount_start(mount),.mount_done(mounted),.mount_ok(mount_ok),.fat_error_code(error),
 .file_start(bmp_start),.file_first_cluster(32'd8),.file_size(32'd600),.file_read_limit(32'd0),.file_abort(1'b0),.file_read_ready(bmp_ready),
 .file_data(bmp_data),.file_data_valid(bmp_valid),.file_done(bmp_done),.file_ok(bmp_ok),
 .map_start(map_start),.map_first_cluster(32'd4),.map_size(32'd600),.map_abort(1'b0),.map_bank(1'b1),.map_done(map_done),.map_ok(map_ok),.map_wr_en(map_entry),
 .dir_owner_req({dreq,2'b00}),.dir_owner_gnt({dgnt,unused_gnt}),.c0_dir_start(1'b0),.c1_dir_start(1'b0),.c2_dir_start(dstart),.c2_dir_dat(dir),
 .txt_file_start(fstart),.txt_file_cluster(fcluster),.txt_file_size(fsize),.txt_file_data(fdata),.txt_file_valid(fvalid),.txt_file_done(fdone),.txt_file_ok(fok),.operation_idle(idle));
 sd_subtitle_controller #(.CLK_HZ(100000)) controller(.clk(clk),.rst(rst),.link_up(up0),.session_reset(s0),.storage_idle(idle),
 .display_toggle(dt),.auto_toggle(at),.clear_manual(clear),.display_enable(enable),.auto_enable(auto_enable),.status(status),.busy(busy),
 .load_req(load),.load_cluster(lc),.load_size(ls),.load_ack(ack),.load_rejected(reject),
 .image_presented(present),.image_suppress_audio(1'b0),.image_cluster(32'd3),.image_size(32'd1234),.image_id(32'd12),
 .dir_req(dreq),.dir_gnt(dgnt),.dir_start(dstart),.dir_dat(dir),
 .file_start(fstart),.file_cluster(fcluster),.file_size(fsize),.file_data(fdata),.file_valid(fvalid),.file_done(fdone),.file_ok(fok),
 .message_valid(mv),.message_ready(mr),.message_revision(revision),.word_valid(wv),.word_ready(wr),.word_data(word),
 .applied(applied),.applied_revision(arev),.applied_result(result));
    wire ack_img,finish,credit,pixel_credit,overflow;wire [1:0] received_mode;
    wire wr_img,ab,we,valid,uiwe,uitoggle;wire [31:0] wd;wire [1:0] wi,di;wire [8:0] uiaddr;wire [7:0] uichar;
    wire received_local_page;wire [3:0] received_ui_page;wire [4:0] received_contrast;wire [3:0] received_brightness;
    reg wack=0,aack=0,wdone=0,uiack=0;
    always @(posedge vc) if(vs) uiack<=uitoggle;
    wire t_req;wire [1:0] t_new,t_cur;
    wire sub_start,sub_ready,sub_dv,sub_last,sub_dr,sub_applied,sub_ar;
    wire [31:0] sub_rev,sub_data,sub_arev;wire [1:0] sub_result;
    seam_media #(.FRAME_WORDS(FRAME_WORDS)) source(.saturation_level(5'd10),.ui_page(4'd0),.transition_mode(2'd0),
      .subtitle_valid(mv),.subtitle_ready(mr),.subtitle_revision(revision),.subtitle_word_valid(wv),.subtitle_word_ready(wr),.subtitle_word(word),
      .subtitle_applied(applied),.subtitle_applied_revision(arev),.subtitle_applied_result(result),.volume_level(5'd20),.volume_changed(1'b0),.volume_hint(1'b0),.volume_revision(32'd0),.keypad_valid(kp_received),.keypad_data(kp_received_data),
        .clk(clk),.rst(rst),.link_up(up0),.session_reset(s0),.image_req(1'b0),.image_ack(ack_img),.image_finish_toggle(finish),
        .image_word_valid(1'b0),.image_word(32'd0),.image_source_ok(1'b0),.image_source_failed(1'b0),.image_burst_ready(credit),.image_pixel_ready(pixel_credit),
        .pcm_push(pcm_push),.pcm(pcm_word),.pcm_clear(pcm_clear),.pcm_eof(pcm_eof),.pcm_total(32'd256),.pcm_base(32'd0),.pcm_stream_toggle(pcm_toggle),.pcm_burst_ready(pcm_credit),.paused(1'b0),.seek_request(1'b0),
        .contrast_level(5'd10),.brightness_level(4'd10),.brightness_mode(received_mode),.ui_wr_en(1'b0),.ui_wr_addr(9'd0),.ui_wr_data(8'd0),.text_osd_page(1'b0),.ui_active(1'b0),.ui_cursor_en(1'b0),.ui_cursor_row(4'd2),.ui_commit_toggle(1'b0),.diag(4'd15),
        .rx_meta_valid(rm0),.rx_meta_ready(rrm0),.rx_required(rq0),.rx_channel(rch0),.rx_opcode(rop0),.rx_object(robj0),.rx_offset(roff0),.rx_length(rlen0),
        .rx_valid(rvd0),.rx_ready(rrd0),.rx_data(rdata0),.rx_last(rl0),
        .tx_meta_valid(mt0),.tx_meta_ready(mr0),.tx_channel(ch0),.tx_opcode(op0),.tx_object(obj0),.tx_offset(off0),.tx_length(len0),
        .tx_valid(dt0),.tx_ready(dr0),.tx_data(d0),.tx_last(lt0),.overflow(overflow));
 seam_render #(.FRAME_WORDS(FRAME_WORDS)) sink(.ui_page(received_ui_page),
      .subtitle_start(sub_start),.subtitle_revision(sub_rev),.subtitle_start_ready(sub_ready),
      .subtitle_data_valid(sub_dv),.subtitle_data(sub_data),.subtitle_last(sub_last),.subtitle_data_ready(sub_dr),
      .subtitle_applied(sub_applied),.subtitle_applied_ready(sub_ar),.subtitle_applied_revision(sub_arev),.subtitle_applied_result(sub_result),.text_osd_page(received_local_page),.keypad_valid(kp_send),.keypad_data(kp_word),.keypad_ready(kp_ready),.contrast_level(received_contrast),.brightness_mode(2'd2),.brightness_level(received_brightness),
        .clk(clk),.rst(rst),.link_up(up1),.session_reset(s1),.video_clk(vc),.video_rst(rst),.vs(vs),
        .rx_meta_valid(rm1),.rx_meta_ready(rrm1),.rx_required(rq1),.rx_channel(rch1),.rx_opcode(rop1),.rx_object(robj1),.rx_offset(roff1),.rx_length(rlen1),
        .rx_valid(rvd1),.rx_ready(rrd1),.rx_data(rdata1),.rx_last(rl1),
        .tx_meta_valid(mt1),.tx_meta_ready(mr1),.tx_channel(ch1),.tx_opcode(op1),.tx_object(obj1),.tx_offset(off1),.tx_length(len1),
        .tx_valid(dt1),.tx_ready(dr1),.tx_data(d1),.tx_last(lt1),
        .write_req(wr_img),.write_req_ack(wack),.write_abort(ab),.write_abort_ack(aack),.write_en(we),.write_data(wd),
        .write_full(1'b0),.write_sector_ready(1'b1),.write_finish_toggle(wdone),.read_selected_index(2'd0),.read_handoff_toggle(1'b0),
        .transition_req(t_req),.transition_new_index(t_new),.transition_cur_index(t_cur),
        .transition_ack(1'b0),.transition_done(1'b0),.transition_failed(1'b0),
        .write_index(wi),.display_index(di),.display_valid(valid),.ui_wr_en(uiwe),.ui_wr_addr(uiaddr),.ui_wr_data(uichar),.ui_commit_toggle(uitoggle),.ui_commit_seen(uiack),
        .audio_push(audio_push),.audio_data(audio_word),.audio_packet_ready(1'b1),.audio_feedback(1'b0),.feedback_epoch(32'd0),.feedback_position(32'd0),.feedback_flags(3'd0));
 sd_subtitle_view view(.clk(clk),.rst(rst),.session_reset(s1),.start(sub_start),.revision(sub_rev),.start_ready(sub_ready),
 .data_valid(sub_dv),.data(sub_data),.last(sub_last),.data_ready(sub_dr),.applied(sub_applied),.applied_ready(sub_ar),.applied_revision(sub_arev),.applied_result(sub_result),
 .video_clk(vc),.video_rst(rst),.vs(vs),.display_image_id(32'd12),.image_valid(1'b1),.mix_active(1'b0),
 .text_addr(capture_frame ? probe_addr:addr),.text_data(text),.metadata(meta),.selected(selected));
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
 task byte_check;input [7:0] index;input [7:0] expected;begin @(negedge vc);addr=index;repeat(2) @(negedge vc);if(text!==expected) begin $display("byte index=%0d actual=%h expected=%h flags=%h",index,text,expected,meta);$fatal(1,"FAT subtitle byte");end end endtask
 tb_sd_subtitle_frame_probe probe(.clk(vc),.rst(rst),.ui_page(received_ui_page),.sd_metadata(meta),.sd_data(text),.sd_addr(probe_addr),.vs(probe_vs));
 task send_keypad;input [5:0] value;begin
  @(negedge clk);kp_word=value;kp_send=1;@(posedge clk);while(!kp_ready) @(posedge clk);@(negedge clk);kp_send=0;tick(2);
 end endtask
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
  tick(5);rst=0;tick(2);mount=1;tick(1);mount=0;wait(mounted);wait(up0 && up1);if(!mount_ok) $fatal(1,"mount");tick(20);
  pcm_clear=1;pcm_toggle=1;tick(1);pcm_clear=0;pcm_running=1;
  // Requests arriving while BMP owns FAT must survive, with WAV map and TXT
  // sharing the walker and only the BMP consumer seeing its file bytes.
  bmp_start=1;tick(1);bmp_start=0;tick(20);request(4,600);map_start=1;tick(1);map_start=0;
  // Drop the next outbound packet; a reliable retransmission must recover.
  drop_forward=1;
  tick(80);if(bmp_bytes!=0) $fatal(1,"BMP burst ignored credit");bmp_ready=1;
  wait(bmp_done);if(!bmp_ok || bmp_bytes!=600) $fatal(1,"BMP read");for(i=0;i<4;i=i+1) send_keypad(i);
  wait(acks==1);tick(300);if(retries==0) $fatal(1,"retry was not exercised");if(kp_count!=4) $fatal(1,"keypad traffic blocked by subtitles");if(map_segments!=2 || !map_ok || meta[8:0]!=3) $fatal(1,"queued map/TXT read");byte_check(0,"M");byte_check(2,"n");
  wait(pcm_received==256);
  if(pcm_busy_sent==0 || overflow) $fatal(1,"existing PCM did not progress during subtitle work");
  $display("Concurrent PCM: %0d ordered frames, %0d transmitted while subtitle busy",pcm_received,pcm_busy_sent);
  if(EXPORT_FRAMES) begin capture_frame=1;probe.export_case("sd_subtitle_manual_frame.ppm",3,"Man");capture_frame=0;tick(2);end
  @(negedge clk);present=1;tick(1);present=0;at=1;tick(1);at=0;
  wait(status==3 && !busy);tick(10000);
  if(!auto_enable || meta[8:0]!=3) $fatal(1,"VFAT auto");byte_check(0,"S");byte_check(2,"!");
  if(EXPORT_FRAMES) begin capture_frame=1;probe.export_case("sd_subtitle_auto_frame.ppm",3,"SD!");capture_frame=0;tick(2);end
  request(6,1);wait(rejects==1);tick(500);byte_check(0,"S");if(!auto_enable) $fatal(1,"bad manual changed AUTO");
  fail_read=1;request(4,600);wait(rejects==2);fail_read=0;tick(500);byte_check(0,"S");
  @(negedge clk);at=1;tick(1);at=0;tick(10000);byte_check(0,"M");
  phy=0;wait(!up0 && !up1);tick(200);dt=1;tick(1);dt=0;tick(200);
  if(enable || auto_enable) $fatal(1,"offline settings retention");
  phy=1;wait(up0 && up1);tick(20000);if(selected) $fatal(1,"reconnect display replay");
  dt=1;tick(1);dt=0;tick(10000);if(!selected) $fatal(1,"display restore");byte_check(0,"M");
  if(EXPORT_FRAMES) $display("*** PASS *** real FAT + independent reliable links + VS subtitle + full 720p RGB/sync: MBR/VFAT, TXT before BMP, bounded fragmented prefix, BMP/WAV-map ownership/credit, keypad concurrency, parse/block failures, disconnect/reconnect replay");
  else $display("*** PASS *** real FAT + independent reliable links + VS subtitle: ownership/credit, retry, keypad, failure retention and reconnect (frame export disabled)");
  $finish;
 end
 initial begin #80000000;$display("DEBUG sub=%0d storage=%0d fat=%0d error=%0d",controller.state,storage.owner,storage.u_fat32_ro.state,error);$fatal(1,"timeout");end
endmodule
