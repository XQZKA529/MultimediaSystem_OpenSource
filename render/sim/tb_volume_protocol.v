`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_volume_protocol;
    reg clk=0,rst=1,sreset=0,mv=0,dv=0;reg [7:0] channel=0;
    reg [31:0] offset=20;reg [15:0] length=0;
    wire mr,valid,hint;wire [4:0] level;integer deliveries=0;
    always #5 clk=~clk;
    always @(negedge clk) if(valid) deliveries=deliveries+1;
    seam_render dut(.clk(clk),.rst(rst),.link_up(1'b1),.session_reset(sreset),
        .keypad_valid(1'b0),.keypad_data(6'd0),.volume_valid(valid),.volume_hint(hint),.volume_level(level),
        .video_clk(clk),.video_rst(rst),.vs(1'b0),.brightness_mode(2'd2),
        .rx_meta_valid(mv),.rx_meta_ready(mr),.rx_required(1'b0),.rx_channel(channel),
        .rx_opcode(`DB_VOLUME_SET),.rx_object(32'hffffffff),.rx_offset(offset),.rx_length(length),
        .rx_valid(dv),.rx_data(32'd0),.rx_last(dv),
        .tx_meta_ready(1'b1),.tx_ready(1'b1),.write_req_ack(1'b0),.write_abort_ack(1'b1),
        .write_full(1'b0),.write_sector_ready(1'b1),.write_finish_toggle(1'b0),
        .read_selected_index(2'd0),.read_handoff_toggle(1'b0),
        .transition_ack(1'b0),.transition_done(1'b0),.transition_failed(1'b0),.ui_commit_seen(1'b0),
        .audio_packet_ready(1'b1),.audio_feedback(1'b0),.feedback_epoch(32'd0),.feedback_position(32'd0),.feedback_flags(3'd0));
    task message;input [7:0] ch;input [15:0] len;input [31:0] off;input accepted;
        begin @(negedge clk);channel=ch;length=len;offset=off;mv=1;
            @(posedge clk);while(!mr) @(posedge clk);#1;
            if(valid!==accepted) $fatal(1,"Volume validation channel/length/reserved/level");
            if(accepted && (level!==off[4:0] || hint!==off[5])) $fatal(1,"Volume semantic decode");
            @(negedge clk);mv=0;
            // Malformed nonzero payload must drain before another header.
            if(len!=0) begin dv=1;@(negedge clk);dv=0;end
            repeat(3) @(negedge clk);
        end
    endtask
    integer n;
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(n=0;n<=20;n=n+1) message(0,0,n|32,1);
        message(0,0,21,0);message(0,0,31,0);message(0,0,64,0);
        message(1,0,0,0);message(2,0,0,0);message(0,4,0,0);
        if(level!=20) $fatal(1,"Malformed message changed configuration");
        sreset=1;repeat(2) @(negedge clk);sreset=0;
        if(level!=20 || hint!=0) $fatal(1,"Session retention");
        message(0,0,0,1);
        if(deliveries!=22) $fatal(1,"Delivery pulses repeated");
        $display("*** PASS *** volume decoder: 21 levels, hint, malformed channel/length/reserved/level, session retention, one delivery pulse");$finish;
    end
    initial begin #100000;$fatal(1,"Protocol watchdog");end
endmodule
