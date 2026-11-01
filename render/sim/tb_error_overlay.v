`timescale 1ns/1ps
module tb_error_overlay;
    reg clk=0,rst=1,hs=0,vs=0,de=0,show=1;reg [23:0] base=0;
    reg [3:0] code=0;wire [23:0] pixel;wire ho,vo,dout,black;
    integer rx=0,ry=0,checks=0,edges=0,x,y,c;reg pd=0,pv=0;
    reg [1:0] diagnostic_atlas[0:29924];reg [4095:0] path;
    reg [23:0] expected;reg eh,ev,ed;
    reg [23:0] first_expected=0,first_base=0,original;reg first_h=0,first_v=0,first_d=0;
    always #5 clk=~clk;
    `include "aa_font_reference.vh"
    initial begin
        if(!$value$plusargs("AA_DIAG=%s",path)) $fatal(1,"Missing diagnostic reference");
        $readmemh(path,diagnostic_atlas);
    end
    error_overlay #(.TEXT_X(9),.TEXT_Y(6)) dut(.video_clk(clk),.rst(rst),
        .hs(hs),.vs(vs),.de(de),.pix_in(base),.code(code),.show(show),
        .hs_out(ho),.vs_out(vo),.de_out(dout),.pix_out(pixel),.frame_black(black));
    function [23:0] golden;
        input integer sx,sy;input [23:0] original;
        integer col,gx,gy;reg [71:0] message;reg [7:0] letter;reg [1:0] a;
        begin
            golden=original;
            if(show && sx>=0 && sx<=176 && sy>=0 && sy<=32) golden=24'h14171b;
            if(show && sx>=9 && sx<168 && sy>=6 && sy<27) begin
                col=(sx-9)/18;gx=(sx-9)%18;gy=sy-6;
                if(code==13) message="WAIT DATA";
                else if(code==14) message="LINK DOWN";
                else begin message="ERROR    ";message[23:16]=code<=9 ? 48+code:32;end
                letter=message[(8-col)*8 +: 8];a=0;
                if(gx<15 && letter>=32 && letter<=126) a=diagnostic_atlas[(letter-32)*315+gy*15+gx];
                golden=reference_blend(24'hf5f7fa,24'h14171b,a);
            end
        end
    endfunction
    always @(posedge clk) begin
        if(rst) begin rx=0;ry=0;pd=0;pv=0;first_expected=0;first_base=0;first_h=0;first_v=0;first_d=0;end
        else begin
            expected=first_expected;eh=first_h;ev=first_v;ed=first_d;
            original=first_base;first_base=base;
            first_expected=golden(rx,ry,base);first_h=hs;first_v=vs;first_d=de;
            // Preserve diagnostic coordinate convention, including its existing
            // one-pixel scanline offset; synchronize every RGB/control sample.
            if(vs && !pv) ry=0;else if(!de && pd) ry=ry+1;
            if(de && !pd) rx=0;else if(de) rx=rx+1;
            pd=de;pv=vs;
            #1;
            if(ho!==eh || vo!==ev || dout!==ed || (ed && pixel!==expected))
                $fatal(1,"Diagnostic pixel/sync c=%0d at (%0d,%0d) got %h expected %h",code,rx,ry,pixel,expected);
            if(ed) begin
                checks=checks+1;
                if(pixel!=24'hf5f7fa && pixel!=24'h14171b && pixel!=original) edges=edges+1;
            end
        end
    end
    task frame;input [3:0] value;
        begin
            @(negedge clk);code=value;vs=1;de=0;repeat(4) @(negedge clk);vs=0;
            repeat(4) @(negedge clk);
            for(y=0;y<36;y=y+1) begin
                for(x=0;x<192;x=x+1) begin
                    @(negedge clk);de=1;hs=0;base={x[7:0],y[7:0],8'ha5};
                end
                @(negedge clk);de=0;hs=1;repeat(4) @(negedge clk);
            end
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(c=0;c<10;c=c+1) frame(c);
        frame(13);frame(14);frame(12);show=0;frame(14);
        if(edges<1000 || checks<90000) $fatal(1,"Insufficient diagnostic AA coverage");
        $display("*** PASS *** AA diagnostics: %0d pixels, %0d edge samples, ERROR 0..9, WAIT DATA, LINK DOWN, invalid digit, bypass, two-stage sync",checks,edges);
        $finish;
    end
    initial begin #3000000;$fatal(1,"Diagnostic timeout");end
endmodule
