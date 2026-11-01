`timescale 1ns/1ps
module tb_saturation_adjust;
 reg clk=0,rst=1,valid=0,enable=1,hs=0,vs=0,de=0;
 reg [4:0] level=10;reg [23:0] rgb=0;
 wire ho,vo,do_;wire [23:0] out;
 integer n,i,j,y,r,g,b,v,seed=32'h1845a731;
 reg [23:0] pixel;reg [23:0] expected[0:3];reg [2:0] timing[0:3];
 always #5 clk=~clk;
 saturation_adjust dut(.clk(clk),.rst(rst),.cfg_valid(valid),.cfg_level(level),.enable(enable),.hs_in(hs),.vs_in(vs),.de_in(de),.rgb_in(rgb),.hs_out(ho),.vs_out(vo),.de_out(do_),.rgb_out(out));
 function [7:0] model_channel;
  input integer c,lum,gain;integer value;
  begin value=(10*lum+gain*(c-lum)+5);if(value<0)value=0;else if(value>2550)value=2550;model_channel=value/10;end
 endfunction
 function [23:0] model;
  input [23:0] c;input integer gain;integer lum;
  begin lum=(77*c[23:16]+150*c[15:8]+29*c[7:0]+128)>>8;
   model={model_channel(c[23:16],lum,gain),model_channel(c[15:8],lum,gain),model_channel(c[7:0],lum,gain)};end
 endfunction
 task tick;
  input [23:0] pixel;input integer gain;
  begin
   @(negedge clk);rgb=pixel;hs=$random(seed);de=$random(seed);
   @(posedge clk);#1;
   if(out!==expected[2] || {ho,vo,do_}!==timing[2]) $fatal(1,"mismatch got=%h expected=%h gain=%0d",out,expected[2],gain);
   for(j=3;j>0;j=j-1)begin expected[j]=expected[j-1];timing[j]=timing[j-1];end
   expected[0]=model(pixel,gain);timing[0]={hs,vs,de};
  end
 endtask
 integer channel_value,luma_value,gain_value,want_product;
 initial begin
  // Exhaust every input to the signed channel-gain kernel independently of
  // luma conversion: 256 channels x 256 lumas x 21 gains.
  for(gain_value=0;gain_value<=20;gain_value=gain_value+1)
   for(channel_value=0;channel_value<256;channel_value=channel_value+1)
    for(luma_value=0;luma_value<256;luma_value=luma_value+1) begin
     want_product=(channel_value-luma_value)*gain_value;
     if($signed(dut.chroma_product(channel_value[7:0],luma_value[7:0],gain_value[4:0]))!==want_product)
      $fatal(1,"signed product channel=%0d luma=%0d gain=%0d",channel_value,luma_value,gain_value);
    end
  repeat(3) @(negedge clk);rst=0;
  for(n=0;n<=23;n=n+1)begin
   // reset provides a clean latency pipeline; commit requested level in blanking.
   @(negedge clk);rst=1;rgb=0;hs=0;vs=0;de=0;repeat(2) @(negedge clk);rst=0;level=(n==22 ? 20:n==23 ? 31:n);enable=(n!=22);valid=1;@(negedge clk);valid=0;vs=1;@(negedge clk);vs=0;repeat(5) @(negedge clk);
   for(j=0;j<4;j=j+1)begin expected[j]=0;timing[j]=0;end
   for(i=0;i<1200;i=i+1)begin
    case(i) 0:pixel=24'hff0000;1:pixel=24'h00ff00;2:pixel=24'h0000ff;3:pixel=24'hffffff;4:pixel=24'h000000;default:pixel=(i>=5 && i<261) ? {i[7:0],i[7:0],i[7:0]}:$random(seed);endcase
    tick(pixel,n<=20?n:10);
   end
  end
  // A mid-frame request is invisible until the next VS trailing edge.
  @(negedge clk);rst=1;enable=1;rgb=24'hd04020;hs=0;vs=0;de=1;repeat(2) @(negedge clk);rst=0;
  repeat(6) @(negedge clk);level=0;valid=1;@(negedge clk);valid=0;repeat(6) @(negedge clk);
  if(out!==24'hd04020) $fatal(1,"mid-frame config changed output");
  vs=1;repeat(2) @(negedge clk);vs=0;repeat(6) @(negedge clk);
  if(out!==model(24'hd04020,0)) $fatal(1,"new frame did not apply saturation");
  level=20;valid=1;@(negedge clk);valid=0;repeat(6) @(negedge clk);
  if(out!==model(24'hd04020,0)) $fatal(1,"second mid-frame config changed output");
  vs=1;repeat(2) @(negedge clk);vs=0;repeat(6) @(negedge clk);
  if(out!==model(24'hd04020,20)) $fatal(1,"new frame did not apply enhancement");
  $display("*** PASS *** saturation: 1376256 exact signed products, 21 levels, all 256 grays, invalid 21/31 fallback, bypass, random RGB and sync");$finish;
 end
endmodule
