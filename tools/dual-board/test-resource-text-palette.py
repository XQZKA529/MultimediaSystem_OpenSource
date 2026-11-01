"""All palette addresses against original Verilog arithmetic, both RAM models."""
import argparse,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
a=p.parse_args();b=a.candidate.resolve();root=Path(__file__).resolve().parents[2]
w=b.parent/'text-palette-address-oracle';w.mkdir(parents=True,exist_ok=True)
original=(root/'build/resource-v1/base/render/rtl/ui/text_osd_overlay.v').read_text(encoding='utf-8-sig')
glass=re.search(r'    function \[7:0\] glass_channel;.*?    endfunction',original,re.S)[0]
tb='''module tb;
reg clk=0;always #5 clk=~clk;reg [9:0] a=0,b=0;wire [15:0] qa,qb;wire [7:0] blue;
resource_text_background_rg rg(.clk(clk),.addr(a),.addr_b(b),.q(qa),.q_b(qb));
resource_text_background_b bb(.clk(clk),.addr(a),.q(blue));
`include "font_blend.vh"
'''+glass+'''
function [7:0] expected;input [9:0] addr;input [7:0] bg,cursor,shadow;
begin case(addr[9:8])
0:expected=addr[7:0];1:expected=glass_channel(addr[7:0],bg,3);
2:expected=glass_channel(addr[7:0],cursor,2);
3:expected=font_blend_channel(shadow,addr[7:0],1);
endcase end endfunction
integer i;
initial begin
repeat(4)@(negedge clk);
for(i=0;i<1024;i=i+1) begin
a=i;b=1023-i;@(posedge clk);#1;
if(qa!=={expected(a,23,63,37),expected(a,20,58,32)} ||
   qb!=={expected(b,23,63,37),expected(b,20,58,32)} || blue!==expected(a,27,70,44))
 $fatal(1,"Palette differs at %0d",i);
@(negedge clk);
end
$display("PASS exact original arithmetic at all 1024 addresses, both RG ports and B");$finish;
end endmodule
'''
(w/'tb.v').write_text(tb,encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[b/'rtl/ui/text_osd_overlay.v',w/'tb.v'],
 includes=[b/'rtl',b/'rtl/ui'],native=True,defines=[] if native else ['DB_BEHAVIORAL_RAM'])
