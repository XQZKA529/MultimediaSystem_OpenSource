`timescale 1ns/1ps
module tb_lba_bounds;
 reg clk=0,rst=1;always #5 clk=~clk;
 wire[7:0]map_rd_addr;reg[31:0]map_rd_lba=32'h1000,map_rd_nsec=32'h800000;
 reg[8:0]map_count=1;reg str_start=0,str_abort=0,str_ready=1;
 reg[31:0]str_file_off=0,str_len=0;wire[7:0]str_data;
 wire str_data_valid,str_done,str_ok,str_error,str_aborted,str_busy;wire[1:0]str_retry_used;
 wire blk_req;wire[31:0]blk_lba;wire[15:0]blk_count;
 reg blk_grant=0,blk_data_valid=0,blk_end=0,blk_error=0;reg[7:0]blk_data=0;
 lba_stream #(.MAX_BURST(2),.RETRY_WAIT(8))dut(.*);
 integer got=0,n,before_fault;reg tail_check=1;
 always @(posedge clk)if(str_data_valid)begin
  if(tail_check && str_data!==(8'hf0+got))fail("4GB span/last-sector byte");got=got+1;
 end
 task fail;input[511:0]why;begin $display("FAIL %0s",why);$finish;end endtask
 task start;input[31:0]off,len;begin @(negedge clk);str_file_off=off;str_len=len;str_start=1;@(negedge clk);str_start=0;end endtask
 initial begin
  #40;rst=0;start(32'hfffffff0,16);wait(blk_req);@(negedge clk);
  if(blk_lba!=32'h800fff||blk_count!=1)fail("4GB map address/length wrapped");
  blk_grant=1;@(negedge clk);blk_grant=0;
  for(n=0;n<512;n=n+1)begin blk_data_valid=1;blk_data=n;@(negedge clk);end
  blk_data_valid=0;blk_end=1;@(negedge clk);blk_end=0;wait(str_done);#20;
  if(!str_ok||str_error||got!=16)fail("last-sector completion");
  start(0,32'hffffffff);wait(blk_req);@(negedge clk);
  if(blk_count!=2)fail("maximum file ceil overflow");
  str_abort=1;blk_grant=1;@(negedge clk);blk_grant=0;str_abort=0;
  blk_end=1;@(negedge clk);blk_end=0;wait(str_done);#20;
  if(!str_aborted)fail("granted-burst abort");
  tail_check=0;got=0;
  start(0,1024);
  for(n=0;n<4;n=n+1)begin
   wait(blk_req);@(negedge clk);blk_error=1;@(negedge clk);blk_error=0;
  end
  wait(str_done);#20;
  if(!str_error||str_retry_used!=3||got!=0)fail("command retry limit/data leak");
  start(0,1024);wait(blk_req);@(negedge clk);blk_grant=1;@(negedge clk);blk_grant=0;
  for(n=0;n<8;n=n+1)begin blk_data_valid=1;blk_data=n;@(negedge clk);end
  blk_data_valid=0;blk_error=1;@(negedge clk);blk_error=0;
  wait(str_done);#20;before_fault=got;repeat(100)@(negedge clk);
  if(!str_error||str_retry_used!=0||got!=before_fault||blk_req)fail("failed partial burst replayed into WAV");
  $display("*** PASS *** LBA: 4GB map span / last sector / maximum file ceil / abort / safe command retries / partial-data failure");$finish;
 end
 initial begin #100000;fail("watchdog");end
endmodule
