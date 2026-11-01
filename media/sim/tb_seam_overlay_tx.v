`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_seam_overlay_tx;
 `include "db_crc.vh"
 reg clk=0,rst=1,begin_req=0,abort_req=0,word_valid=0,source_ok=0,applied_reply=0;
 reg [31:0] begin_object=32'h42,word_data=32'h07e0f800;
 wire begin_ack,begin_ready,failed,word_ready,applied;
 reg rx_meta_valid=0;reg [7:0] rx_channel=0,rx_opcode=0;reg [31:0] rx_object=0,rx_offset=0,rx_data=0;reg [15:0] rx_length=0;
 wire rx_meta_ready,rx_ready;reg rx_valid=0,rx_last=0;
 wire tx_meta_valid;reg tx_meta_ready=1;wire [7:0] tx_channel,tx_opcode;wire [31:0] tx_object,tx_offset;wire [15:0] tx_length;wire tx_valid;reg tx_ready=1;wire [31:0] tx_data;wire tx_last;
 integer sent=0,remaining=0,packet_kind=0,bad=0;reg begin_seen=0,end_seen=0,ready_seen=0,applied_seen=0,failed_seen=0;reg [31:0] crc=32'hffffffff;
 seam_media dut(.saturation_level(5'd10),
  .clk(clk),.rst(rst),.link_up(1'b1),.session_reset(1'b0),
  .emergency_reply_valid(1'b0),.emergency_reply_revision(32'd0),.emergency_reply_status(8'd0),
  .subtitle_valid(1'b0),.subtitle_revision(32'd0),.subtitle_word_valid(1'b0),.subtitle_word(32'd0),
  .volume_level(5'd20),.volume_changed(1'b0),.volume_hint(1'b0),.volume_revision(32'd0),
  .image_req(1'b0),.image_word_valid(1'b0),.image_word(32'd0),.image_source_ok(1'b0),.image_source_failed(1'b0),
  .overlay_begin_req(begin_req),.overlay_begin_ack(begin_ack),.overlay_begin_ready(begin_ready),.overlay_failed(failed),
  .overlay_begin_object(begin_object),.overlay_abort_req(abort_req),.overlay_word_valid(word_valid),.overlay_word(word_data),
  .overlay_word_ready(word_ready),.overlay_source_ok(source_ok),.overlay_applied(applied),
  .pcm_push(1'b0),.pcm(32'd0),.pcm_clear(1'b0),.pcm_eof(1'b0),.pcm_total(32'd0),.pcm_base(32'd0),
  .pcm_stream_toggle(1'b0),.paused(1'b0),.seek_request(1'b0),.seek_execute(),.played_position(),.resume_request(),.remote_playing(),
  .ui_wr_en(1'b0),.ui_wr_addr(9'd0),.ui_wr_data(8'd0),
  .contrast_level(5'd10),.brightness_level(4'd10),.brightness_mode(),.transition_mode(2'd0),.text_osd_page(1'b0),.ui_active(1'b0),
  .ui_cursor_en(1'b0),.ui_cursor_row(4'd0),.ui_page(4'd0),.ui_commit_toggle(1'b0),.diag(4'd15),
  .rx_meta_valid(rx_meta_valid),.rx_meta_ready(rx_meta_ready),.rx_required(1'b1),.rx_channel(rx_channel),.rx_opcode(rx_opcode),
  .rx_object(rx_object),.rx_offset(rx_offset),.rx_length(rx_length),.rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),.rx_last(rx_last),
  .tx_meta_valid(tx_meta_valid),.tx_meta_ready(tx_meta_ready),.tx_channel(tx_channel),.tx_opcode(tx_opcode),.tx_object(tx_object),
  .tx_offset(tx_offset),.tx_length(tx_length),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.tx_last(tx_last),.overflow());
 always #5 clk=~clk;
 always @(posedge clk) if(begin_ready) ready_seen<=1;
 always @(posedge clk) if(applied) applied_seen<=1;
 always @(posedge clk) if(failed) failed_seen<=1;
 always @(posedge clk) if(!rst) begin
   if(tx_meta_valid && tx_meta_ready && tx_channel==2) begin
     if(tx_object!=begin_object) begin $display("bad object %h expected %h op %h",tx_object,begin_object,tx_opcode);bad=bad+1;end
     case(tx_opcode)
       `DB_OVL_BEGIN:begin if(tx_offset!=2048 || tx_length!=0) begin $display("bad begin off=%0d len=%0d",tx_offset,tx_length);bad=bad+1;end begin_seen<=1;packet_kind<=0;end
       `DB_OVL_DATA:begin
         if(tx_offset!=sent*4 || tx_length==0 || tx_length[1:0]!=0) begin $display("bad data off=%0d expected=%0d len=%0d",tx_offset,sent*4,tx_length);bad=bad+1;end
         remaining<=tx_length>>2;packet_kind<=1;
       end
       `DB_OVL_END:begin if(tx_offset!=8192 || tx_length!=4) begin $display("bad end off=%0d len=%0d",tx_offset,tx_length);bad=bad+1;end packet_kind<=2;end
       `DB_OVL_ABORT:packet_kind<=0;
       default:begin $display("bad opcode %h",tx_opcode);bad=bad+1;end
     endcase
   end
   if(tx_valid && tx_ready && tx_channel==2) begin
     if(packet_kind==1) begin
       if(tx_data!=32'h07e0f800) begin $display("bad data word %h",tx_data);bad=bad+1;end
       crc<=db_crc_byte(db_crc_byte(db_crc_byte(db_crc_byte(crc,tx_data[31:24]),tx_data[23:16]),tx_data[15:8]),tx_data[7:0]);
       sent<=sent+1;remaining<=remaining-1;
     end else if(packet_kind==2) begin
       if(tx_data!=~crc) begin $display("bad crc %h expected %h",tx_data,~crc);bad=bad+1;end end_seen<=1;packet_kind<=0;
     end
   end
 end
 task send_control;input [7:0] op;input [31:0] id;begin
   @(negedge clk);rx_channel=0;rx_opcode=op;rx_object=id;rx_offset=0;rx_length=0;rx_meta_valid=1;
   while(!rx_meta_ready) @(negedge clk);@(negedge clk);rx_meta_valid=0;repeat(3) @(negedge clk);
 end endtask
 task offer_word;begin
   while(!word_ready) @(negedge clk);@(negedge clk);word_valid=1;@(negedge clk);word_valid=0;
 end endtask
 initial begin
   repeat(4) @(negedge clk);rst=0;@(negedge clk);begin_req=1;wait(begin_ack);@(negedge clk);begin_req=0;
   wait(begin_seen);send_control(`DB_OVL_READY,begin_object);wait(ready_seen);
   repeat(2048) offer_word();source_ok=1;wait(end_seen);send_control(`DB_OVL_APPLIED,begin_object);wait(applied_seen);repeat(4) @(negedge clk);
   if(sent!=2048 || bad!=0 || failed) $fatal(1,"TX words=%0d bad=%0d failed=%b",sent,bad,failed);
   // Deliberately collide with the retired reset main-image ID. ERROR must
   // still reach the active overlay, even for an older peer's low-valued ID.
   source_ok=0;begin_object=0;begin_seen=0;
   @(negedge clk);begin_req=1;wait(begin_ack);@(negedge clk);begin_req=0;
   wait(begin_seen);send_control(`DB_ERROR,begin_object);wait(failed_seen);
   repeat(6) @(negedge clk);if(word_ready || bad) $fatal(1,"overlay ERROR was swallowed by a retired main image");
   $display("*** PASS *** tb_seam_overlay_tx: 2048 words, CRC/APPLIED and ERROR dispatch with retired main-image ID collision");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
