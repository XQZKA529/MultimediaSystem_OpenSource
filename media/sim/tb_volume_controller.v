`timescale 1ns/1ps
module tb_volume_controller;
    reg clk=0,rst=1,inc=0,dec=0,shortcut=0;
    wire [4:0] level;wire changed,hint;wire [31:0] revision;
    integer i;
    always #5 clk=~clk;
    volume_controller dut(.clk(clk),.rst(rst),.increase(inc),.decrease(dec),.shortcut(shortcut),
        .level(level),.changed(changed),.hint(hint),.revision(revision));
    task action;
        input a,b,c;input [4:0] want;input change,notify;
        begin @(negedge clk);inc=a;dec=b;shortcut=c;@(posedge clk);#1;
            if(level!==want || changed!==change || hint!==notify) $fatal(1,"Volume owner action/boundary");
            @(negedge clk);inc=0;dec=0;shortcut=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        action(1,0,0,20,0,0);action(1,0,1,20,1,1);
        for(i=19;i>=0;i=i-1) action(0,1,0,i,1,0);
        action(0,1,0,0,0,0);action(0,1,1,0,1,1);
        action(1,1,1,0,0,0);
        for(i=1;i<=20;i=i+1) action(1,0,1,i,1,1);
        if(revision!=42) $fatal(1,"Operation revision mismatch");
        @(negedge clk);rst=1;@(negedge clk);rst=0;
        if(level!=20 || revision!=0) $fatal(1,"Reset defaults");
        $display("*** PASS *** independent volume owner: all 21 levels, bounds, hint, simultaneous actions, reset");$finish;
    end
endmodule
