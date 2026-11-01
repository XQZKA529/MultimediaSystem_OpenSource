`timescale 1ns/1ps
module tb_volume_overlay;
    reg clk=0,rst=1,hs=0,vs=0,de=0,show=1;
    reg [4:0] level=20;reg [23:0] rgb=0;
    wire oh,ov,od;wire [23:0] out;
    wire [6:0] ch;wire [3:0] gx,gy;wire [1:0] alpha,alpha_a;
    reg [6:0] ch_a=65;reg [3:0] gx_a=0,gy_a=0;
    integer x,y,n,checks=0,coverage,c,percent;
    reg [23:0] want,previous=0;reg ph=0,pv=0,pd=0;
    reg trigger=0,suppress=0,hvs=0;wire hint_show;wire [4:0] hint_level;
    function [23:0] glass;
        input [23:0] s; integer r,g,b; reg [7:0] rr,gg,bb;
        begin r=s[23:16]+(s[23:16]>>1)+(8'h14>>1);g=s[15:8]+(s[15:8]>>1)+(8'h17>>1);b=s[7:0]+(s[7:0]>>1)+(8'h1b>>1);rr=r>>2;gg=g>>2;bb=b>>2;glass={rr,gg,bb}; end
    endfunction
    always #5 clk=~clk;
    `include "aa_font_reference.vh"
    font_rom #(.SECOND_PORT(1)) font(.clk(clk),.char_code(ch_a),.gx(gx_a),.gy(gy_a),.alpha(alpha_a),
        .char_code_b(ch),.gx_b(gx),.gy_b(gy),.alpha_b(alpha));
    volume_overlay #(.X0(20),.Y0(4)) dut(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.pix_in(rgb),
        .show(show),.level(level),.font_char(ch),.font_x(gx),.font_y(gy),.font_alpha(alpha),
        .hs_out(oh),.vs_out(ov),.de_out(od),.pix_out(out));
    volume_hint_controller #(.CLK_HZ(100)) timer(.clk(clk),.rst(rst),.vs(hvs),.trigger(trigger),
        .suppress(suppress),.level(level),.show(hint_show),.display_level(hint_level));
    function [23:0] pixel;
        input integer px,py;input enabled;input integer l;input [23:0] background;
        integer local_x,local_y,col,letter,a,p,t;reg [7:0] b1,b2,g1;
        begin
            pixel=background;
            if(enabled && px>=20 && px<380 && py>=4 && py<52) begin
                pixel=glass(background);
                if(px==20 || px==379 || py==4 || py==51) pixel=24'hd6dbe1;
                else if(px>=32 && px<164 && py>=9 && py<25) begin
                    local_x=px-32;local_y=py-9;col=local_x/12;p=l*5;t=p/10%10;
                    case(col)
                        0:letter=86;1:letter=79;2:letter=76;3:letter=85;4:letter=77;5:letter=69;6:letter=58;
                        7:letter=p==100 ? 49:32;8:letter=48+t;9:letter=48+p%10;10:letter=37;default:letter=32;
                    endcase
                    a=reference_alpha(letter,local_x%12,local_y);
                    pixel=reference_blend(24'hf5f7fa,24'h14171b,a);
                end else if(px>=32 && px<352 && py>=34 && py<44)
                    pixel=(px-32<l*16 && (px-32)%16<14) ? 24'hf5f7fa:24'h5a6068;
            end
        end
    endfunction
    task drive;
        input dh,dv,dd;input [23:0] drgb,dwant;
        begin
            @(negedge clk);hs=dh;vs=dv;de=dd;rgb=drgb;
            ch_a=(checks%95)+32;gx_a=checks%16;gy_a=(checks/16)%16;
            @(posedge clk);#1;
            if(out!==previous || oh!==ph || ov!==pv || od!==pd) $fatal(1,"Overlay pixel/phase x=%d y=%d level=%d got=%h expected=%h",x,y,level,out,previous);
            if(alpha_a!==reference_alpha(ch_a,gx_a,gy_a)) $fatal(1,"Concurrent font A read changed");
            previous=dwant;ph=dh;pv=dv;pd=dd;checks=checks+1;
        end
    endtask
    task hframe;begin @(negedge clk);hvs=1;@(negedge clk);hvs=0;end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(n=0;n<=21;n=n+1) begin
            level=n<=20 ? n:20;show=n<=20;
            drive(0,1,0,24'h123456,24'h123456);drive(0,0,0,24'h123456,24'h123456);
            for(y=0;y<56;y=y+1) begin
                for(x=0;x<384;x=x+1) begin
                    want=pixel(x,y,show,level,24'h123456);
                    drive(x[0],0,1,24'h123456,want);
                end
                drive(1,0,0,24'h234567,24'h234567);drive(0,0,0,24'h345678,24'h345678);
            end
        end
        @(negedge clk);trigger=1;@(negedge clk);trigger=0;hframe;
        if(!hint_show) $fatal(1,"Hint trigger");
        repeat(150) @(negedge clk);trigger=1;@(negedge clk);trigger=0;hframe;
        repeat(100) @(negedge clk);hframe;if(!hint_show) $fatal(1,"Hint renewal");
        repeat(101) @(negedge clk);hframe;if(hint_show) $fatal(1,"Hint two-second timeout");
        trigger=1;@(negedge clk);trigger=0;hframe;suppress=1;hframe;
        suppress=0;hframe;if(hint_show) $fatal(1,"Hint suppress cancellation");
        $display("*** PASS *** %d volume pixel/phase/dual-font checks, all 21 levels, 20 segments, bypass, hint renewal/timeout/suppress",checks);$finish;
    end
    initial begin #10000000;$fatal(1,"Overlay watchdog");end
endmodule
