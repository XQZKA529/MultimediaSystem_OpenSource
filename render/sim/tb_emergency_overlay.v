`timescale 1ns/1ps
module tb_emergency_overlay;
 reg clk=0,rst=1,hs=0,vs=0,de=0,en=0;reg [23:0] rgb=24'h5a9ce1;
 reg [143:0] timestamps={48'h990101000000,48'h000229235959,48'h261014153001};
 reg [2:0] sources=0;reg [8:0] groups=0;
 wire ho,vo,deo;wire [23:0] out;
 integer scenario,x,y,f,m,red_count,white_count,dy,dx,ty,lim,cy,lh,rh;
 reg arrow,warning,expected;reg [2:0] frozen_sources;reg [8:0] frozen_groups;
 reg [511:0] filename;reg [8:0] cases[0:24];
 reg [2:0] controls0=0,controls1=0;
 reg [23:0] reference=0,reference0=0,reference1=0;
 reg capture_frame=0;integer output_pixels=0;
 always #5 clk=~clk;
 emergency_overlay dut(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb_in(rgb),.enable(en),.sources(sources),.groups(groups),.timestamps(timestamps),
  .hs_out(ho),.vs_out(vo),.de_out(deo),.rgb_out(out));
 task clock;begin
  @(posedge clk);#1;
  if({ho,vo,deo}!==controls1) $fatal(1,"three-stage sync alignment");
  if(capture_frame && deo) begin
   if(reference1!==24'hffffff && out!==reference1) $fatal(1,"pipelined geometry mask=%d pixel=%d rgb=%h expected=%h",m,output_pixels,out,reference1);
   if(reference1===24'hffffff && out!=0 && out!=24'hffffff) $fatal(1,"text palette");
   if(out==24'hff0000) red_count=red_count+1;
   if(out==24'hffffff) white_count=white_count+1;
   $fwrite(f,"%c%c%c",out[23:16],out[15:8],out[7:0]);output_pixels=output_pixels+1;
  end
  controls1=controls0;controls0={hs,vs,de};reference1=reference0;reference0=reference;
  @(negedge clk);
 end endtask
 initial begin
  cases[0]=9'h001;
  cases[1]=9'h002;
  cases[2]=9'h003;
  cases[3]=9'h004;
  cases[4]=9'h005;
  cases[5]=9'h006;
  cases[6]=9'h007;
  cases[7]=9'h00a;
  cases[8]=9'h00c;
  cases[9]=9'h00e;
  cases[10]=9'h011;
  cases[11]=9'h014;
  cases[12]=9'h015;
  cases[13]=9'h01c;
  cases[14]=9'h021;
  cases[15]=9'h022;
  cases[16]=9'h023;
  cases[17]=9'h02a;
  cases[18]=9'h031;
  cases[19]=9'h054;
  cases[20]=9'h062;
  cases[21]=9'h08c;
  cases[22]=9'h0a1;
  cases[23]=9'h10a;
  cases[24]=9'h111;
  repeat(3) @(negedge clk);rst=0;clock;
  reference=rgb;de=1;repeat(16) clock;
  if(out!==rgb) $fatal(1,"normal bypass");
  de=0;clock;
  for(scenario=0;scenario<25;scenario=scenario+1) begin
   groups=cases[scenario];m=groups[2:0]|groups[5:3]|groups[8:6];sources=m;
   timestamps={48'h990101000000,48'h000229235959,48'h261014153001};en=1;vs=1;clock;vs=0;clock;
   timestamps={48'h990101000000,48'h000229235959,48'h261014153001};frozen_sources=sources;frozen_groups=groups;red_count=0;white_count=0;output_pixels=0;
   $sformat(filename,"emergency_%0d.ppm",scenario+1);f=$fopen(filename,"wb");$fwrite(f,"P6\n1280 720\n255\n");
   capture_frame=1;
   for(y=0;y<720;y=y+1) begin
    de=1;
    for(x=0;x<1280;x=x+1) begin
     cy=(m>=5) ? 440:360;dy=y>cy ? y-cy:cy-y;
     lh=(m>=5) ? 440:480;rh=(m>=5) ? 840:800;
     lim=(m>=5) ? 2*dy:dy+dy/2;
     arrow=((m&3)!=0) &&
      ((x>=((m&1)!=0 ? lh:240) && x<((m&2)!=0 ? rh:1040) && dy<((m>=5) ? 40:64)) ||
       ((m&1)!=0 && x>=240 && x<lh && dy<((m>=5) ? 100:160) && x-240>lim) ||
       ((m&2)!=0 && x>=rh && x<1040 && dy<((m>=5) ? 100:160) && 1040-x>lim));
     dx=x>640 ? x-640:640-x;ty=y-((m>=5) ? 100:160);
     lim=(m>=5) ? ty+ty/4:ty+ty/8+ty/16;
     warning=(m&4)!=0 && ty>=0 && ty<((m>=5) ? 200:340) &&
      ((lim>=2*dx && (lim-2*dx<12 || ty>=((m>=5) ? 192:332))) ||
       (dx<((m>=5) ? 8:12) && ((ty>=((m>=5) ? 45:70) && ty<((m>=5) ? 130:230)) ||
         (ty>=((m>=5) ? 154:270) && ty<((m>=5) ? 172:292)))));
     expected=arrow || warning;
     reference=((y>=580 && y<604) || (y>=612 && y<700)) ? 24'hffffff:(expected ? 24'hff0000:24'd0);
     clock;
     if(x==640 && y==300) begin en=0;timestamps=0;sources=7-m;groups=7-m;end
     if(dut.frame_sources!==frozen_sources || dut.frame_groups!==frozen_groups || dut.frame_timestamps!=={48'h990101000000,48'h000229235959,48'h261014153001} || !dut.active) $fatal(1,"mid-frame tear");
    end
    de=0;hs=1;clock;hs=0;clock;
   end
   if(output_pixels!=921600) $fatal(1,"full frame pixel count %d",output_pixels);
   capture_frame=0;$fclose(f);
   if(red_count<3000 || white_count<40) $fatal(1,"missing icon or sequence text");
   $display("mask=%0d red=%0d white=%0d",m,red_count,white_count);
   vs=1;clock;vs=0;clock;de=1;repeat(4) clock;if(out!==rgb) $fatal(1,"frame-latched exit");de=0;repeat(3) clock;
  end
  // Complete chronological layouts have centered 11/10-character sequences.

  $display("*** PASS *** 25 complete 720p alarm/time frames, geometry, white sequence text, frame atomics, RGB bypass and continuous sync");$finish;
 end
 initial begin #400000000;$fatal(1,"timeout");end
endmodule
