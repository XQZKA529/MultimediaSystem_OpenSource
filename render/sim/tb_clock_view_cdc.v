`timescale 1ns/1ps
module tb_clock_view_cdc;
    reg clk=0,vclk=0,rst=1,vrst=1,vs=0,editing=0;reg [2:0] focus=0;
    reg [32:0] live={7'd26,4'd10,5'd14,5'd12,6'd34,6'd56},draft={7'd99,4'd12,5'd31,5'd23,6'd59,6'd59};
    wire [47:0] ld,dd;wire [2:0] vf;wire ve;
    always #5 clk=~clk;always #7 vclk=~vclk;
    clock_view_cdc dut(.clk(clk),.rst(rst),.live(live),.draft(draft),.focus(focus),.editing(editing),
        .video_clk(vclk),.video_rst(vrst),.vs(vs),.live_digits(ld),.draft_digits(dd),.video_focus(vf),.video_editing(ve));
    task step;input integer n;begin repeat(n) @(negedge clk);end endtask
    task frame;begin @(negedge vclk);vs=1;repeat(3) @(negedge vclk);vs=0;step(20);end endtask
    initial begin
        step(5);rst=0;vrst=0;editing=1;focus=6;step(150);
        if(ld!==48'h000101000000 || ve) $fatal(1,"Mailbox changed before frame boundary");
        frame;if(ld!==48'h261014123456 || dd!==48'h991231235959 || vf!=6 || !ve) $fatal(1,"BCD snapshot fields");
        live={7'd0,4'd2,5'd29,5'd0,6'd1,6'd9};editing=0;focus=0;step(170);
        if(ld!==48'h261014123456 || !ve) $fatal(1,"Midframe tear");frame;
        if(ld!==48'h000229000109 || ve) $fatal(1,"Updated snapshot");
        // A video-only reset keeps the source date and republishes without a source change.
        vrst=1;step(20);vrst=0;step(180);frame;
        if(ld!==48'h000229000109 || dd!==48'h991231235959) $fatal(1,"Video reset lost clock");
        // A source change during conversion must coalesce to a complete latest view.
        live={7'd12,4'd3,5'd4,5'd5,6'd6,6'd7};step(30);
        live={7'd87,4'd9,5'd8,5'd7,6'd6,6'd5};step(270);frame;
        if(ld!==48'h870908070605) $fatal(1,"Latest snapshot lost during conversion");
        live={7'd26,4'd10,5'd14,5'd12,6'd34,6'd56};step(170);
        if(!dut.request) $fatal(1,"Pending mailbox not exercised");
        vrst=1;step(20);vrst=0;step(170);frame;
        if(ld!==48'h261014123456) $fatal(1,"Reset with pending request lost snapshot");
        $display("*** PASS *** asynchronous clock snapshots, BCD formatting, frame atomicity, coalescing and video-only reset");$finish;
    end
    initial begin #50000;$fatal(1,"CDC watchdog");end
endmodule
