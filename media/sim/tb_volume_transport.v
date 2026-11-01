`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_volume_transport;
    reg clk=0,rst=1,live=0,sreset=0,changed=0,hint=0,ready=0;
    reg [4:0] level=20;reg [31:0] revision=0;
    wire mv;wire [7:0] ch,op;wire [31:0] obj,off;wire [15:0] len;
    integer packets=0;
    always #5 clk=~clk;
    seam_media dut(.saturation_level(5'd10),.clk(clk),.rst(rst),.link_up(live),.session_reset(sreset),
        .subtitle_valid(1'b0),.subtitle_revision(32'd0),.subtitle_word(32'd0),.subtitle_word_valid(1'b0),
        .volume_level(level),.volume_changed(changed),.volume_hint(hint),.volume_revision(revision),
        .image_req(1'b0),.image_word_valid(1'b0),.image_word(32'd0),.image_source_ok(1'b0),.image_source_failed(1'b0),
        .pcm_push(1'b0),.pcm(32'd0),.pcm_clear(1'b0),.pcm_eof(1'b0),.pcm_total(32'd0),.pcm_base(32'd0),
        .pcm_stream_toggle(1'b0),.paused(1'b0),.seek_request(1'b0),
        .ui_wr_en(1'b0),.ui_wr_addr(9'd0),.ui_wr_data(8'd0),.ui_commit_toggle(1'b0),
        .text_osd_page(1'b0),.ui_active(1'b0),.ui_cursor_en(1'b0),.ui_cursor_row(4'd0),
        .contrast_level(5'd10),.brightness_level(4'd10),.diag(4'd15),
        .rx_meta_valid(1'b0),.rx_required(1'b0),.rx_channel(8'd0),.rx_opcode(8'd0),.rx_object(32'd0),.rx_offset(32'd0),.rx_length(16'd0),
        .rx_valid(1'b0),.rx_data(32'd0),.rx_last(1'b0),
        .tx_meta_valid(mv),.tx_meta_ready(ready),.tx_channel(ch),.tx_opcode(op),.tx_object(obj),.tx_offset(off),.tx_length(len),.tx_ready(1'b1));
    task step;input integer n;begin repeat(n) @(negedge clk);end endtask
    task action;input [4:0] n;input h;begin level=n;hint=h;changed=1;revision=revision+1;step(1);changed=0;step(1);end endtask
    task expect_message;input [4:0] n;input h;input [31:0] version;
        begin wait(mv && op==`DB_VOLUME_SET);#1;
            if(ch!=0 || len!=0 || off!=={26'd0,h,n} || obj!==version) $fatal(1,"Volume message shape/value");
            ready=1;step(1);ready=0;packets=packets+1;
        end
    endtask
    initial begin
        step(4);rst=0;step(3);live=1;expect_message(20,0,0);
        // Drain the unrelated initial STATUS, then hold a volume metadata offer.
        ready=1;step(12);ready=0;action(19,1);wait(mv && op==`DB_VOLUME_SET);
        action(18,1);action(17,0);step(8);
        if(off!=={26'd0,1'b1,5'd19} || obj!=1) $fatal(1,"Offered packet changed under backpressure");
        expect_message(19,1,1);expect_message(17,0,3);
        action(0,1);wait(mv && op==`DB_VOLUME_SET);sreset=1;live=0;step(2);sreset=0;step(3);live=1;
        expect_message(0,0,4);
        if(packets!=4) $fatal(1,"Lost coalesced/replay configuration");
        $display("*** PASS *** volume transport: zero payload, priority, frozen metadata, latest coalescing, silent session replay");$finish;
    end
    initial begin #100000;$fatal(1,"Transport watchdog");end
endmodule
