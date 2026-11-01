`timescale 1ns/1ps
module tb_calendar_clock;
    reg clk=0,rst=1,en=0,cancel=0,up=0,down=0,left=0,right=0,confirm=0;
    wire [32:0] live,draft;wire [2:0] focus;wire editing;
    reg [65:0] vectors[0:36524];reg [4095:0] file_name;
    integer i;
    always #5 clk=~clk;
    calendar_clock #(.CLK_HZ(64)) dut(.clk(clk),.rst(rst),.edit_enable(en),.cancel(cancel),
        .up(up),.down(down),.left(left),.right(right),.confirm(confirm),
        .live(live),.draft(draft),.focus(focus),.editing(editing));
    task step;input integer n;begin repeat(n) @(negedge clk);end endtask
    task key;input integer k;begin
        @(negedge clk);case(k) 0:up=1;1:down=1;2:left=1;3:right=1;4:confirm=1;endcase
        step(1);up=0;down=0;left=0;right=0;confirm=0;
    end endtask
    task load_time;input [32:0] t;begin
        @(negedge clk);dut.draft=t;dut.focus=6;dut.editing=1;dut.ready_d=1;en=1;confirm=1;
        step(1);confirm=0;
        if(live!==t || dut.fraction!==0) $fatal(1,"Apply must atomically set time and reset fraction");
    end endtask
    initial begin
        if(!$value$plusargs("CALENDAR_VECTORS=%s",file_name)) $fatal(1,"Missing Gregorian oracle");
        $readmemh(file_name,vectors);
        step(4);rst=0;step(1);
        if(live!=={7'd0,4'd1,5'd1,5'd0,6'd0,6'd0}) $fatal(1,"Default time");
        for(i=0;i<36525;i=i+1) begin
            load_time(vectors[i][65:33]);step(63);
            if(live!==vectors[i][65:33]) $fatal(1,"Early second at vector %d",i);
            step(1);if(live!==vectors[i][32:0]) $fatal(1,"Gregorian rollover %d got %h want %h",i,live,vectors[i][32:0]);
        end
        load_time({7'd24,4'd1,5'd1,5'd12,6'd34,6'd58});step(64);
        if(live[5:0]!=59) $fatal(1,"Second increment");step(64);
        if(live[11:0]!={6'd35,6'd0}) $fatal(1,"Minute increment");
        // Apply wins over the normal second even at the exact divider boundary.
        @(negedge clk);dut.fraction=63;dut.draft={7'd0,4'd1,5'd1,5'd0,6'd0,6'd7};confirm=1;
        step(1);confirm=0;if(live[5:0]!=7 || dut.fraction!=0) $fatal(1,"Apply/tick priority");
        en=0;step(1);en=1;step(2);if(!editing || focus!=0 || draft!==live) $fatal(1,"Entry snapshot");
        key(0);if(focus!=6) $fatal(1,"Focus up wrap");key(1);if(focus!=0) $fatal(1,"Focus down wrap");
        @(negedge clk);dut.draft={7'd0,4'd2,5'd29,5'd23,6'd59,6'd59};dut.focus=0;
        key(3);if(draft[32:26]!=1 || draft[21:17]!=28) $fatal(1,"Year clamps leap day");
        key(2);if(draft[32:26]!=0 || draft[21:17]!=28) $fatal(1,"Leap year change cannot invent day");
        @(negedge clk);dut.draft={7'd24,4'd1,5'd31,5'd23,6'd59,6'd59};dut.focus=1;
        key(3);if(draft[25:22]!=2 || draft[21:17]!=29) $fatal(1,"Month clamps day");
        @(negedge clk);dut.focus=2;key(3);if(draft[21:17]!=1) $fatal(1,"Day high wrap");key(2);if(draft[21:17]!=29) $fatal(1,"Day low wrap");
        @(negedge clk);dut.focus=3;key(3);if(draft[16:12]!=0) $fatal(1,"Hour wrap");key(2);if(draft[16:12]!=23) $fatal(1,"Hour low wrap");
        @(negedge clk);dut.focus=4;key(3);if(draft[11:6]!=0) $fatal(1,"Minute wrap");key(2);if(draft[11:6]!=59) $fatal(1,"Minute low wrap");
        @(negedge clk);dut.focus=5;key(3);if(draft[5:0]!=0) $fatal(1,"Second wrap");key(2);if(draft[5:0]!=59) $fatal(1,"Second low wrap");
        @(negedge clk);dut.focus=0;dut.draft[32:26]=99;key(3);if(draft[32:26]!=0) $fatal(1,"Year high wrap");key(2);if(draft[32:26]!=99) $fatal(1,"Year low wrap");
        @(negedge clk);dut.focus=1;dut.draft[25:22]=12;key(3);if(draft[25:22]!=1) $fatal(1,"Month high wrap");key(2);if(draft[25:22]!=12) $fatal(1,"Month low wrap");
        // Confirm on a field cannot apply; cancelling cannot overwrite live.
        load_time({7'd26,4'd10,5'd14,5'd0,6'd0,6'd0});
        @(negedge clk);dut.focus=2;dut.draft[21:17]=15;key(4);if(live[21:17]!=14) $fatal(1,"Confirm on field applied");
        cancel=1;step(1);cancel=0;if(editing || live[21:17]!=14) $fatal(1,"Cancel mutated live");
        en=0;step(64);if(live[5:0]==0) $fatal(1,"Clock stopped with editor closed");
        $display("*** PASS *** all 36525 Gregorian day boundaries, year/month/date/time/focus wraps, clamps, divider and apply/cancel priority");$finish;
    end
    initial begin #30000000;$fatal(1,"Calendar watchdog");end
endmodule
