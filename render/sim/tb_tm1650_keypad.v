`timescale 1ns/1ps
module tb_tm1650_keypad;
 reg clk=0;always #500 clk=~clk;
 reg rst=1,slave_low=0,missing=0,force_sda=0,force_scl=0;
 tri1 scl,sda;assign scl=force_scl ? 1'b0:1'bz;assign sda=(slave_low || force_sda) ? 1'b0:1'bz;
 wire down,online;wire [3:0] id;
 reg [7:0] code=8'h4d,address,value;integer i,j,init_count=0,poll_count=0;
 tm1650_keypad #(.CLK_HZ(1000000)) dut(.clk(clk),.rst(rst),.scl(scl),.sda(sda),.down(down),.key_id(id),.online(online));
 task receive;output [7:0] b;integer n;begin
  for(n=7;n>=0;n=n-1) begin @(posedge scl);b[n]=sda;end
  @(negedge scl);slave_low=!missing;
  @(posedge scl);#100;slave_low=0; // MCU example's early ACK release
  @(negedge scl);
 end endtask
 initial forever begin : slave_transaction
  @(negedge sda);
  if(scl===1'b1 && !force_sda) begin
   receive(address);
   if(!missing && address==8'h48) begin
    receive(value);if(value!==8'h19) $fatal(1,"initialisation byte");init_count=init_count+1;
   end else if(!missing && address==8'h49) begin
    value=code;
    for(j=7;j>=0;j=j-1) begin slave_low=!value[j];@(posedge scl);@(negedge scl);end
    slave_low=0;@(posedge scl);if(sda!==1) $fatal(1,"missing master NACK");@(negedge scl);
    poll_count=poll_count+1;
   end
   slave_low=0;
  end
 end
 initial begin
  #3000;rst=0;#130000000;
  if(!online || init_count!=1 || down) $fatal(1,"startup");
  code=0;#25000000;
  for(i=0;i<16;i=i+1) begin
   code=8'h44 | ((i/4)<<3) | (i%4);#25000000;
   if(!down || id!==i[3:0]) $fatal(1,"map key %d got %d down %b",i,id,down);
   code=0;#25000000;if(down) $fatal(1,"release");
  end
  code=8'h7c;#25000000;if(down) $fatal(1,"combo accepted");
  code=0;#25000000;
  missing=1;#25000000;if(online || down) $fatal(1,"NACK recovery");
  missing=0;#550000000;if(!online || init_count<2) $fatal(1,"reinit");
  force_sda=1;#25000000;if(online || down) $fatal(1,"SDA stuck recovery");
  force_sda=0;#550000000;if(!online || init_count<3) $fatal(1,"SDA recovery reinit");
  force_scl=1;#10000000;if(online || down) $fatal(1,"SCL timeout");
  force_scl=0;disable slave_transaction;#550000000;if(!online || init_count<4) $fatal(1,"SCL timeout reinit");
  $display("*** PASS *** TM1650 early ACK/init/held boot/16 keys/release/combo/NACK/SDA recovery/SCL timeout");$finish;
 end
 initial begin #3500000000;$fatal(1,"timeout");end
endmodule
