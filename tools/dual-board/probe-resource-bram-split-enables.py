"""Verify independent input/output enables on write-through BRAM pipeline regs."""
from pathlib import Path
from resource_sim import simulate
ROOT=Path(__file__).resolve().parents[2];w=ROOT/'build/resource-v1/bram-split-enable-probe';w.mkdir(parents=True,exist_ok=True)
rtl='''module split_registers(input wire clk,rst_a,rst_b,in_a,in_b,out_a,out_b,
 input wire [31:0] din,output wire [31:0] q);
reg ready_a,ready_b;
always @(posedge clk or posedge rst_a)if(rst_a)ready_a<=0;else if(in_a)ready_a<=1;
always @(posedge clk or posedge rst_b)if(rst_b)ready_b<=0;else if(in_b)ready_b<=1;
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
.REGMODE_A("OUTREG"),.REGMODE_B("OUTREG"),.SRMODE("ASYNC"),
.WRITEMODE_A("WRITETHROUGH"),.WRITEMODE_B("WRITETHROUGH"),.INIT_00(256'd0)) u_ram(
.clka(clk),.addra(11'd0),.doa(q[15:0]),.dia(din[15:0]),.bytea(1'b0),.bytewea(1'b0),
.csa(!rst_a),.wea(in_a),.rsta(rst_a || !ready_a),.ocea(out_a),
.clkb(clk),.addrb(11'd1024),.dob(q[31:16]),.dib(din[31:16]),.byteb(1'b0),.byteweb(1'b0),
.csb(!rst_b),.web(in_b),.rstb(rst_b || !ready_b),.oceb(out_b));
endmodule
''';(w/'registers.v').write_text(rtl,encoding='utf-8')
tb='''module tb;
reg clk=0,ra=1,rb=1,ia=0,ib=0,oa=0,ob=0;always #5 clk=~clk;
reg [31:0] din=0;wire [31:0] q;
split_registers dut(.clk(clk),.rst_a(ra),.rst_b(rb),.in_a(ia),.in_b(ib),.out_a(oa),.out_b(ob),.din(din),.q(q));
reg [15:0] a1=0,a2=0,b1=0,b2=0;integer i,checks=0;
always @(posedge clk or posedge ra)if(ra)begin a1<=0;a2<=0;end
else begin if(ia)a1<=din[15:0];if(oa)a2<=a1;end
always @(posedge clk or posedge rb)if(rb)begin b1<=0;b2<=0;end
else begin if(ib)b1<=din[31:16];if(ob)b2<=b1;end
always @(posedge clk or negedge clk)begin #1;
if(q!=={b2,a2})$fatal(1,"Split-enable registers differ t=%t q=%h expected=%h",$time,q,{b2,a2});
checks=checks+1;end
initial begin
repeat(4)@(negedge clk);ra=0;rb=0;
for(i=0;i<20000;i=i+1)begin
 @(negedge clk);din=$random;ia=$random;ib=$random;oa=$random;ob=$random;
 if(i%71==50)begin ra=1;#2;ra=0;end
 if(i%113==70)begin rb=1;#2;rb=0;end
end
repeat(5)@(negedge clk);
$display("PASS BRAM exact split input/output enables %0d checks, independent resets/ports/hold",checks);$finish;
end endmodule
''';(w/'tb.v').write_text(tb,encoding='utf-8')
simulate(w/'native','tb',[w/'registers.v',w/'tb.v'],native=True)
