`timescale 1ns/1ps
`include "pkg/text_osd_model.vh"
module tb_text_osd_scroll;
 reg clk=0,rst=1,hs=0,vs=0,de=0,active=0,page=0,diag=0,source=0,commit=0;
 reg [23:0] pixel=0;
 reg [`TEXT_OSD_META_W-1:0] view=0;
 wire [7:0] text_addr;wire hs_out,vs_out,de_out;wire [23:0] rgb_out;
 wire [6:0] font_char;wire [3:0] font_x,font_y;
 always #5 clk=~clk;
 text_osd_overlay #(.EXTERNAL_FONT(1)) dut(
  .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.pix_in(pixel),
  .ui_active_frame(active),.text_osd_page_frame(page),.diag_show(diag),
  .banner_source(source),.banner_reset(commit),.view(view),.text_addr(text_addr),.text_data(8'd65),
  .hs_out(hs_out),.vs_out(vs_out),.de_out(de_out),.pix_out(rgb_out),
  .font_char(font_char),.font_x(font_x),.font_y(font_y),.font_alpha(2'd0));
 task frame;
  begin @(negedge clk);de=0;vs=0;@(negedge clk);vs=1;@(negedge clk);vs=0;repeat(2) @(negedge clk);end
 endtask
 initial begin
  repeat(3) @(negedge clk);rst=0;view[`TEXT_OSD_VIEW_LEN]=75;view[`TEXT_OSD_VIEW_ENABLE]=1;
  commit=1;frame;commit=0; // initial content commit initializes at its first character
  if(dut.scroll_offset!=0) $fatal(1,"Scroll did not initialize at offset zero");
  repeat(61) frame;
  if(dut.scroll_offset!=0 || dut.scroll_hold!=61 || !dut.scroll_divider)
   $fatal(1,"Initial 61-frame hold failed");
  frame;if(dut.scroll_offset!=1 || dut.scroll_divider) $fatal(1,"First scroll step did not follow the hold");
  frame;if(dut.scroll_offset!=1 || !dut.scroll_divider) $fatal(1,"Second-frame divider phase failed");
  frame;if(dut.scroll_offset!=2 || dut.scroll_divider) $fatal(1,"Scroll speed is not one pixel per two frames");
  repeat(4) frame;
  if(dut.scroll_offset!=4 || dut.scroll_hold!=0) $fatal(1,"75-character endpoint is not four pixels");
  repeat(61) frame;
  if(dut.scroll_offset!=4 || dut.scroll_hold!=61) $fatal(1,"Tail hold was not 61 frames");
  frame;if(dut.scroll_offset!=0 || dut.scroll_hold!=0) $fatal(1,"Tail hold did not restart at the beginning");
  commit=1;@(negedge clk);commit=0;
  if(dut.scroll_offset!=0 || dut.scroll_hold!=0) $fatal(1,"A committed replacement did not reset scroll");
  source=1;repeat(2) @(negedge clk);
  if(dut.scroll_offset!=0 || dut.scroll_hold!=0) $fatal(1,"A source change did not reset scroll");
  active=1;repeat(2) @(negedge clk);active=0;repeat(2) @(negedge clk);frame;
  if(dut.scroll_offset!=0) $fatal(1,"Showing a hidden banner did not restart it");
  $display("*** PASS *** Text scroll: 896px viewport boundary, 61-frame head/tail holds, 1px/2-frame motion, content/source/visibility resets");$finish;
 end
 initial begin #1000000;$fatal(1,"scroll test timeout");end
endmodule
