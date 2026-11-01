"""Verify every bit/address of packed native cache, including partial refills."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--tag',default='cache32-word-equivalence');a=p.parse_args()
b=a.candidate.resolve();w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0;always #5 clk=~clk;
// The cache has no defined contents before refill. Start with writes, exactly
// as the real cache protocol does, rather than comparing uninitialized words.
reg we=1;reg [6:0] wa=0,ra=0;reg [31:0] din=0;
wire [31:0] q;reg [31:0] expected[0:127],read_expected;
integer i,j,checks=0;reg check_read=0;
resource_fat_cache32 dut(.clk(clk),.write(we),.write_address(wa),.read_address(ra),.din(din),.q(q));
always @(posedge clk)begin
 check_read<=!we;
 if(we)expected[wa]<=din;else read_expected<=expected[ra];
 #1;if(check_read)begin
  if(q!==read_expected)$fatal(1,"full32 cache word mismatch address %0d q=%h expected=%h",ra,q,read_expected);
  checks=checks+1;
 end
end
initial begin
for(i=0;i<128;i=i+1)begin @(negedge clk);we=1;wa=i;din=$random;end
@(negedge clk);we=0;
for(i=0;i<128;i=i+1)begin @(negedge clk);ra=i;end
for(i=0;i<100000;i=i+1)begin
 @(negedge clk);we=$random;wa=$random;ra=$random;din=$random;
 if(i%997==0)din=32'hffffffff;
 if(i%991==0)din=32'h80000000;
end
@(negedge clk);we=0;
for(i=0;i<128;i=i+1)begin @(negedge clk);ra=i;end
@(negedge clk);
$display("PASS %0d full-32-bit cache reads: all 128 addresses, random/partial refills, top four stored bits and signed boundaries",checks);$finish;
end endmodule
''',encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[b/'rtl/fat/fat32_ro.v',tb],
    includes=[b/'rtl',b/'rtl/pkg',b/'rtl/fat'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
