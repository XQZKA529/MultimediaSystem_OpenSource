"""Exhaustive exact bounded UI column and glyph remainder oracle."""
import argparse,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path);a=p.parse_args();b=a.candidate.resolve()
w=b.parent/'ui-cell-equivalence';w.mkdir(parents=True,exist_ok=True)
if a.reference:
 original=(a.reference/'rtl/ui/ui_text_overlay.v').read_text(encoding='utf-8-sig')
 fun=re.search(r'    function \[4:0\] cell_index;.*?    endfunction',original,re.S)[0]
else:fun=(b.parent/'ui-cell-generation/original_cell_index.v').read_text(encoding='utf-8')
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0;always #5 clk=~clk;reg [8:0] x=0;wire [7:0] q;
resource_ui_cell9 dut(.clk(clk),.addr({1'b0,x}),.q(q));
'''+fun+'''
integer n;reg [4:0] col;reg [3:0] gx;
initial begin
@(negedge clk);
for(n=0;n<512;n=n+1)begin
 x=n;col=cell_index(x);gx=x-({4'd0,col}<<3)-({4'd0,col}<<2);
 @(posedge clk);#1;
 if(q[6:2]!==col || {q[1:0],x[1:0]}!==gx)$fatal(1,"UI bounded column/remainder differs at %d",n);
 @(negedge clk);
end
$display("PASS all 512 UI inputs: original saturated column and four-bit glyph remainder, including out-of-range truncation");$finish;
end endmodule
''',encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[b/'rtl/ui/font_rom.v',b/'rtl/ui/ui_text_overlay.v',tb],includes=[b/'rtl',b/'rtl/ui'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=True)
