`timescale 1ns/1ps
module tb_clock_overlay;
 parameter FIRST_CASE=0,LAST_CASE=10;
 reg clk=0,rst=1,hs=0,vs=0,de=0,editing=0,emergency=0;
 reg [2:0] sources=0;reg [8:0] groups=0;reg [23:0] rgb=24'h123456;
 wire vh,vv,vd,dh,dv,dd,eh,ev,ed,oh,ov,od;wire [23:0] volume_rgb,diagnostic_rgb,emergency_rgb,result;
 wire [6:0] vc,cc;wire [3:0] vx,vy,cx,cy;wire [1:0] a,b;wire request;
 integer x,y,scenario,checks=0,j,sx=0,sy=0,fp,pixels=0;reg id=0,iv=0,capture=0;
 reg [23:0] oracle[0:2];reg [2:0] hp=0,vp=0,dp=0;reg [1023:0] filename;
 always #5 clk=~clk;
 `include "aa_font_reference.vh"
 font_rom #(.SECOND_PORT(1)) font(.clk(clk),.char_code(7'd32),.gx(4'd0),.gy(4'd0),.alpha(a),
  .char_code_b(request ? cc:vc),.gx_b(request ? cx:vx),.gy_b(request ? cy:vy),.alpha_b(b));
 volume_overlay volume(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.pix_in(rgb),.show(!editing),.level(5'd9),
  .font_char(vc),.font_x(vx),.font_y(vy),.font_alpha(b),.hs_out(vh),.vs_out(vv),.de_out(vd),.pix_out(volume_rgb));
 error_overlay diagnostic(.video_clk(clk),.rst(rst),.hs(vh),.vs(vv),.de(vd),.pix_in(volume_rgb),
  .show(scenario>=9),.code(scenario==9 ? 4'd5:4'd14),.hs_out(dh),.vs_out(dv),.de_out(dd),.pix_out(diagnostic_rgb),.frame_black());
 emergency_overlay #(.FRAME_TIMESTAMPS(1)) alarm(.clk(clk),.rst(rst),.hs(dh),.vs(dv),.de(dd),.rgb_in(diagnostic_rgb),.enable(emergency),.sources(sources),.groups(groups),.timestamps({3{48'h261014123456}}),
  .hs_out(eh),.vs_out(ev),.de_out(ed),.rgb_out(emergency_rgb));
 clock_overlay dut(.clk(clk),.rst(rst),.hs(eh),.vs(ev),.de(ed),.rgb_in(emergency_rgb),
  .live_digits(48'h261014123456),.draft_digits(48'h000229235959),.focus(3'd2),.editing(editing),
  .font_request(request),.font_char(cc),.font_x(cx),.font_y(cy),.font_alpha(b),
  .hs_out(oh),.vs_out(ov),.de_out(od),.rgb_out(result));
 function [7:0] character;
  input integer col,row;reg [255:0] line;
  begin line="                                ";case(row)
   0:line=" CLOCK                          ";1:line=" YEAR           2000            ";
   2:line=" MONTH          02              ";3:line=" DAY            29              ";
   4:line=" HOUR           23              ";5:line=" MINUTE         59              ";
   6:line=" SECOND         59              ";7:line=" APPLY                          ";
   8:line="2/8 MOVE 4/6 -/+ 5 APPLY # BACK ";endcase
   character=line[(31-col)*8 +: 8];end
 endfunction
 function [23:0] clock_coverage;
  input [23:0] bg;input integer a;integer w;reg [7:0] r,g,b;
  begin w=a==0 ? 0:a==1 ? 1:a==2 ? 3:4;
   r=(255*w+bg[23:16]*(4-w))/4;g=(255*w+bg[15:8]*(4-w))/4;b=(255*w+bg[7:0]*(4-w))/4;
   clock_coverage={r,g,b};end
 endfunction
 function [23:0] golden;
  input integer px,py;input [23:0] base;
  reg [79:0] date;reg [63:0] times;reg [7:0] ch;reg [23:0] bg;
  integer dx,dy,col,row,cov;reg plate,card,border,text,high;
  begin date="2026-10-14";times="12:34:56";ch=32;dx=0;dy=0;high=0;text=0;
   plate=px>=8 && px<144 && py>=8 && py<60;card=editing && px>=446 && px<834 && py>=286 && py<434;
   border=(plate && (px==8 || px==143 || py==8 || py==59)) || (card && (px==446 || px==833 || py==286 || py==433));
   if(px>=16 && px<136 && py>=16 && py<32) begin text=1;dx=px-16;dy=py-16;col=dx/12;ch=date[(9-col)*8 +: 8];end
   else if(px>=16 && px<112 && py>=36 && py<52) begin text=1;dx=px-16;dy=py-36;col=dx/12;ch=times[(7-col)*8 +: 8];end
   else if(card && px>=448 && px<832 && py>=288 && py<432) begin text=1;dx=px-448;dy=py-288;col=dx/12;row=dy/16;high=row==3;ch=character(col,row);end
   golden=base;if(plate || card) begin
    golden={1'b0,base[23:17],1'b0,base[15:9],1'b0,base[7:1]};
    if(border) golden=24'h949494;
    else if(text) begin bg={1'b0,base[23:17],1'b0,base[15:9],1'b0,base[7:1]};
     if(high) bg={2'd0,base[23:18],2'd0,base[15:10],2'd0,base[7:2]}+24'h404040;
     cov=reference_alpha(ch,dx%12,dy%16);golden=clock_coverage(bg,cov);end
   end
  end
 endfunction
 always @(posedge clk) begin
  if(rst) begin sx=0;sy=0;id=0;iv=0;hp<=0;vp<=0;dp<=0;for(j=0;j<3;j=j+1) oracle[j]<=0;end
  else begin
   if(request && volume.text_a) $fatal(1,"Clock and volume font request collision");
   if(ev && !iv) sy=0;else if(!ed && id) sy=sy+1;if(!ed) sx=0;
   oracle[0]<=ed ? golden(sx,sy,emergency_rgb):emergency_rgb;oracle[1]<=oracle[0];oracle[2]<=oracle[1];
   hp<={hp[1:0],eh};vp<={vp[1:0],ev};dp<={dp[1:0],ed};if(ed) sx=sx+1;id=ed;iv=ev;
   #1;if(result!==oracle[2] || oh!==hp[2] || ov!==vp[2] || od!==dp[2])
    $fatal(1,"Clock pixel/sync mismatch case=%d x=%d y=%d got=%h want=%h",scenario,sx,sy,result,oracle[2]);
   checks=checks+1;
   if(capture && od) begin $fwrite(fp,"%c%c%c",result[23:16],result[15:8],result[7:0]);pixels=pixels+1;end
  end
 end
 initial begin
  repeat(4) @(negedge clk);rst=0;
  for(scenario=FIRST_CASE;scenario<=LAST_CASE;scenario=scenario+1) begin
   editing=scenario==8;emergency=scenario>=1 && scenario<=7;sources=scenario;groups={6'd0,sources};pixels=0;
   @(negedge clk);vs=1;repeat(12) @(negedge clk);vs=0;repeat(20) @(negedge clk);
   $sformat(filename,"clock_case_%0d.ppm",scenario);fp=$fopen(filename,"wb");if(!fp) $fatal(1,"Frame open");
   $fwrite(fp,"P6\n1280 720\n255\n");capture=1;
   for(y=0;y<720;y=y+1) begin
    for(x=0;x<1280;x=x+1) begin @(negedge clk);de=1;rgb={x[7:0],y[7:0],8'hA5};end
    @(negedge clk);de=0;repeat(16) @(negedge clk);
   end
   repeat(20) @(negedge clk);capture=0;$fclose(fp);if(pixels!=921600) $fatal(1,"Frame pixel count");
  end
  $display("*** PASS *** %d final-layer pixel/sync checks, %d full 720p frames (cases %d..%d), emergency/editor and shared volume font",checks,LAST_CASE-FIRST_CASE+1,FIRST_CASE,LAST_CASE);$finish;
 end
 initial begin #130000000;$fatal(1,"Overlay watchdog");end
endmodule
