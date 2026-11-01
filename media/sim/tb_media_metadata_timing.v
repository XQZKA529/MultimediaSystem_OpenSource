`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_media_metadata_timing;
    reg clk=0,rst=1,req=0,rmv=0;
    reg [7:0] rop=0;
    reg [31:0] robj=0;
    wire ready,ack,finish,mv;
    wire [7:0] op;
    wire [31:0] obj;
    integer acks=0,presentations=0,checks=0;
    wire presented;
    always #5 clk=~clk;
    seam_media #(.FRAME_WORDS(64)) dut(.saturation_level(5'd10),
        .clk(clk),.rst(rst),.link_up(1'b1),.session_reset(1'b0),
        .volume_level(5'd20),.volume_changed(1'b0),.volume_hint(1'b0),.volume_revision(32'd0),
        .subtitle_valid(1'b0),.subtitle_word_valid(1'b0),.subtitle_word(32'd0),.subtitle_revision(32'd0),.emergency_reply_valid(1'b0),.transition_mode(2'd0),.ui_page(4'd0),.contrast_level(5'd10),.brightness_level(4'd10),
        .image_req(req),.image_ack(ack),.image_finish_toggle(finish),.image_presented(presented),
        .image_word_valid(1'b0),.image_word(32'd0),.image_source_ok(1'b0),.image_source_failed(1'b0),
        .overlay_begin_req(1'b0),.overlay_begin_object(32'd0),.overlay_abort_req(1'b0),
        .overlay_word_valid(1'b0),.overlay_word(32'd0),.overlay_source_ok(1'b0),
        .pcm_push(1'b0),.pcm(32'd0),.pcm_clear(1'b0),.pcm_eof(1'b0),.pcm_total(32'd0),.pcm_base(32'd0),
        .pcm_stream_toggle(1'b0),.paused(1'b0),.seek_request(1'b0),
        .ui_wr_en(1'b0),.ui_wr_addr(9'd0),.ui_wr_data(8'd0),.text_osd_page(1'b0),.ui_active(1'b0),
        .ui_cursor_en(1'b0),.ui_cursor_row(4'd0),.ui_commit_toggle(1'b0),.diag(4'd15),
        .rx_meta_valid(rmv),.rx_meta_ready(ready),.rx_required(1'b1),.rx_channel(8'd0),
        .rx_opcode(rop),.rx_object(robj),.rx_offset(32'd0),.rx_length(16'd0),
        .rx_valid(1'b0),.rx_data(32'd0),.rx_last(1'b0),
        .tx_meta_valid(mv),.tx_meta_ready(1'b1),.tx_opcode(op),.tx_object(obj),.tx_ready(1'b1));
    always @(posedge clk) if(!rst) begin
        if(ack)acks=acks+1;
        if(presented)presentations=presentations+1;
    end
    task tick;input integer n;begin repeat(n)@(negedge clk);end endtask
    task reply;input [7:0] code;input [31:0] id;
        begin
            rop=code;robj=id;rmv=1;
            while(!ready)tick(1);
            tick(1);rmv=0;tick(3);
        end
    endtask
    reg [31:0] old_id,new_id;
    integer phase,code;
    initial begin
        tick(4);rst=0;tick(10);
        // Replace an active image on either edge of metadata qualification.
        for(code=0;code<2;code=code+1)for(phase=0;phase<2;phase=phase+1)begin
            req=1;tick(1);req=0;tick(3);old_id=dut.image_id;
            rop=code==0 ? `DB_IMG_READY:`DB_IMG_PRESENTED;robj=old_id;rmv=1;
            if(phase!=0)tick(1);
            req=1;
            #1;if(ready!==0)$fatal(1,"replacement did not stall stale descriptor");
            tick(1);req=0;new_id=dut.image_id;
            while(!ready)tick(1);
            tick(1);rmv=0;tick(3);
            if(acks!=checks || presentations!=0 || !dut.image_active || dut.image_ready)
                $fatal(1,"stale reply changed replacement image phase=%0d opcode=%0d",phase,code);
            reply(`DB_IMG_READY,new_id);checks=checks+1;
            if(acks!=checks || !dut.image_ready)$fatal(1,"current image ACK lost");
            reply(`DB_IMG_PRESENTED,new_id);
            if(presentations!=1 || dut.image_active)$fatal(1,"current image presentation lost");
            presentations=0;
        end
        $display("*** PASS *** metadata timing: stale READY/PRESENTED across both replacement edges, current replies retained");
        $finish;
    end
    initial begin #200000;$fatal(1,"metadata watchdog");end
endmodule
