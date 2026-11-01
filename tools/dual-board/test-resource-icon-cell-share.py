"""Exhaustively compare both independently addressed ports to separate old ROMs."""
import argparse, re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser()
p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True)
a=p.parse_args();b=a.candidate.resolve();r=a.reference.resolve()
w=b.parent/'icon-cell-share-equivalence';w.mkdir(parents=True,exist_ok=True)
s=(r/'rtl/ui/ui_text_overlay.v').read_text(encoding='utf-8-sig')
ref=w/'reference.v'
ref.write_text(''.join(re.search(r'\nmodule '+name+r'\(.*?\nendmodule\n',s,re.S)[0]
    for name in ('resource_ui_cell9','resource_icon_pixels')),encoding='utf-8')
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0;always #5 clk=~clk;
reg [9:0] bitmap=0;reg [8:0] x=0;
wire [7:0] pixel,cell_word,old_pixel,old_cell;
resource_icon_cell_shared dut(.clk(clk),.a(bitmap),.b({3'b110,x[8:2]}),.qa(pixel),.qb(cell_word));
resource_icon_pixels oldp(.clk(clk),.addr(bitmap),.q(old_pixel));
resource_ui_cell9 oldc(.clk(clk),.addr({1'b0,x}),.q(old_cell));
integer i,j,checks=0;
initial begin
@(negedge clk);
for(i=0;i<752;i=i+1)for(j=0;j<512;j=j+1)begin
 bitmap=i;x=j;@(posedge clk);#1;
 if(pixel!==old_pixel || cell_word!==old_cell)$fatal(1,"independent shared ports differ bitmap=%0d x=%0d",i,j);
 checks=checks+1;@(negedge clk);
end
$display("PASS %0d simultaneous bitmap/cell reads: every reachable icon word and all 512 cell inputs",checks);$finish;
end endmodule
''',encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',
    [b/'rtl/ui/ui_text_overlay.v',ref,tb],includes=[b/'rtl',b/'rtl/ui'],
    defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=True)
