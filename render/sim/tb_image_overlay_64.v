`timescale 1ns/1ps
module tb_image_overlay_64;
 reg clk=0,rst=1,wr_en=0,hs=0,vs=0,de=0,enable=1,prep=0,commit=0;
 reg [10:0] wr_addr=0;reg [31:0] wr_data=0;reg [23:0] rgb_in=24'h123456;
 wire prep_ack,commit_ack,hs_o,vs_o,de_o;wire [23:0] rgb_o;
 integer sy,pair,x,y,checks=0;
 image_overlay_64 dut(.wr_clk(clk),.wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),
  .video_clk(clk),.video_rst(rst),.hs_in(hs),.vs_in(vs),.de_in(de),.rgb_in(rgb_in),.enable_in(enable),
  .prepare_toggle(prep),.commit_toggle(commit),.prepare_ack(prep_ack),.commit_ack(commit_ack),
  .hs_out(hs_o),.vs_out(vs_o),.de_out(de_o),.rgb_out(rgb_o));
 always #5 clk=~clk;
 function [23:0] expand565;input [15:0] p;begin expand565={p[15:11],p[15:13],p[10:5],p[10:9],p[4:0],p[4:2]};end endfunction
 function [15:0] low_for_row;input integer r;reg [4:0] rr,bb;reg [5:0] gg;begin rr=r&31;gg=(r*3)&63;bb=(r+7)&31;low_for_row={rr,gg,bb};end endfunction
 function [15:0] high_for_row;input integer r;reg [4:0] rr,bb;reg [5:0] gg;begin rr=(r+9)&31;gg=(r*5)&63;bb=(r+13)&31;high_for_row={rr,gg,bb};end endfunction
 task pulse_vs;begin @(negedge clk);vs=1;@(posedge clk);#1;@(negedge clk);vs=0;@(posedge clk);#1;end endtask
 task check_pixel;input integer px,py;input [23:0] expected;begin
   if(rgb_o!==expected || de_o!==1'b1) begin $display("pixel (%0d,%0d) got %h/%b exp %h",px,py,rgb_o,de_o,expected);$fatal(1,"overlay pixel mismatch");end
   checks=checks+1;
 end endtask
 initial begin
   repeat(4) @(negedge clk);rst=0;
   for(sy=0;sy<64;sy=sy+1) for(pair=0;pair<32;pair=pair+1) begin
     @(negedge clk);wr_en=1;wr_addr=(63-sy)*32+pair;wr_data={high_for_row(63-sy),low_for_row(63-sy)};
     @(negedge clk);wr_en=0;
   end
   repeat(3) @(negedge clk);prep=1;repeat(4) @(negedge clk);pulse_vs();wait(prep_ack);
   commit=1;repeat(4) @(negedge clk);pulse_vs();wait(commit_ack);repeat(3) @(negedge clk);
   for(y=0;y<=80;y=y+1) begin
     for(x=0;x<1280;x=x+1) begin
       @(negedge clk);de=1;hs=(x>=656 && x<752);rgb_in=24'h123456;
       @(posedge clk);#1;
       if((y==16 && x==1199)||(y==16 && x==1264)||(y==15 && x==1200)||(y==80 && x==1200))
         check_pixel(x,y,24'h123456);
       if(y>=16 && y<80 && x>=1200 && x<1264)
         check_pixel(x,y,expand565(x[0] ? high_for_row(y-16):low_for_row(y-16)));
       if(hs_o!==hs || vs_o!==vs) $fatal(1,"sync latency mismatch at %0d,%0d",x,y);
     end
     @(negedge clk);de=0;@(posedge clk);#1;
   end
   if(checks!=4100) $fatal(1,"expected 4096 pixels + 4 boundary checks, got %0d",checks);
   // Hide must consume an outstanding commit instead of showing it one frame later.
   @(negedge clk);prep=~prep;commit=~commit;repeat(5) @(negedge clk);pulse_vs();
   pulse_vs();
   if(dut.enabled_frame!==1'b0) $fatal(1,"stale commit enabled a canceled image");
   $display("*** PASS *** tb_image_overlay_64: all 4096 pixels, bounds/sync, frame commit and canceled commit stays hidden");$finish;
 end
 initial begin #30000000;$fatal(1,"timeout");end
endmodule
