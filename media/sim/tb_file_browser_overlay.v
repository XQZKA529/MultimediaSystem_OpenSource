`timescale 1ns/1ps
`include "pkg/fat_dir_bus.vh"
module tb_file_browser_overlay;
 reg clk=0,rst=1,open=0,confirm=0,up=0;reg [`VDIR_DBUS_W-1:0] dir=0;
 wire req,start,active,commit,load;wire [3:0] state;wire [31:0] cluster,size;wire [6:0] entry_count;wire [5:0] cursor;
 wire [4:0] contrast;wire [3:0] brightness;wire [1:0] brightness_mode,transition_mode;
 wire [8:0] wr_addr;wire [7:0] wr_data;wire wr_en;
 reg [6:0] text[0:287];integer i;
 always @(posedge clk) if(wr_en) text[wr_addr]<=wr_data[6:0];
 file_browser #(.CLK_FREQ_HZ(1000),.DEBOUNCE_MS(2),.HOLD_MS(1000)) dut(
  .clk(clk),.rst(rst),
  .action_open(open),.action_back(1'b0),.action_up(up),.action_down(1'b0),.action_left(1'b0),.action_right(1'b0),.action_confirm(confirm),
  .key_open(1'b1),.key_sel(1'b1),.key_ok(1'b1),.force_close(1'b0),.input_block(1'b0),
  .volume_level(5'd20),.contrast_level(contrast),.brightness_mode(brightness_mode),.brightness_level(brightness),.transition_mode(transition_mode),
  .subtitle_display(1'b0),.subtitle_auto(1'b0),.subtitle_status(4'd0),.subtitle_display_toggle(),.subtitle_auto_toggle(),.subtitle_clear(),
  .text_osd_page(),.ui_navigable(),.img_idle(1'b1),.img_ready(1'b1),.fat_busy(1'b0),
  .dir_req(req),.dir_gnt(req),.dir_start(start),.dir_dat(dir),.ui_active(active),.ui_commit_toggle(commit),
  .cursor_row(),.cursor_en(),.ui_wr_en(wr_en),.ui_wr_addr(wr_addr),.ui_wr_data(wr_data),
  .ext_load_req(load),.ext_load_cluster(cluster),.ext_load_size(size),.ext_load_ack(1'b0),.ext_load_rejected(1'b0),
  .ext_play_req(),.ext_play_ack(1'b0),.ext_play_rejected(1'b0),.auto_toggle_pulse(),
  .dbg_browser_state(state),.dbg_entry_count(entry_count),.dbg_cursor(cursor));
 always #5 clk=~clk;
 task tick;input integer n;begin repeat(n) @(negedge clk);end endtask
 task send_entry;input [255:0] nm;input integer len;input [31:0] cl;input is_dir;
 integer j;begin
  dir=0;dir[`VDIR_D_ESTART]=1;dir[`VDIR_D_FCLUST]=cl;dir[`VDIR_D_SIZE]=32'd12342;tick(1);dir=0;
  for(j=0;j<len;j=j+1) begin dir[`VDIR_D_NVLD]=1;dir[`VDIR_D_CHAR]=nm[(len-j)*8-1 -:8];dir[`VDIR_D_INDEX]=j;tick(1);dir=0;end
  dir[`VDIR_D_EEND]=1;dir[`VDIR_D_ISDIR]=is_dir;
  dir[`VDIR_D_FCLUST]=cl;dir[`VDIR_D_SIZE]=32'd12342;tick(1);dir=0;tick(2);
 end endtask
 task enumerate;
 begin
  send_entry("System Volume Information",25,32'd99,1);
  send_entry("overlay.bmp",11,32'd98,0);
  for(i=0;i<9;i=i+1) begin
   send_entry({"IMAGE",(8'h30+i[7:0]),".BMP"},10,32'd7+i,0);
   send_entry("UNUSABLE",8,32'd80+i,1);
  end
  dir=0;dir[`VDIR_D_DONE]=1;dir[`VDIR_D_OK]=1;tick(1);dir=0;wait(state==6);tick(5);
 end endtask
 initial begin
  tick(4);rst=0;@(negedge clk);open=1;tick(1);open=0;wait(state==12);@(negedge clk);confirm=1;tick(1);confirm=0;wait(state==4);wait(start);
  enumerate;
  if(entry_count!=9) $fatal(1,"Directories/reserved BMP leaked into browser count=%0d",entry_count);
  if({text[0],text[1],text[2],text[3],text[4],text[5],text[6],text[7],text[8],text[9]}!={7'd73,7'd77,7'd65,7'd71,7'd69,7'd48,7'd46,7'd66,7'd77,7'd80})
   $fatal(1,"First row must contain first file IMAGE0.BMP");
  // Up from the first file wraps to file 8 on the next page and rescans.
  up=1;tick(1);up=0;wait(state==4);wait(start);enumerate;
  if(entry_count!=9 || cursor!=8 || text[0]!="I" || text[5]!="8") $fatal(1,"Filtered pagination");
  for(i=32;i<256;i=i+1) if(text[i]!==7'd32) $fatal(1,"Filtered last-page blank row at %0d",i);
  confirm=1;tick(1);confirm=0;wait(load);tick(1);
  if(cluster!=15 || size!=12342) $fatal(1,"Filtered file selection descriptor");
  $display("*** PASS *** tb_file_browser_overlay: directories/reserved BMP hidden; first file, count, page wrap, blank rows and selection verified");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
