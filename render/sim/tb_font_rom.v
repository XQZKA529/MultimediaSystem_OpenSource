`timescale 1ns/1ps
`include "pkg/osd_model_bus.vh"
module tb_font_rom;
    reg clk=0,rst=1;reg [6:0] ch=32;reg [3:0] gx=0,gy=0;wire [1:0] alpha;
    reg [10:0] lx=0,ly=0;reg [`OSD_TXT_W-1:0] txt=0;
    wire draw;wire [2:0] ink;wire [1:0] audio_alpha;
    wire compact_draw;wire [2:0] compact_ink;wire [1:0] compact_alpha;
    integer c,x,y,i,checks=0,partials=0;reg [1:0] expected;
    always #5 clk=~clk;
    `include "aa_font_reference.vh"
    font_rom dut(.clk(clk),.char_code(ch),.gx(gx),.gy(gy),.alpha(alpha),.char_code_b(7'd32),.gx_b(4'd0),.gy_b(4'd0),.alpha_b());
    osd_paint_text painter(.clk(clk),.rst(rst),.lx(lx),.ly(ly),.txt(txt),
        .draw(draw),.ink(ink),.alpha(audio_alpha),.glass_blue_src(8'd0),.glass_blue_rgb());
    osd_paint_text #(.SCALE(1)) compact_painter(.clk(clk),.rst(rst),.lx(lx),.ly(ly),.txt(txt),
        .draw(compact_draw),.ink(compact_ink),.alpha(compact_alpha),.glass_blue_src(8'd0),.glass_blue_rgb());
    initial begin
        repeat(3) @(negedge clk);rst=0;
        for(c=0;c<128;c=c+1) for(y=0;y<16;y=y+1) for(x=0;x<16;x=x+1) begin
            @(negedge clk);ch=c;gx=x;gy=y;
            expected=reference_alpha(c,x,y);
            @(posedge clk);#1;
            if(alpha!==expected) $fatal(1,"Font pixel c=%0d x=%0d y=%0d got %0d expected %0d",c,x,y,alpha,expected);
            if(alpha==1 || alpha==2) partials=partials+1;
            checks=checks+1;
        end
        for(i=0;i<13;i=i+1) txt[i*8 +: 8]=(i<10) ? 48+i:(i==10) ? 58:(i==11) ? 47:32;
        for(y=0;y<18;y=y+1) for(x=0;x<160;x=x+1) begin
            @(negedge clk);lx=x;ly=y;
            expected=(x<156 && y<16) ? reference_alpha(txt[(x/12)*8 +: 8],x%12,y):0;
            @(posedge clk);#1;
            if(audio_alpha!==expected || draw!==(expected!=0)) $fatal(1,"Audio coverage x=%0d y=%0d",x,y);
            if(draw && ink!==((x/12==11) ? `OSD_INK_TEXTDIM:`OSD_INK_TEXT)) $fatal(1,"Audio dim slash");
            checks=checks+1;
        end
        // Compact card samples the same native AA ROM at twice the coordinate.
        // Exercise every character position, the slash and both bounds.
        for(y=0;y<10;y=y+1) for(x=0;x<82;x=x+1) begin
            @(negedge clk);lx=x;ly=y;
            expected=(x<78 && y<8) ? reference_alpha(txt[(x/6)*8 +: 8],(x%6)*2,y*2):0;
            @(posedge clk);#1;
            if(compact_alpha!==expected || compact_draw!==(expected!=0))
                $fatal(1,"Compact audio coverage x=%0d y=%0d got=%0d expected=%0d",x,y,compact_alpha,expected);
            if(compact_draw && compact_ink!==((x/6==11) ? `OSD_INK_TEXTDIM:`OSD_INK_TEXT))
                $fatal(1,"Compact audio dim slash");
            checks=checks+1;
        end
        if(partials<1000) $fatal(1,"No anti-alias edge coverage");
        $display("*** PASS *** native AA font/audio: %0d pixel checks, %0d edge samples; 95 ASCII, blank controls, gaps, sync latency, dim slash",checks,partials);
        $finish;
    end
    initial begin #1000000;$fatal(1,"Font timeout");end
endmodule
