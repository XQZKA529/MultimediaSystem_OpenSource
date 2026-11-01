`timescale 1ns/1ps
`include "pkg/fat_dir_bus.vh"
module tb_sd_subtitle_controller;
 reg clk=0,vclk=0,rst=1,vs=0,link=1,sreset=0;
 reg dt=0,at=0,clear=0,load=0,present=0;
 reg [31:0] lc=8,ls=6,ic=7,isz=1234,iid=12,image=12;
 wire enable,auto_enabled,busy,ack,reject;wire [3:0] status;
 wire dreq,dstart,fstart;wire [31:0] fc,fs;
 wire match_done,wav_match;wire [31:0] wav_cluster,wav_size;integer wav_matches=0;
 reg [`VDIR_DBUS_W-1:0] dd=0;reg [7:0] fd=0;reg fv=0,done=0,fok=1;
 wire mv,mr,wv,wr,applied;wire [31:0] rev,word,arev;wire [1:0] result;
 wire selected,video_commit;wire [14:0] meta;wire [7:0] text;reg [7:0] addr=0;
 reg force_failure=0,hold_apply=0;reg [2047:0] longname;integer j;
 integer frame_cycle=0,acks=0,rejects=0,messages=0,checks=0;
 sd_subtitle_controller #(.CLK_HZ(1000)) dut(.clk(clk),.rst(rst),.link_up(link),.session_reset(sreset),.storage_idle(1'b1),
 .display_toggle(dt),.auto_toggle(at),.clear_manual(clear),.display_enable(enable),.auto_enable(auto_enabled),.status(status),
 .load_req(load),.load_cluster(lc),.load_size(ls),.load_ack(ack),.load_rejected(reject),.busy(busy),
 .image_presented(present),.image_suppress_audio(1'b0),.image_cluster(ic),.image_size(isz),.image_id(iid),
 .match_done(match_done),.wav_match(wav_match),.match_pending(),.wav_cluster(wav_cluster),.wav_size(wav_size),
 .dir_req(dreq),.dir_gnt(dreq),.dir_start(dstart),.dir_dat(dd),
 .file_start(fstart),.file_cluster(fc),.file_size(fs),.file_data(fd),.file_valid(fv),.file_done(done),.file_ok(fok),
 .message_valid(mv),.message_ready(mr),.message_revision(rev),.word_valid(wv),.word_ready(wr),.word_data(word),
 .applied((applied && !hold_apply) || force_failure),.applied_revision(force_failure ? dut.await_revision:arev),.applied_result(force_failure ? 2'd2:result));
 sd_subtitle_view sink(.clk(clk),.rst(rst),.session_reset(sreset),.start(mv && mr),.revision(rev),.start_ready(mr),
 .data_valid(wv),.data(word),.last(dut.tx_word==65),.data_ready(wr),.applied(applied),.applied_ready(1'b1),.applied_revision(arev),.applied_result(result),
 .video_clk(vclk),.video_rst(rst),.vs(vs),.display_image_id(image),.image_valid(1'b1),.mix_active(1'b0),
 .text_addr(addr),.text_data(text),.metadata(meta),.selected(selected),.video_commit(video_commit));
 always #5 clk=~clk;always #7 vclk=~vclk;
 always @(negedge vclk) begin frame_cycle=frame_cycle+1;vs=frame_cycle%256<4;end
 always @(posedge clk) if(!rst) begin if(ack) acks=acks+1;if(reject) rejects=rejects+1;if(mv && mr) messages=messages+1;end
 always @(posedge clk) if(!rst && match_done && wav_match) wav_matches=wav_matches+1;
 task tick;input integer n;begin repeat(n) @(negedge clk);end endtask
 task settle;begin tick(3000);end endtask
 task read_char;input [6:0] n;input [7:0] c;
 begin @(negedge vclk);addr=n;repeat(2) @(negedge vclk);if(text!==c) $fatal(1,"wrong text byte index=%0d got=%h expected=%h status=%0d len=%0d",n,text,c,status,meta[8:0]);checks=checks+1;end endtask
 task present_image;input [31:0] id;begin @(negedge clk);iid=id;image=id;present=1;tick(1);present=0;end endtask
 task toggle_auto;begin @(negedge clk);at=1;tick(1);at=0;end endtask
 task request_file;input integer size;begin @(negedge clk);ls=size;load=1;tick(1);load=0;if(size!=0) begin wait(fstart);tick(2);end end endtask
 task file_byte;input [7:0] c;begin @(negedge clk);fd=c;fv=1;tick(1);fv=0;tick(1);end endtask
 task finish_file;input success;begin @(negedge clk);fok=success;done=1;tick(1);done=0;end endtask
 task entry;input [2047:0] name;input integer length;input [31:0] cluster,size;
 integer j;begin
  @(negedge clk);dd=0;dd[`VDIR_D_ESTART]=1;dd[`VDIR_D_FCLUST]=cluster;dd[`VDIR_D_SIZE]=size;tick(1);dd=0;
  for(j=0;j<length;j=j+1) begin
   dd[`VDIR_D_NVLD]=1;dd[`VDIR_D_CHAR]=name[(length-j)*8-1 -:8];dd[`VDIR_D_INDEX]=j;
   dd[`VDIR_D_FCLUST]=cluster;dd[`VDIR_D_SIZE]=size;tick(1);dd=0;tick(1);
  end
  dd[`VDIR_D_EEND]=1;dd[`VDIR_D_FCLUST]=cluster;dd[`VDIR_D_SIZE]=size;tick(1);dd=0;tick(1);
 end endtask
 task end_dir;begin dd=0;dd[`VDIR_D_DONE]=1;dd[`VDIR_D_OK]=1;tick(1);dd=0;end endtask
 task first_scan;begin wait(dstart);tick(2);entry("photo.txt",9,8,4);entry("photo.bmp",9,7,1234);end_dir;end endtask
 initial begin
  tick(4);rst=0;settle;if(selected) $fatal(1,"default on");
  request_file(6);file_byte("M");file_byte("a");file_byte("n");file_byte("u");file_byte("a");file_byte("l");finish_file(1);
  if(acks) $fatal(1,"success before video commit");
  // A queued toggle plus another on the first post-commit edge cancel;
  // merge deferred and fresh events by parity, for both DISPLAY and AUTO.
  wait(dut.staged);@(negedge clk);dt=1;at=1;tick(1);dt=0;at=0;
  wait(ack);@(negedge clk);dt=1;at=1;tick(1);dt=0;at=0;
  wait(acks==1);settle;
  if(!enable || auto_enabled || meta[8:0]!=6) $fatal(1,"manual selection");read_char(0,"M");read_char(5,"l");
  request_file(1);file_byte(8'hff);finish_file(1);wait(rejects==1);settle;read_char(0,"M");if(meta[8:0]!=6) $fatal(1,"failed manual replaced text");
  request_file(1);file_byte("Z");finish_file(1);wait(dut.snapshot_ready);
  @(negedge clk);force_failure=1;tick(1);force_failure=0;wait(rejects==2);settle;
  if(!enable || auto_enabled || dut.manual_len!=6 || dut.u_ram.mem[512][7:0]!="M")
   $fatal(1,"failed APPLIED changed saved manual state");
  present_image(12);toggle_auto;first_scan;wait(dstart);tick(2);
  entry("photograph.txt",14,9,4);entry("photo.txb",9,10,4);entry("PHOTO.TXT",9,8,4);
  entry("pHoTo.WaV",9,11,42);entry("EMERG.WAV",9,12,43);end_dir;wait(fstart);tick(2);
  if(wav_matches!=1 || wav_cluster!=11 || wav_size!=42) $fatal(1,"same-name WAV match count=%0d cluster=%0d size=%0d",wav_matches,wav_cluster,wav_size);
  if(fc!=8) $fatal(1,"same-prefix/case match");file_byte("A");file_byte("u");file_byte("t");file_byte("o");finish_file(1);settle;
  if(!auto_enabled || meta[8:0]!=4 || !meta[14]) begin
   $display("auto debug state=%0d found=%0d wav_found=%0d wav_matches=%0d status=%0d fc=%0d cluster=%0d lookup=%0d",dut.state,dut.found,dut.wav_found,wav_matches,status,fc,dut.current_cluster,dut.lookup_id);
   $fatal(1,"auto_enabled selection auto=%b meta=%h status=%0d",auto_enabled,meta,status);
  end
  read_char(0,"A");read_char(3,"o");
  request_file(1);file_byte(8'hff);finish_file(1);wait(rejects==3);settle;
  if(!auto_enabled || !enable || meta[8:0]!=4) $fatal(1,"manual failure changed AUTO mode/display");read_char(0,"A");
  toggle_auto;settle;if(auto_enabled || meta[8:0]!=6) $fatal(1,"manual restore");read_char(0,"M");
  // A setting arriving on the first reconnect snapshot must publish the new
  // configuration, rather than clearing dirty while freezing the old value.
  link=0;sreset=1;tick(1);sreset=0;tick(20);link=1;clear=1;tick(1);clear=0;settle;
  if(!selected || meta[8:0]!=0 || dut.manual_len!=0) $fatal(1,"clear lost at snapshot dispatch");
  toggle_auto;first_scan;wait(dstart);tick(2);entry("OTHER.TXT",9,8,4);end_dir;settle;
  if(status!=4 || meta[8:0]!=0 || !selected) $fatal(1,"missing TXT fallback");
  present_image(13);first_scan;wait(dstart);tick(2);entry("photo.txt",9,8,4);entry("PHOTO.TXT",9,9,4);end_dir;settle;
  if(status!=8 || meta[8:0]!=0) $fatal(1,"ambiguous name");
  present_image(14);wait(dstart);tick(2);entry("p?oto.bmp",9,7,1234);end_dir;settle;
  if(status!=7 || meta[8:0]!=0) $fatal(1,"unsupported name");
  present_image(15);wait(dstart);tick(2);longname=0;
  for(j=0;j<130;j=j+1) longname[(133-j)*8 +:8]="L";longname[31:0]=".BMP";
  entry(longname,134,7,1234);end_dir;wait(dstart);tick(2);longname[31:0]=".TXT";
  entry(longname,134,8,4);end_dir;wait(fstart);tick(2);
  file_byte("L");file_byte("o");file_byte("n");file_byte("g");finish_file(1);settle;
  if(meta[8:0]!=4) $fatal(1,"134-byte full-name match");read_char(0,"L");
  // A presentation arriving during lookup is retained and supersedes the old
  // image. The render binding hides the old caption before the next lookup.
  present_image(16);wait(dstart);tick(2);entry("photo.bmp",9,7,1234);
  present_image(17);end_dir;wait(dstart);tick(2);entry("photo.txt",9,8,3);end_dir;
  wait(fstart);tick(2);file_byte("O");file_byte("l");file_byte("d");finish_file(1);
  wait(dstart);tick(2);entry("photo.bmp",9,7,1234);end_dir;
  wait(dstart);tick(2);entry("photo.txt",9,8,3);end_dir;
  wait(fstart);tick(2);file_byte("N");file_byte("e");file_byte("w");finish_file(1);settle;
  if(!meta[14] || meta[8:0]!=3 || sink.view_binding!=17) $fatal(1,"rapid image request lost or stale binding");
  read_char(0,"N");read_char(2,"w");
  @(negedge clk);dt=1;tick(1);dt=0;settle;if(selected || !auto_enabled) $fatal(1,"display off cleared AUTO mode");
  present_image(18);first_scan;wait(dstart);tick(2);entry("PHOTO.WAV",9,11,42);end_dir;settle;
  if(dreq || !auto_enabled) $fatal(1,"hidden subtitle lookup did not retain configuration");
  @(negedge clk);dt=1;tick(1);dt=0;first_scan;wait(dstart);tick(2);entry("photo.txt",9,8,3);entry("PHOTO.WAV",9,11,42);end_dir;
  wait(fstart);tick(2);file_byte("O");file_byte("n");file_byte("!");finish_file(1);settle;
  if(!meta[14] || sink.view_binding!=18) $fatal(1,"display reenable did not refresh current image");read_char(0,"O");
  hold_apply=1;request_file(1);file_byte("T");finish_file(1);wait(rejects==4);hold_apply=0;settle;
  if(status!=6 || !enable || !auto_enabled || meta[8:0]!=3) $fatal(1,"business timeout did not restore AUTO/display");
  read_char(0,"O");
  // A new manual selection disables AUTO and clears the display successfully.
  request_file(0);wait(acks==2);settle;if(auto_enabled || meta[8:0]!=0 || !enable) $fatal(1,"empty manual");
  @(negedge clk);dt=1;tick(1);dt=0;settle;if(selected || enable) $fatal(1,"display off");
  link=0;sreset=1;tick(1);sreset=0;tick(20);link=1;dt=1;tick(1);dt=0;settle;
  if(!selected || !enable) $fatal(1,"display toggle lost at reconnect snapshot dispatch");
  @(negedge clk);dt=1;tick(1);dt=0;settle;
  link=0;sreset=1;tick(1);sreset=0;tick(20);link=1;settle;if(selected) $fatal(1,"reconnect configuration");
  request_file(257);repeat(257) file_byte("Q");finish_file(1);wait(acks==3);settle;
  if(meta[8:0]!=256 || status!=2) $fatal(1,"256-byte manual TXT capacity/truncation");
  read_char(0,"Q");read_char(255,"Q");
  $display("*** PASS *** SD subtitle lifecycle: manual commit/failure, auto case/full-name/missing/ambiguous/unsupported, restore/empty/off/reconnect (%0d snapshots)",messages);$finish;
 end
 initial begin #5000000;$display("DEBUG state=%0d status=%0d tx=%0d ack=%0d rejects=%0d",dut.state,status,dut.tx_state,acks,rejects);$fatal(1,"timeout");end
endmodule
