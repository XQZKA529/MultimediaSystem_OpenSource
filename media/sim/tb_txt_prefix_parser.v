`timescale 1ns/1ps
module tb_txt_prefix_parser;
 reg clk=0,rst=1,start=0,bv=0,finish=0,read_ok=1;
 reg [7:0] byte_data;reg [31:0] size;
 wire cv,done,ok,truncated,first_line;wire [7:0] ci;wire [8:0] len;wire [7:0] cd;
 reg [7:0] got[0:255];integer checks=0,i;
 txt_prefix_parser dut(.clk(clk),.rst(rst),.start(start),.byte_valid(bv),.byte_data(byte_data),
 .finish(finish),.read_ok(read_ok),.file_size(size),.char_valid(cv),.char_index(ci),.char_data(cd),
 .done(done),.ok(ok),.length(len),.truncated(truncated),.first_line(first_line));
 always #5 clk=~clk;
 always @(posedge clk) if(cv) got[ci]=cd;
 task begin_file;input integer n;begin @(negedge clk);size=n;start=1;read_ok=1;@(negedge clk);start=0;end endtask
 task byte_in;input [7:0] c;begin @(negedge clk);bv=1;byte_data=c;@(negedge clk);bv=0;end endtask
 task end_file;input expected_ok;input integer expected_len;input expected_trunc;
 begin @(negedge clk);finish=1;@(negedge clk);finish=0;
  if(!done || ok!==expected_ok || len!=expected_len || truncated!==expected_trunc)
   $fatal(1,"Parser case %0d ok=%b len=%0d trunc=%b",checks,ok,len,truncated);
  checks=checks+1;
 end endtask
 initial begin
  repeat(3) @(negedge clk);rst=0;
  begin_file(0);end_file(1,0,0);
  begin_file(3);byte_in("A");byte_in("b");byte_in("9");end_file(1,3,0);if(got[1]!="b") $fatal(1,"case lost");
  begin_file(6);byte_in(8'hef);byte_in(8'hbb);byte_in(8'hbf);byte_in("X");byte_in(9);byte_in("!");end_file(1,3,0);if(got[1]!=32) $fatal(1,"TAB");
  begin_file(3);byte_in(8'hef);byte_in(8'hbb);byte_in(8'hbf);end_file(1,0,0);
  begin_file(109);byte_in(8'hef);byte_in(8'hbb);byte_in(8'hbf);
  for(i=0;i<106;i=i+1) byte_in("z");end_file(1,106,0);
  begin_file(110);byte_in(8'hef);byte_in(8'hbb);byte_in(8'hbf);
  for(i=0;i<107;i=i+1) byte_in("z");end_file(1,107,0);
  begin_file(4);byte_in("A");byte_in(13);byte_in(10);byte_in("B");end_file(1,1,0);if(!first_line) $fatal(1,"first-line flag");
  begin_file(2);byte_in(10);byte_in(8'hff);end_file(0,0,0);
  begin_file(2);byte_in(10);byte_in("A");end_file(1,0,0);
  begin_file(2);byte_in("A");byte_in(10);end_file(1,1,0);
  begin_file(106);for(i=0;i<106;i=i+1) byte_in(32+i%95);end_file(1,106,0);
  begin_file(256);for(i=0;i<256;i=i+1) byte_in("a");end_file(1,256,0);if(got[255]!="a") $fatal(1,"byte 255 lost");
  begin_file(257);for(i=0;i<257;i=i+1) byte_in("b");end_file(1,256,1);
  begin_file(260);byte_in(8'hef);byte_in(8'hbb);byte_in(8'hbf);
  for(i=0;i<257;i=i+1) byte_in("x");end_file(1,256,1);
  begin_file(1000000);for(i=0;i<260;i=i+1) byte_in("x");end_file(1,256,1);
  begin_file(2);byte_in("A");byte_in(0);end_file(0,1,0);
  begin_file(2);byte_in("A");byte_in(1);end_file(0,1,0);
  begin_file(3);byte_in(8'he4);byte_in(8'hb8);byte_in(8'had);end_file(0,0,0);
  begin_file(2);byte_in(8'hff);byte_in(8'hfe);end_file(0,0,0);
  begin_file(1);byte_in(8'hef);end_file(0,0,0);
  begin_file(2);byte_in(8'hef);byte_in(8'hbb);end_file(0,0,0);
  begin_file(3);byte_in(8'hef);byte_in(8'hbb);byte_in("A");end_file(0,0,0);
  begin_file(1);byte_in("A");read_ok=0;end_file(0,1,0);
  $display("*** PASS *** TXT prefix: %0d cases, BOM/ASCII/TAB/line/106/107/large/format/read failures",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
