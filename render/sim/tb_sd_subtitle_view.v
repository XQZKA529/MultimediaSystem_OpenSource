`timescale 1ns/1ps
module tb_sd_subtitle_view;
 reg clk=0,vclk=0,rst=1,vrst=1,sreset=0,start=0,dv=0,last=0,vs=0;
 reg [31:0] rev=0,data=0,image=7;reg image_valid=1,mix=0,ar=0;
 reg [7:0] addr=0;
 wire sr,dr,applied,selected,video_commit;wire [31:0] applied_rev;wire [1:0] result;wire [14:0] meta;wire [7:0] text;
 sd_subtitle_view dut(.clk(clk),.rst(rst),.session_reset(sreset),.start(start),.revision(rev),.start_ready(sr),
 .data_valid(dv),.data(data),.last(last),.data_ready(dr),.applied(applied),.applied_ready(ar),.applied_revision(applied_rev),.applied_result(result),
 .video_clk(vclk),.video_rst(vrst),.vs(vs),.display_image_id(image),.image_valid(image_valid),.mix_active(mix),
 .text_addr(addr),.text_data(text),.metadata(meta),.selected(selected),.video_commit(video_commit));
 always #5 clk=~clk;always #7 vclk=~vclk;
 task tick;input integer n;begin repeat(n) @(negedge clk);end endtask
 task frame;begin repeat(8) @(negedge vclk);vs=1;repeat(3) @(negedge vclk);vs=0;tick(12);end endtask
 task begin_packet;begin wait(sr);@(negedge clk);rev=rev+1;start=1;tick(1);start=0;end endtask
 task word;input [31:0] w;input final_word;
 begin wait(dr);@(negedge clk);data=w;last=final_word;dv=1;@(negedge clk);dv=0;last=0;end endtask
 task packet;input [31:0] f,b;input [31:0] chars;
 integer i;begin begin_packet;word(f,0);word(b,0);word(chars,0);for(i=3;i<66;i=i+1) word(0,i==65);tick(8);end endtask
 task maximum_packet;
 integer i,j;reg [31:0] w;begin
  begin_packet;word(32'd768,0);word(0,0);
  for(i=0;i<64;i=i+1) begin
   w=0;for(j=0;j<4;j=j+1) if(i*4+j<256) w[31-j*8 -:8]="A"+(i*4+j)%26;
   word(w,i==63);
  end
  tick(8);
 end endtask
 task retire;input [1:0] expected;
 begin wait(applied);if(result!==expected || applied_rev!=rev) $fatal(1,"result rev=%0d code=%0d expected=%0d",applied_rev,result,expected);
  @(negedge clk);ar=1;tick(1);ar=0;tick(2);
 end endtask
 task read_char;input [7:0] index;input [7:0] expected;
 begin @(negedge vclk);addr=index;repeat(2) @(negedge vclk);if(text!==expected) $fatal(1,"byte %0d got=%h expected=%h",index,text,expected);end endtask
 initial begin
  tick(4);rst=0;vrst=0;tick(8);
  packet(32'h203,0,{"A","b","!",8'd0});if(selected || meta!=0) $fatal(1,"published before VS");
  frame;retire(0);if(!selected || meta[8:0]!=3) $fatal(1,"metadata");read_char(0,"A");read_char(1,"b");read_char(2,"!");read_char(3,0);
  packet(32'h603,7,{"X","Y","Z",8'd0});frame;retire(0);read_char(0,"X");
  mix=1;#1;if(meta[14]) $fatal(1,"auto visible during fade");mix=0;#1;if(!meta[14]) $fatal(1,"failed fade did not restore");
  image=8;#1;if(meta[14] || !selected) $fatal(1,"old subtitle leaks into new image");
  packet(32'h603,7,{"B","A","D",8'd0});frame;retire(1);read_char(0,"X");
  packet(32'h603,8,{"N","E","W",8'd0});frame;retire(0);read_char(0,"N");
  // An independent pixel-domain reset republishes the last committed bank.
  vrst=1;tick(6);vrst=0;tick(10);frame;retire(0);read_char(0,"N");
  packet(32'h3ff,0,0);retire(2);read_char(0,"N");
  packet(32'h201,0,{8'hff,24'd0});retire(2);read_char(0,"N");
  packet(32'h201,0,{"A","B",16'd0});retire(2); // nonzero padding
  packet(32'h201,0,{"A",24'd0});frame;retire(0);if(meta[8:0]!=1) $fatal(1,"one-byte text length");read_char(0,"A");read_char(1,0);
  packet(32'h202,0,{"A","B",16'd0});frame;retire(0);if(meta[8:0]!=2) $fatal(1,"two-byte text length");read_char(1,"B");read_char(2,0);
  packet(32'h203,0,{"A","B","C",8'd0});frame;retire(0);if(meta[8:0]!=3) $fatal(1,"three-byte text length");read_char(2,"C");read_char(3,0);
  packet(32'h204,0,"ABCD");frame;retire(0);if(meta[8:0]!=4) $fatal(1,"four-byte text length");read_char(3,"D");read_char(4,0);
  begin_packet;word(32'h203,0);word(0,0);word({"B","A","D",8'd0},1);tick(8);retire(2);
  begin_packet;word(32'h203,0);word(0,0);sreset=1;tick(1);sreset=0;tick(4);if(!sr) $fatal(1,"partial packet not canceled");read_char(0,"A");
  // Invalidate a complete mailbox already crossing to video, before VS.
  packet(32'h203,0,{"O","L","D",8'd0});sreset=1;tick(1);sreset=0;
  tick(8);frame;retire(2);read_char(0,"A");
  maximum_packet;frame;retire(0);if(meta[8:0]!=256) $fatal(1,"maximum metadata");
  read_char(0,"A");read_char(255,"V");
  packet(32'h200,0,0);frame;retire(0);if(meta[8:0]!=0 || !selected) $fatal(1,"empty SD source did not suppress local text");
  packet(0,0,0);frame;retire(0);if(selected) $fatal(1,"display off");
  $display("*** PASS *** SD subtitle view: frame commit, bytes/padding, fade/binding, malformed/partial/empty/off");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
