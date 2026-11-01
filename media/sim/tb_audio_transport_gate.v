`timescale 1ns/1ps
module tb_audio_transport_gate;
    reg clk=0,rst=1,ui=0,p=0,r=0,h=0,new_track=0;
    wire paused,next_req,seek;
    integer nexts=0,seeks=0;
    always #5 clk=~clk;
    audio_transport #(.CLK_FREQ_HZ(1000),.DBL_WIN_MS(8)) dut(.action_pause(1'b0),.action_next(1'b0),
        .clk(clk),.rst(rst),.i_playing(1'b1),.i_ui_active(ui),.i_new_track(new_track),
        .ev_press(p),.ev_release(r),.ev_hold(h),.o_pause(paused),.o_next_req(next_req),.o_seek_fwd(seek));
    always @(posedge clk) begin if(next_req) nexts=nexts+1;if(seek) seeks=seeks+1;end
    task tap;begin @(negedge clk);p=1;@(negedge clk);p=0;r=1;@(negedge clk);r=0;end endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        tap;repeat(2) @(negedge clk);ui=1;repeat(12) @(negedge clk);
        if(paused || nexts || seeks) $fatal(1,"Deferred audio gesture crossed into menu");
        ui=0;tap;repeat(12) @(negedge clk);if(!paused) $fatal(1,"Normal pause lost");
        tap;tap;repeat(12) @(negedge clk);if(nexts!=1) $fatal(1,"Audio double click lost");
        @(negedge clk);p=1;@(negedge clk);p=0;h=1;@(negedge clk);h=0;r=1;@(negedge clk);r=0;
        repeat(12) @(negedge clk);if(seeks!=1) $fatal(1,"Audio long press lost");
        new_track=1;@(negedge clk);new_track=0;@(negedge clk);if(paused) $fatal(1,"New track reset lost");
        $display("*** PASS *** audio context cancellation and existing short/double/long gestures");$finish;
    end
endmodule
