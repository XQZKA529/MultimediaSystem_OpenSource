"""Native one-cycle BRAM9K write-through probe, with explicit readback mode."""
import argparse,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--readback',choices=['ON','OFF'],required=True)
p.add_argument('--native-write-address',action='store_true',help='Match low address write-enable pins in the native mapped 9-bit RAM')
a=p.parse_args()
b=a.candidate.resolve();w=b.parent/('bram9-hold-'+('native-writes-' if a.native_write_address else '')+'readback-'+a.readback.lower());w.mkdir(parents=True,exist_ok=True)
s=(b/'rtl/fat/fat32_ro.v').read_text(encoding='utf-8-sig')
s=s[s.index('\nmodule resource_fat_scratch_hold #('):]
s=s.replace('.GSR("DISABLE"),',f'.GSR("DISABLE"),.READBACK("{a.readback}"),')
if a.native_write_address:
 assert s.count(".addra(13'd0)")==1 and s.count(".addrb(13'd4096)")==1
 s=s.replace(".addra(13'd0)",".addra(13'd7)").replace(".addrb(13'd4096)",".addrb(13'd4103)")
rtl=w/'hold.v';rtl.write_text(s,encoding='utf-8')
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0,rst=1,en=0;always #5 clk=~clk;
reg [31:0] din=0,expected;reg defined=0;wire [31:0] q;
integer i,checks=0;
resource_fat_scratch_hold dut(.clk(clk),.rst(rst),.enable(en),.din(din),.q(q));
always @(posedge clk)if(!rst && en)begin expected<=din;defined<=1;end
always @(posedge clk or negedge clk)begin #1;
 if(defined && q!==expected)$fatal(1,"write-through/hold mismatch q=%h expected=%h",q,expected);
 checks=checks+1;
end
initial begin
repeat(5)@(negedge clk);#1;rst=0;
for(i=0;i<20000;i=i+1)begin
 @(negedge clk);#2;din=$random;en=$random;
 if(i%71==13)begin rst=1;#1;rst=0;end
end
repeat(5)@(negedge clk);
$display("PASS %0d native BRAM9K full-32-bit edge/reset/hold checks",checks);$finish;
end endmodule
''',encoding='utf-8')
simulate(w/'native','tb',[rtl,tb],native=True)
