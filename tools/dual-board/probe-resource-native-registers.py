"""Verify BRAM write-through register equivalence before using it in a design.

Checks enabled one-/two-stage registers, independent port enables, asynchronous
warm reset and stability between clock edges. A failed native mode is rejected.
"""
from pathlib import Path
import argparse
from resource_sim import simulate

ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--startup-cycles',type=int,default=50)
args=p.parse_args()
work=ROOT/'build/resource-v1/native-register-probe'
if args.startup_cycles!=50:work=work/f'startup_{args.startup_cycles}'
work.mkdir(parents=True,exist_ok=True)
for latency in (1,2):
    mode='NOREG' if latency==1 else 'OUTREG'
    rtl=work/f'register{latency}.v'
    s='''module native_registers(input wire clk,rst_a,rst_b,en_a,en_b,
input wire [31:0] din,output wire [31:0] q);
'''
    if latency==2:
        s+='''reg ready_a=0,ready_b=0;
always @(posedge clk or posedge rst_a) if(rst_a) ready_a<=0;else if(en_a) ready_a<=1;
always @(posedge clk or posedge rst_b) if(rst_b) ready_b<=0;else if(en_b) ready_b<=1;
wire reset_a=rst_a || !ready_a,reset_b=rst_b || !ready_b;
'''
    else:s+='wire reset_a=rst_a,reset_b=rst_b;\n'
    s+=f'''EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
.REGMODE_A("{mode}"),.REGMODE_B("{mode}"),.SRMODE("ASYNC"),
.WRITEMODE_A("WRITETHROUGH"),.WRITEMODE_B("WRITETHROUGH"),.INIT_00(256'd0)) u_ram(
.clka(clk),.addra(11'd0),.doa(q[15:0]),.dia(din[15:0]),.bytea(1'b0),.bytewea(1'b0),
.csa(en_a && !rst_a),.wea(1'b1),.rsta(reset_a),.ocea(en_a),
.clkb(clk),.addrb(11'd1024),.dob(q[31:16]),.dib(din[31:16]),.byteb(1'b0),.byteweb(1'b0),
.csb(en_b && !rst_b),.web(1'b1),.rstb(reset_b),.oceb(en_b));
endmodule
'''
    rtl.write_text(s,encoding='utf-8')
    tb=work/f'tb{latency}.v'
    tb.write_text('''module tb;
reg clk=0,rst_a=1,rst_b=1,en_a=0,en_b=0;always #5 clk=~clk;
reg [31:0] din=0;wire [31:0] q;
native_registers dut(.clk(clk),.rst_a(rst_a),.rst_b(rst_b),.en_a(en_a),.en_b(en_b),.din(din),.q(q));
reg [15:0] a1=0,a2=0,b1=0,b2=0;integer n,checks=0;
always @(posedge clk or posedge rst_a) if(rst_a) begin a1<=0;a2<=0;end
else if(en_a) begin a1<=din[15:0];a2<=a1;end
always @(posedge clk or posedge rst_b) if(rst_b) begin b1<=0;b2<=0;end
else if(en_b) begin b1<=din[31:16];b2<=b1;end
wire [31:0] expected='''+('{b1,a1}' if latency==1 else '{b2,a2}')+''';
always @(posedge clk or negedge clk) begin #1;
 if(q!==expected) $fatal(1,"Native register differs q=%h expected=%h t=%t",q,expected,$time);
 checks=checks+1;
end
initial begin
 repeat(STARTUP_CYCLES) @(negedge clk);rst_a=0;rst_b=0;
 for(n=0;n<10000;n=n+1) begin
  @(negedge clk);din=$random;en_a=$random;en_b=$random;
  if(n%71==50) begin rst_a=1;#2;rst_a=0;end
  if(n%113==70) begin rst_b=1;#2;rst_b=0;end
 end
 repeat(5) @(negedge clk);
 $display("PASS exact native enabled register, %0d edge/reset/stability checks",checks);$finish;
end endmodule
'''.replace('STARTUP_CYCLES',str(args.startup_cycles)),encoding='utf-8')
    try:simulate(work/mode,'tb',[rtl,tb],native=True)
    except RuntimeError as error:
        (work/mode/'probe-rejected.txt').write_text(str(error),encoding='utf-8')
        print(f'{mode}: rejected; see probe-rejected.txt')
