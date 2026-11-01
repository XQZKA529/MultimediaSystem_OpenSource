`timescale 1ns/1ps
module tb_brightness_scale;
    reg clk=0,rst=1,h=0,v=0,d=0;
    reg [3:0] level=10;
    reg [23:0] rgb=0;
    wire ho,vo,deo;wire [23:0] out;
    reg [23:0] expected;
    integer l,x;
    always #5 clk=~clk;
    brightness_scale dut(.clk(clk),.rst(rst),.level(level),.hs_in(h),.vs_in(v),.de_in(d),.rgb_in(rgb),
        .hs_out(ho),.vs_out(vo),.de_out(deo),.rgb_out(out));
    task check;
        integer gain;
        begin
            gain=(level>=1 && level<=10) ? level:10;
            expected[23:16]=(rgb[23:16]*gain+5)/10;
            expected[15:8]=(rgb[15:8]*gain+5)/10;
            expected[7:0]=(rgb[7:0]*gain+5)/10;
            @(posedge clk);@(posedge clk);#1;
            if(out!==expected || ho!==h || vo!==v || deo!==d) $fatal(1,"Brightness/alignment l=%d rgb=%h out=%h expected=%h",level,rgb,out,expected);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        for(l=0;l<=15;l=l+1) for(x=0;x<256;x=x+1) begin
            @(negedge clk);level=l;rgb={x[7:0],(8'd255-x[7:0]),x[7:0]};
            h=x[0];v=x[1];d=x[2];check;
        end
        $display("*** PASS *** RGB all 256 values, 10 levels, invalid input, sync alignment");$finish;
    end
endmodule
