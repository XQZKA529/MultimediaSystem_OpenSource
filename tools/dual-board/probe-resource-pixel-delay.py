"""Measure native same-port read-before-write semantics before an RTL change.

Two nonoverlapping halves of one BRAM32K would hold a complete pixel per
cycle, with both ports writing/returning old data. This probe rejects modes
that cannot preserve exact three-stage latency and short asynchronous reset.
"""
from pathlib import Path
from resource_sim import simulate

ROOT=Path(__file__).resolve().parents[2]
work=ROOT/'build/resource-v1/pixel-delay-probe';work.mkdir(parents=True,exist_ok=True)
template='''module pixel_delay(input wire clk,rst,input wire [31:0] din,output wire [31:0] q);
reg ready=0;always @(posedge clk or posedge rst) if(rst) ready<=0;else ready<=1;
wire output_reset=rst || !ready;
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
 .REGMODE_A("OUTREG"),.REGMODE_B("OUTREG"),.SRMODE("ASYNC"),
 .WRITEMODE_A("WRITE_MODE"),.WRITEMODE_B("WRITE_MODE"),.INIT_00(256'd0)) u_ram(
 .clka(clk),.addra(11'd0),.doa(q[15:0]),.dia(din[15:0]),.bytea(1'b0),.bytewea(1'b0),
 .csa(1'b1),.wea(!rst),.rsta(output_reset),.ocea(1'b1),
 .clkb(clk),.addrb(11'd1024),.dob(q[31:16]),.dib(din[31:16]),.byteb(1'b0),.byteweb(1'b0),
 .csb(1'b1),.web(!rst),.rstb(output_reset),.oceb(1'b1));
endmodule
'''
tb=work/'tb.v';tb.write_text('''module tb;
reg clk=0,rst=1;always #5 clk=~clk;reg [31:0] din=0;
wire [31:0] q;pixel_delay dut(.clk(clk),.rst(rst),.din(din),.q(q));
reg [31:0] a=0,b=0,c=0;integer n,errors=0,checks=0;
always @(posedge clk or posedge rst) if(rst) begin a<=0;b<=0;c<=0;end
else begin a<=din;b<=a;c<=b;end
always @(posedge clk) begin #1;if(!rst) begin
 checks=checks+1;if(q!==c) begin
  if(errors<8) $display("MISMATCH input=%h q=%h expected=%h t=%t",din,q,c,$time);
  errors=errors+1;
 end
end end
initial begin
 repeat(50) @(negedge clk);rst=0;
 for(n=0;n<1000;n=n+1) begin
  @(negedge clk);din=$random;
  if(n%71==50) begin rst=1;#2;rst=0;end
  if(n%113==70) begin rst=1;repeat(3) @(negedge clk);rst=0;end
 end
 repeat(5) @(negedge clk);
 if(errors) $fatal(1,"Pixel delay differs in %0d/%0d clocks",errors,checks);
 $display("PASS exact native pixel delay, %0d checks including warm reset",checks);$finish;
end endmodule
''',encoding='utf-8')
passed=[]
for mode in ('NORMAL','READBEFOREWRITE','WRITETHROUGH'):
    rtl=work/(mode+'.v');rtl.write_text(template.replace('WRITE_MODE',mode),encoding='utf-8')
    try:
        simulate(work/mode,'tb',[rtl,tb],native=True)
        passed.append(mode)
    except RuntimeError as error:
        (work/mode/'probe-rejected.txt').write_text(str(error),encoding='utf-8')
        print(f'{mode}: rejected; see probe-rejected.txt')
print('Exact native delay modes:',passed)
