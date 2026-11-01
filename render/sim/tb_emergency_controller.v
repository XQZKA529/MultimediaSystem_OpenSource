`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_emergency_controller;
 reg clk=0,vclk=0,rst=1,link=1,sreset=0,down=0,online=1,cancel=0;
 reg [3:0] id=0;reg b0=0,b1=0;
 reg frame_sync=0;always begin #100;frame_sync=1;#40;frame_sync=0;end
 reg fb=0;reg [31:0] epoch=7,pos=123;reg [2:0] flags=7;
 reg reply=0;reg [31:0] reply_rev=0,reply_ep=0;reg [7:0] code=0;
 reg pic_ready=0,audio_ready=0,request_ready=0;
 wire [1:0] mode,index;wire blocked,hold_audio,req,allow_audio,restore,valid,active;
 reg [32:0] live={7'd26,4'd10,5'd14,5'd15,6'd30,6'd1};
 wire [98:0] times;wire [143:0] vtimes;
 wire [2:0] sources,vsources;wire [8:0] groups,vgroups;wire ven;
 wire [31:0] rev,allowed_epoch,pic;wire [127:0] snapshot;wire [7:0] status;
 reg [31:0] saved_rev;integer a,b,c,k,combinations=0;
 always #5 clk=~clk;always #7 vclk=~vclk;
 emergency_inputs #(.FILTER_CYCLES(8)) inputs(.clk(clk),.rst(rst),.gpio_b0(b0),.gpio_b1(b1),
  .key_down(down),.key_online(online),.key_cancel(cancel),.key_id(id),.clock_live(live),.timestamps(times),.sources(sources),.groups(groups),.active(active));
 emergency_view_cdc view(.clk(clk),.rst(rst),.mode(mode),.sources(sources),.groups(groups),.timestamps(times),
  .video_clk(vclk),.video_rst(rst),.enable(ven),.video_sources(vsources),.video_groups(vgroups),.video_timestamps(vtimes),.vs(frame_sync));
 emergency_controller dut(.clk(clk),.rst(rst),.link_up(link),.session_reset(sreset),.alarm_active(active),
  .video_clk(vclk),.video_rst(rst),.display_id(32'd11),.display_index(2'd1),.display_valid(1'b1),
  .feedback(fb),.feedback_epoch(epoch),.feedback_position(pos),.feedback_flags(flags),
  .reply_valid(reply),.reply_revision(reply_rev),.reply_epoch(reply_ep),.reply_status(code),
  .picture_restored(pic_ready),.frame_sync(frame_sync),.audio_ready(audio_ready),.mode(mode),.input_block(blocked),.local_hold(hold_audio),
  .request_valid(req),.request_ready(request_ready),.revision(rev),.request_snapshot(snapshot),
  .audio_allowed(allow_audio),.allowed_epoch(allowed_epoch),.restore_picture(restore),.restore_index(index),
  .restore_valid(valid),.restore_id(pic),.status(status));
 task step;input integer n;begin repeat(n) @(negedge clk);end endtask
 task key;input [3:0] keycode;begin down=0;step(3);id=keycode;down=1;step(3);end endtask
 task response;input [7:0] val;input [31:0] e;begin code=val;reply_ep=e;reply_rev=rev;reply=1;step(1);reply=0;end endtask
 task reset_all;begin rst=1;b0=0;b1=0;down=0;fb=0;link=1;sreset=0;pic_ready=0;audio_ready=0;request_ready=0;step(4);rst=0;step(4);end endtask
 task source_on;input integer which;begin
  case(which) 0:b0=1;1:b1=1;2:key(11);endcase step(14);
 end endtask
 task source_off;input integer which;begin
  case(which) 0:b0=0;1:b1=0;2:key(11);endcase step(14);
 end endtask
 initial begin
  // All masks and six distinct chronological permutations.
  for(k=0;k<8;k=k+1) begin
   reset_all;b0=k[0];b1=k[1];if(k[2]) key(11);step(400);
   if(sources!==k[2:0] || active!==(k!=0)) $fatal(1,"source truth table %d",k);
   if(vsources!==sources || vgroups!==groups || ven!==(k!=0)) $fatal(1,"mailbox truth table");
   combinations=combinations+1;
  end
  for(a=0;a<3;a=a+1) for(b=0;b<3;b=b+1) for(c=0;c<3;c=c+1) if(a!=b && a!=c && b!=c) begin
   reset_all;source_on(a);source_on(b);source_on(c);
   if(groups!==((1<<a)|((1<<b)<<3)|((1<<c)<<6))) $fatal(1,"chronology %d %d %d groups=%h",a,b,c,groups);
   saved_rev=rev;source_off(b);
   if(groups!==((1<<a)|((1<<c)<<3)) || rev!=saved_rev) $fatal(1,"remove middle source");
   source_on(b);
   if(groups!==((1<<a)|((1<<c)<<3)|((1<<b)<<6)) || rev!=saved_rev) $fatal(1,"re-add to tail");
  end
  reset_all;b0=1;b1=1;step(14);
  if(groups!==9'd3) $fatal(1,"simultaneous GPIO group");
  source_on(2);if(groups!==9'd35) $fatal(1,"B0=B1 then C");
  source_off(0);if(groups!==9'd34) $fatal(1,"remove tied source");
  reset_all;b0=1;b1=1;
  // Align C press exactly with the GPIO confirmation edge.
  wait(inputs.accept0 && inputs.accept1);@(negedge clk);id=11;down=1;step(3);
  if(groups!==9'd7) $fatal(1,"three simultaneous sources %h",groups);
  step(30);if(sources!=7 || rev!=1) $fatal(1,"held C toggles repeatedly");
  // Stable filter rejects high and low glitches.
  reset_all;b0=1;step(3);b0=0;step(15);if(active) $fatal(1,"short high glitch");
  b0=1;step(15);b0=0;step(3);b0=1;step(15);if(sources!=1) $fatal(1,"short low glitch");
  // GPIO works without keypad. Keypad cancellation never clears latched C.
  reset_all;online=0;b1=1;step(15);if(sources!=2 || mode!=1) $fatal(1,"offline keypad blocks GPIO");
  online=1;down=0;step(3);key(11);cancel=1;step(4);cancel=0;step(4);if(sources!=6) $fatal(1,"cancel cleared C");
  // Snapshot, key neutrality, source changes, prefill and recovery reentry.
  reset_all;key(7);step(4);if(mode!=0 || active) $fatal(1,"B still enters emergency");
  key(11);step(20);fb=1;step(1);fb=0;step(4);
  if(mode!=1 || !req || snapshot!={32'd11,32'd7,32'd123,32'd15}) $fatal(1,"stable original snapshot");
  step(30);if(rev!=1) $fatal(1,"held C repeats");
  request_ready=1;step(2);response(`DB_EM_PLAYING,9);
  if(!allow_audio || allowed_epoch!=9) $fatal(1,"voice permission");
  b0=1;b1=1;step(15);key(11);step(4);
  if(mode!=1 || rev!=1 || !allow_audio || sources!=3) $fatal(1,"source change restarts audio/business");
  b0=0;step(15);if(mode!=1) $fatal(1,"partial clear exits");
  b1=0;step(15);if(mode!=2 || !hold_audio) $fatal(1,"last source recovery");
  step(400);if(!ven || vsources!=2) $fatal(1,"restore lost last alarm display");
  pic_ready=1;response(`DB_EM_RESTORED,10);step(5);if(mode!=2) $fatal(1,"exit before target prefill");
  key(11);step(5);if(mode!=1 || snapshot[63:32]!=123 || rev!=3) $fatal(1,"reentry changed original snapshot");
  sreset=1;step(1);sreset=0;link=0;step(4);if(mode!=1 || allow_audio || sources!=4) $fatal(1,"session loss cleared authority");
  key(11);step(400);if(mode!=0 || ven || groups!=0) $fatal(1,"offline clear failed");
  // High GPIO after system reset reactivates, while keyboard latch resets.
  rst=1;b0=1;step(4);rst=0;step(20);if(sources!=1 || mode!=1) $fatal(1,"boot high not detected");
  $display("*** PASS *** 8 masks, 6 permutations, ties, reactivation, filtering, C latch, B neutral, atomic mailbox, no audio restart, snapshot/recovery and reset");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
