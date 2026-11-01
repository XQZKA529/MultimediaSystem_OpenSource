`timescale 1ns/1ps
module tb_overlay_protocol;
 `include "db_crc.vh"
 reg clk=0,video_clk=0,rst=1,rx_meta_valid=0,rx_valid=0,rx_last=0;
 reg link_up=1,session_reset=0;
 reg [7:0] rx_channel=2,rx_opcode=0;reg [31:0] rx_object=7,rx_offset=0,rx_data=0;reg [15:0] rx_length=0;
 wire rx_meta_ready,rx_ready,tx_meta_valid;reg tx_meta_ready=1,tx_ready=1;
 wire [7:0] tx_channel,tx_opcode;wire [31:0] tx_object,tx_offset,tx_data;wire [15:0] tx_length;wire tx_valid,tx_last;
 wire write_en,overlay_write_en;wire [31:0] write_data,overlay_write_data;wire [10:0] overlay_write_addr;
 wire prep_toggle,commit_toggle,prep_ack,commit_ack;reg vs=0;integer frame_tick=0;
 wire [1:0] transition_mode;
 reg seen_ready=0,seen_applied=0;integer words=0,bad=0,i,pkt;reg [31:0] commit_before;
 reg [31:0] crc;
 seam_render #(.CLK_HZ(1000),.DIAG_HOLD_CYCLES(8)) dut(
  .emergency_image_idle(),.emergency_block(1'b0),.emergency_request_valid(1'b0),.emergency_request_ready(),
  .emergency_mode(2'd0),.emergency_revision(32'd0),.emergency_snapshot(128'd0),
  .emergency_reply_valid(),.emergency_reply_revision(),.emergency_reply_epoch(),.emergency_reply_status(),
  .emergency_picture_restored(1'b0),.emergency_restore_valid(1'b0),.emergency_restore_index(2'd0),.emergency_restore_id(32'd0),
  .display_image_id(),.subtitle_start(),.subtitle_revision(),.subtitle_start_ready(1'b1),
  .subtitle_data_valid(),.subtitle_data(),.subtitle_last(),.subtitle_data_ready(1'b1),
  .subtitle_applied(1'b0),.subtitle_applied_ready(),.subtitle_applied_revision(32'd0),.subtitle_applied_result(2'd0),
  .overlay_write_en(overlay_write_en),.overlay_write_addr(overlay_write_addr),.overlay_write_data(overlay_write_data),
  .overlay_prepare_toggle(prep_toggle),.overlay_commit_toggle(commit_toggle),.overlay_prepare_ack(prep_ack),.overlay_commit_ack(commit_ack),
  .keypad_valid(1'b0),.keypad_data(6'd0),.keypad_ready(),.video_clk(video_clk),.video_rst(rst),.vs(vs),
  .clk(clk),.rst(rst),.link_up(link_up),.session_reset(session_reset),
  .rx_meta_valid(rx_meta_valid),.rx_meta_ready(rx_meta_ready),.rx_required(1'b1),.rx_channel(rx_channel),.rx_opcode(rx_opcode),
  .rx_object(rx_object),.rx_offset(rx_offset),.rx_length(rx_length),.rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),.rx_last(rx_last),
  .tx_meta_valid(tx_meta_valid),.tx_meta_ready(tx_meta_ready),.tx_channel(tx_channel),.tx_opcode(tx_opcode),.tx_object(tx_object),
  .tx_offset(tx_offset),.tx_length(tx_length),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.tx_last(tx_last),
  .write_req(),.write_req_ack(1'b0),.write_abort(),.write_abort_ack(1'b0),.write_en(write_en),.write_data(write_data),
  .write_full(1'b0),.write_sector_ready(1'b1),.write_finish_toggle(1'b0),.read_selected_index(2'd0),.read_handoff_toggle(1'b0),
  .write_index(),.display_index(),.display_valid(),.transition_req(),.transition_new_index(),.transition_cur_index(),
  .transition_req_mode(),.transition_mode(transition_mode),.transition_ack(1'b0),.transition_done(1'b0),.transition_failed(1'b0),
  .ui_commit_seen(1'b0),.audio_packet_ready(1'b1),.audio_feedback(1'b0),.feedback_epoch(32'd0),.feedback_position(32'd0),.feedback_flags(3'd0),
        // Explicit defaults for the unused main-image/audio/UI environment.
        .text_osd_page(),.ui_active(),.ui_cursor_en(),.ui_commit_toggle(),
        .ui_page(),.ui_cursor_row(),.ui_wr_en(),.ui_wr_addr(),
        .ui_wr_data(),.volume_valid(),.volume_hint(),.volume_level(),
        .contrast_level(),.brightness_mode(2'd0),.brightness_level(),.diag(),
        .audio_begin(),.audio_stop(),.audio_eof(),.audio_pause(),
        .audio_freeze(),.audio_epoch(),.audio_total(),.audio_base(),
        .audio_push(),.audio_data()
    );
 always #5 clk=~clk;
 always #6.667 video_clk=~video_clk;
 always @(posedge video_clk) begin
   if(rst) begin vs<=0;frame_tick<=0;end
   else begin vs<=frame_tick==99;frame_tick<=frame_tick==99 ? 0:frame_tick+1;end
 end
 image_overlay_64 sprite(.wr_clk(clk),.wr_en(overlay_write_en),.wr_addr(overlay_write_addr),.wr_data(overlay_write_data),
   .video_clk(video_clk),.video_rst(rst),.hs_in(1'b0),.vs_in(vs),.de_in(1'b0),.rgb_in(24'd0),.enable_in(1'b1),
   .prepare_toggle(prep_toggle),.commit_toggle(commit_toggle),.prepare_ack(prep_ack),.commit_ack(commit_ack),
   .hs_out(),.vs_out(),.de_out(),.rgb_out());
 always @(posedge clk) begin
   if(!rst && tx_meta_valid && tx_meta_ready) begin
     if(tx_opcode==8'h17) seen_ready<=1;
     if(tx_opcode==8'h1a) seen_applied<=1;
   end
   if(!rst && overlay_write_en) begin
     if(overlay_write_addr!==((63-(words/32))*32+(words%32))) bad=bad+1;
     if(overlay_write_data!==32'h07e0f800) bad=bad+1;
     words=words+1;
   end
 end
 task meta;input [7:0] op;input [31:0] off;input [15:0] len;
 begin
   @(negedge clk);rx_channel=2;rx_opcode=op;rx_object=7;rx_offset=off;rx_length=len;rx_meta_valid=1;
   while(!rx_meta_ready) @(negedge clk);@(negedge clk);rx_meta_valid=0;repeat(3) @(negedge clk);
 end endtask
 task payload;input [31:0] value;input last;
 begin
   // Consecutive calls present accepted words on consecutive bus clocks.
   @(negedge clk);rx_data=value;rx_valid=1;rx_last=last;
   @(posedge clk);while(!rx_ready) @(posedge clk);#1;rx_valid=0;rx_last=0;
 end endtask
 initial begin
   repeat(5) @(negedge clk);rst=0;meta(8'h16,2048,0);
   wait(seen_ready);
   crc=32'hffffffff;
   for(pkt=0;pkt<8;pkt=pkt+1) begin
     meta(8'h18,pkt*1024,1024);
     for(i=0;i<256;i=i+1) begin
       crc=db_crc_byte(db_crc_byte(db_crc_byte(db_crc_byte(crc,8'h07),8'he0),8'hf8),8'h00);
       payload(32'h07e0f800,i==255);
     end
   end
   meta(8'h19,8192,4);payload(~crc,1);wait(seen_applied);repeat(6) @(negedge clk);
   if(words!=2048 || bad!=0) $fatal(1,"overlay writes=%0d bad=%0d",words,bad);
   $display("first image applied through real video frame handshake");
   commit_before=commit_toggle;seen_ready=0;seen_applied=0;words=0;meta(8'h16,2048,0);wait(seen_ready);crc=32'hffffffff;
   for(pkt=0;pkt<8;pkt=pkt+1) begin
     meta(8'h18,pkt*1024,1024);
     for(i=0;i<256;i=i+1) begin
       crc=db_crc_byte(db_crc_byte(db_crc_byte(db_crc_byte(crc,8'h07),8'he0),8'hf8),8'h00);
       payload(32'h07e0f800,i==255);
     end
   end
   meta(8'h19,8192,4);payload((~crc)^32'd1,1);repeat(40) @(negedge clk);
   if(seen_applied || commit_toggle!==commit_before || words!=2048 || bad!=0) $fatal(1,"bad CRC committed overlay");
   $display("bad CRC rejected; starting retry before next frame");
   seen_ready=0;seen_applied=0;meta(8'h16,2048,0);wait(seen_ready);meta(8'h18,0,4);payload(32'h07e0f800,1);
   @(negedge clk);link_up=0;session_reset=1;repeat(3) @(negedge clk);session_reset=0;link_up=1;repeat(5) @(negedge clk);
   meta(8'h19,8192,4);payload(~crc,1);repeat(40) @(negedge clk);
   if(seen_applied || commit_toggle!==commit_before) $fatal(1,"stale transaction committed after link/reset interruption");
   seen_ready=0;meta(8'h16,2048,0);wait(seen_ready);
   // Cancel and immediately retry before the pixel domain reaches its next VS.
   meta(8'h1b,0,0);seen_ready=0;meta(8'h16,2048,0);wait(seen_ready);
   meta(8'h1b,0,0);repeat(300) @(negedge clk);
   if(sprite.enabled_frame!==1'b0 || seen_applied) $fatal(1,"canceled transaction became visible");
   $display("*** PASS *** tb_overlay_protocol: real dual-clock VS handshake, CRC, immediate retry, session reset and abort recovery");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
