`timescale 1ns/1ps
module tb_key_click;
    reg clk=0,rst=1,enable=1,cancel=0,p=0,r=0,h=0;
    wire single_event,double_event;
    integer singles=0,doubles=0;
    always #5 clk=~clk;
    key_click_decode #(.CLK_FREQ_HZ(1000),.DBL_WIN_MS(8)) dut(
        .clk(clk),.rst(rst),.enable(enable),.cancel(cancel),
        .ev_press(p),.ev_release(r),.ev_hold(h),.single_pulse(single_event),.double_pulse(double_event));
    always @(posedge clk) begin
        if(single_event) singles=singles+1;
        if(double_event) doubles=doubles+1;
        if(single_event && double_event) $fatal(1,"Overlapping click events");
    end
    task press;begin @(negedge clk);p=1;@(negedge clk);p=0;end endtask
    task release_key;begin @(negedge clk);r=1;@(negedge clk);r=0;end endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        press;release_key;repeat(10) @(negedge clk);
        if(singles!=1 || doubles!=0) $fatal(1,"Single click");
        press;release_key;repeat(3) @(negedge clk);press;release_key;
        repeat(12) @(negedge clk);
        if(singles!=1 || doubles!=1) $fatal(1,"Double leaked a single");
        // Second press on the expiry cycle must win.
        press;release_key;repeat(6) @(negedge clk);press;release_key;
        repeat(12) @(negedge clk);
        if(singles!=1 || doubles!=2) $fatal(1,"Boundary priority");
        press;@(negedge clk);h=1;@(negedge clk);h=0;release_key;
        repeat(12) @(negedge clk);
        if(singles!=1) $fatal(1,"Long press leaked single");
        press;release_key;@(negedge clk);cancel=1;@(negedge clk);cancel=0;
        repeat(12) @(negedge clk);
        if(singles!=1) $fatal(1,"Cancel leaked single");
        press;@(negedge clk);enable=0;repeat(3) @(negedge clk);enable=1;
        release_key;repeat(12) @(negedge clk);
        if(singles!=1) $fatal(1,"Held key crossed context");
        $display("*** PASS *** key clicks: single/double/boundary/hold/context");$finish;
    end
endmodule
