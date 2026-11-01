"""All final AA table addresses against the original /3 blend function."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
a=p.parse_args();b=a.candidate.resolve();w=b.parent/'text-final-address-oracle';w.mkdir(parents=True,exist_ok=True)
tb='''module tb;
reg clk=0;always #5 clk=~clk;reg [9:0] a=0,b=0;wire [15:0] qa,qb;wire [7:0] blue;
resource_text_final_rg rg(.clk(clk),.addr(a),.addr_b(b),.q(qa),.q_b(qb));
resource_text_final_b bb(.clk(clk),.addr(a),.q(blue));
`include "font_blend.vh"
function [15:0] expected;input [9:0] addr;
begin expected={font_blend_channel(8'd247,addr[7:0],addr[9:8]),
                font_blend_channel(8'd245,addr[7:0],addr[9:8])};end endfunction
integer i;
initial begin
repeat(4)@(negedge clk);
for(i=0;i<1024;i=i+1) begin
a=i;b=1023-i;@(posedge clk);#1;
if(qa!==expected(a) || qb!==expected(b) || blue!==font_blend_channel(8'd250,a[7:0],a[9:8]))
 $fatal(1,"Final AA palette differs at %0d",i);
@(negedge clk);
end
$display("PASS exact original /3 AA at all 1024 addresses, both RG ports and B");$finish;
end endmodule
'''
(w/'tb.v').write_text(tb,encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[b/'rtl/ui/text_osd_overlay.v',w/'tb.v'],
 includes=[b/'rtl',b/'rtl/ui'],native=True,defines=[] if native else ['DB_BEHAVIORAL_RAM'])
