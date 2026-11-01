"""Exhaustively check both native and behavioral dictionary ROM addresses."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
a=p.parse_args();b=a.candidate.resolve();root=Path(__file__).resolve().parents[2]
w=b.parent/'icon-address-oracle';w.mkdir(parents=True,exist_ok=True)
bits=[int(x,16) for x in (root/'build/resource-v1/tables/icons.bits').read_text().split()]
rows=[];ids=[]
for i in range(0,len(bits),96):
 row=tuple(bits[i:i+96])
 if row not in rows:rows.append(row)
 ids.append(rows.index(row))
lookup=[0]*1024;pixels=[0]*1024
for k in range(8):
 for y in range(96):lookup[k*128+y]=ids[(4 if k==7 else k)*96+y]
for r,row in enumerate(rows):
 for x in range(12):pixels[r*16+x]=sum(row[x*8+j]<<j for j in range(8))
for name,values in [('rows.hex',lookup),('pixels.hex',pixels)]:
 (w/name).write_text(''.join(f'{x:02x}\n' for x in values),encoding='utf-8')
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0;always #5 clk=~clk;reg [9:0] addr=0;wire [7:0] row,pixel;
reg [7:0] expected_row[0:1023],expected_pixel[0:1023];reg [2047:0] path;
integer i;
resource_icon_rows r(.clk(clk),.addr(addr),.q(row));
resource_icon_pixels p(.clk(clk),.addr(addr),.q(pixel));
initial begin
if(!$value$plusargs("ROWS=%s",path))$fatal(1,"ROWS missing");$readmemh(path,expected_row);
if(!$value$plusargs("PIXELS=%s",path))$fatal(1,"PIXELS missing");$readmemh(path,expected_pixel);
repeat(4)@(negedge clk);
for(i=0;i<1024;i=i+1) begin
 addr=i;@(posedge clk);#1;
 if(row!==expected_row[i] || pixel!==expected_pixel[i])$fatal(1,"dictionary address %0d differs",i);
 @(negedge clk);
end
$display("PASS all 2048 row/pixel ROM addresses");$finish;
end endmodule
''',encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[b/'rtl/ui/ui_text_overlay.v',tb],
 includes=[b/'rtl',b/'rtl/ui'],native=True,defines=[] if native else ['DB_BEHAVIORAL_RAM'],
 plus=['+ROWS='+str(w/'rows.hex'),'+PIXELS='+str(w/'pixels.hex')])
