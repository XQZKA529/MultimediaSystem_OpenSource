"""Check native one-stage write-through holds, including unreset scratch values.

NOREG does not reset its output. An explicit valid mask can provide reset for
resettable data; unreset scratch registers instead preserve their existing
unknown-at-power-up/hold-across-reset semantics with no mask or extra latency.
"""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--startup',type=int,default=3);a=p.parse_args()
root=Path(__file__).resolve().parents[2];w=root/'build/resource-v1/bram-one-stage-probe'/str(a.startup);w.mkdir(parents=True,exist_ok=True)
rtl=w/'register.v';rtl.write_text('''module native_hold(input wire clk,rst_a,rst_b,en_a,en_b,input wire [31:0] din,
 output wire [31:0] raw,masked);
reg va=0,vb=0;
always @(posedge clk or posedge rst_a)if(rst_a)va<=0;else if(en_a)va<=1;
always @(posedge clk or posedge rst_b)if(rst_b)vb<=0;else if(en_b)vb<=1;
assign masked={vb ? raw[31:16]:16'd0,va ? raw[15:0]:16'd0};
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("WRITETHROUGH"),.WRITEMODE_B("WRITETHROUGH"),
 .SRMODE("ASYNC"),.INIT_00(256'd0)) u_ram(
 .clka(clk),.addra(11'd0),.dia(din[15:0]),.doa(raw[15:0]),.bytea(1'b0),.bytewea(1'b0),
 .csa(en_a && !rst_a),.wea(1'b1),.rsta(1'b0),.ocea(en_a),
 .clkb(clk),.addrb(11'd1024),.dib(din[31:16]),.dob(raw[31:16]),.byteb(1'b0),.byteweb(1'b0),
 .csb(en_b && !rst_b),.web(1'b1),.rstb(1'b0),.oceb(en_b));
endmodule
''',encoding='utf-8')
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0,rst_a=1,rst_b=1,en_a=0,en_b=0;always #5 clk=~clk;
reg [31:0] din=0;wire [31:0] raw,masked;
native_hold dut(.clk(clk),.rst_a(rst_a),.rst_b(rst_b),.en_a(en_a),.en_b(en_b),.din(din),.raw(raw),.masked(masked));
reg [15:0] a,b;reg [15:0] ar=0,br=0;integer n,checks=0;
always @(posedge clk)begin if(!rst_a && en_a)a<=din[15:0];if(!rst_b && en_b)b<=din[31:16];end
always @(posedge clk or posedge rst_a)if(rst_a)ar<=0;else if(en_a)ar<=din[15:0];
always @(posedge clk or posedge rst_b)if(rst_b)br<=0;else if(en_b)br<=din[31:16];
always @(posedge clk or negedge clk)begin #1;
 if(raw!=={b,a})$fatal(1,"unreset one-stage differs raw=%h expected=%h t=%t",raw,{b,a},$time);
 if(masked!=={br,ar})$fatal(1,"masked one-stage differs raw=%h expected=%h t=%t",masked,{br,ar},$time);
 checks=checks+1;
end
initial begin
 repeat(STARTUP)@(negedge clk);rst_a=0;rst_b=0;
 for(n=0;n<20000;n=n+1)begin
  @(negedge clk);din=$random;en_a=$random;en_b=$random;
  if(n%71==50)begin rst_a=1;#2;rst_a=0;end
  if(n%113==70)begin rst_b=1;#2;rst_b=0;end
 end
 repeat(5)@(negedge clk);
 $display("PASS native NOREG one-stage raw/unreset and reset-masked holds: %d edge/reset/stability checks",checks);$finish;
end endmodule
'''.replace('STARTUP',str(a.startup)),encoding='utf-8')
simulate(w/'native','tb',[rtl,tb],native=True)
