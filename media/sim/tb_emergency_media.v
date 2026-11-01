`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_emergency_media;
 reg clk=0,rst=1,link=1,sreset=0,req=0;reg [1:0] mode=1;reg [31:0] revision=1;
 reg [127:0] snapshot={32'd5,32'd7,32'd1234,32'd15};
 reg found=1,ack=0,reject=0,image_event=0,stream_toggle=0;reg [31:0] epoch=7,pos=0,cluster=20,size=10000;
 reg [31:0] img_id=5,img_cluster=10,img_size=500;reg img_idle=1;
 wire ctx_req,ctx_we,history_hold,prep,prep_size;wire [3:0] ctx_addr,ctx_read_addr;wire [63:0] ctx_data;reg [63:0] ctx_q=0;
 reg [63:0] mem[0:15];wire [31:0] prep_word;reg [31:0] prepared_cluster=0,prepared_size=0,restored_cluster=0;
 wire block,close,play,stop,paused,restore,reply;wire [31:0] pcl,psz,pstart,rcl,rsz,rrev,rep_epoch;wire [7:0] code;
 always @(posedge clk) begin
  if(ctx_req && img_idle) begin if(ctx_we) mem[ctx_addr]<=ctx_data;ctx_q<=mem[ctx_read_addr];end
  if(restore) restored_cluster<=rcl;
  if(prep) begin if(prep_size) prepared_size<=prep_word;else prepared_cluster<=prep_word;end
 end

 always #5 clk=~clk;
 emergency_media_controller #(.CLK_HZ(1000)) dut(.clk(clk),.rst(rst),.link_up(link),.session_reset(sreset),
  .request_valid(req),.request_mode(mode),.request_revision(revision),.request_snapshot(snapshot),
  .emergency_found(found),.catalog_done(1'b1),.emergency_cluster(32'd99),.emergency_size(32'd4096),
  .track_stream_toggle(stream_toggle),.track_cluster(cluster),.track_size(size),.audio_epoch(epoch),.audio_file_epoch(epoch),.audio_consumed_epoch(epoch),.audio_dispatch_epoch(epoch),.audio_dispatch_valid(1'b0),.total_frames(32'd100),.played_position(pos),
  .track_ack(ack),.track_rejected(reject),.track_idle(1'b1),.track_status(4'd3),.normal_pause(1'b1),
  .image_presented(image_event),.image_id(img_id),.image_cluster(img_cluster),.image_size(img_size),.image_idle(img_idle),
  .ctx_req(ctx_req),.ctx_we(ctx_we),.ctx_addr(ctx_addr),.ctx_read_addr(ctx_read_addr),.ctx_data(ctx_data),.ctx_ready(img_idle),.ctx_q(ctx_q),
  .prepare_restore(prep),.prepare_size(prep_size),.prepare_word(prep_word),.prepared_cluster(prepared_cluster),.prepared_size(prepared_size),
  .history_hold(history_hold),.block_normal(block),.force_close(close),.play_req(play),.play_stop(stop),.play_cluster(pcl),.play_size(psz),.play_position(pstart),
  .play_paused(paused),.restore_selection(restore),.restore_cluster(rcl),.restore_size(rsz),
  .reply_valid(reply),.reply_ready(1'b1),.reply_revision(rrev),.reply_epoch(rep_epoch),.reply_status(code));
 task step;input integer n;begin repeat(n) @(negedge clk);end endtask
 task request;input [1:0] m;begin mode=m;revision=revision+1;req=1;step(1);req=0;end endtask
 task started;begin epoch=epoch+1;ack=1;step(1);ack=0;step(2);end endtask
 initial begin
  step(3);rst=0;image_event=1;step(1);image_event=0;wait(!history_hold);step(3);
  stream_toggle=1;step(1);wait(!history_hold);step(3);
  request(1);wait(play);#1;
  if(pcl!=99 || psz!=4096 || pstart!=0 || paused || !block) $fatal(1,"emergency request");
  step(2);started;if(code!=`DB_EM_PLAYING) $fatal(1,"playing status");
  img_idle=0;img_id=6;img_cluster=30;img_size=600;image_event=1;step(1);image_event=0;step(5);img_idle=1;
  cluster=99;size=4096;pos=99;step(8);if(play) $fatal(1,"loop before consumption end");
  pos=100;wait(play);pos=0;step(2);started;
  request(2);wait(play);#1;
  if(pcl!=20 || psz!=10000 || pstart!=1234 || !paused || restored_cluster!=10) $fatal(1,"normal restoration");
  step(2);started;if(code!=`DB_EM_RESTORED || !block) $fatal(1,"completion before render acknowledgement");
  request(1);wait(play);#1;if(mem[4][63:32]!=20 || mem[5][63:32]!=1234) $fatal(1,"reentry overwrote snapshot");
  step(2);started;request(2);wait(play);step(2);started;request(0);step(2);if(block) $fatal(1,"exit ack");
  found=0;request(1);wait(code==`DB_EM_MISSING);if(!block) $fatal(1,"missing file visual-only");
  request(2);step(5);request(0);step(3);
  // Picture-only snapshot from a reset media cannot be called fully restored.
  rst=1;step(3);rst=0;snapshot={32'd5,32'd0,32'd0,32'd12};found=1;
  request(2);wait(code==`DB_EM_LOST);
  $display("*** PASS *** background commit bank preservation, reset loss and specified WAV, real-consumption loop, exact position/pause, image cursor, reentry and missing file");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
