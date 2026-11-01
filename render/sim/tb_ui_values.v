`timescale 1ns/1ps
module tb_ui_values;
 reg clk=0,rst=1,vs=0,commit=0;reg [10:0] x=0;
 wire [6:0] code;wire [3:0] fx,fy;wire seen;integer i;
 always #5 clk=~clk;
 ui_text_overlay #(.EXTERNAL_FONT(1)) dut(.video_clk(clk),.rst(rst),.hs(1'b0),.vs(vs),.de(1'b1),.pix_in(24'd0),.pix_out(),.hs_out(),.vs_out(),.de_out(),
  .brightness_level(4'd10),.brightness_frame(),.contrast_level(5'd20),.saturation_level(5'd0),.volume_level(5'd20),.osd_enabled(1'b1),
  .text_osd_page(1'b0),.ui_page(4'd1),.ui_active_frame(),.text_osd_page_frame(),.ui_page_frame(),.ui_active(1'b1),.ui_commit_toggle(commit),
  .cursor_row(4'd2),.cursor_en(1'b1),.wr_clk(clk),.wr_en(1'b0),.wr_addr(9'd0),.wr_data(8'd0),.dbg_commit_seen(seen),.font_char(code),.font_x(fx),.font_y(fy),.font_alpha(2'd0));
 task probe;input [10:0] px;input [7:0] want;begin
  x=px;force dut.x_cnt=x;force dut.y_cnt=11'd450;repeat(16) @(negedge clk);
  if(code!==want) $fatal(1,"value char at %0d got %c expected %c",px,code,want);
  release dut.x_cnt;release dut.y_cnt;
 end endtask
 initial begin repeat(4) @(negedge clk);rst=0;commit=1;repeat(4) @(negedge clk);vs=1;repeat(4) @(negedge clk);vs=0;repeat(8) @(negedge clk);
  if(!seen) $fatal(1,"missing commit");
  for(i=0;i<112;i=i+1) begin
   if(dut.compact_label_x(i[6:0])!==((4*i)/3)) $fatal(1,"Card label coordinate %0d",i);
  end
  probe(310,"2");probe(322,"0");probe(334,"0");
  probe(432," ");probe(444," ");probe(456,"0");
  $display("*** PASS *** all 112 compact label coordinates; distinct saturation and contrast digits");$finish;
 end
endmodule
