"""Exhaust both original LFN lookup results, including malformed ordinals."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True);a=p.parse_args();b=a.candidate.resolve()
w=b.parent/'lfn-rom-equivalence';w.mkdir(parents=True,exist_ok=True)
fun=(b.parent/'lfn-rom-generation/original_base.v').read_text(encoding='utf-8')
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0;always #5 clk=~clk;reg [4:0] ordinal=0;
wire [7:0] base,length;
resource_fat_lfn_table dut(.clk(clk),.a({5'd0,ordinal}),.b({4'd0,1'b1,ordinal}),.qa(base),.qb(length));
'''+fun+'''
integer n;reg [7:0] expected_base,expected_length;
initial begin @(negedge clk);
for(n=0;n<32;n=n+1)begin
 ordinal=n;expected_base=lfn_ordinal_base(ordinal);expected_length=n==20 ? 8'd255:n*13;
 @(posedge clk);#1;
 if(base!==expected_base || length!==expected_length)$fatal(1,"LFN table/default/truncation differs ordinal=%d",n);
 @(negedge clk);
end
$display("PASS all 32 LFN ordinals: both native table ports, default base 247, special length 255 and eight-bit overflow");$finish;
end endmodule
''',encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[b/'rtl/fat/fat32_ro.v',tb],includes=[b/'rtl',b/'rtl/fat'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
