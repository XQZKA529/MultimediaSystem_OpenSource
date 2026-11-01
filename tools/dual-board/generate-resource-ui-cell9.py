"""Map the exact bounded UI column/remainder chain into one BRAM9K byte ROM.

All 512 addresses preserve the five-step original division, which saturates
at column 31 rather than truncating a mathematical quotient. Low two glyph
coordinate bits equal x[1:0], leaving only seven table bits per address.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import byte_rom9,rom
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);p.add_argument('--bram32',action='store_true');a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/ui/ui_text_overlay.v';s=f.read_text(encoding='utf-8-sig')
fun=re.search(r'    function \[4:0\] cell_index;.*?    endfunction',s,re.S)[0]
words=[]
for x in range(512):
 rem=x;q=0
 for div,bit in ((192,16),(96,8),(48,4),(24,2),(12,1)):
  if rem>=div:rem-=div;q+=bit
 gx=(x-12*q)&15
 assert gx&3==x&3
 words.append((q<<2)|(gx>>2))
s=s.replace(fun,'')
s=s.replace('reg [4:0] col_1;', '''wire [7:0] cell_word;
    reg cell_valid;
    wire [4:0] col_1=cell_valid ? cell_word[6:2]:5'd0;
    wire [3:0] cell_gx;
    resource_ui_cell9 u_cell(.clk(video_clk),.addr({1'b0,tx_0}),.q(cell_word));''')
s=s.replace('reg [8:0] tx_1;', "reg [8:0] tx_1;\n    assign cell_gx=cell_valid ? {cell_word[1:0],tx_1[1:0]}:4'd0;")
s=s.replace('col_1<=0;', 'cell_valid<=0;').replace('col_1<=cell_index(tx_0);','cell_valid<=1;')
old="gx_2<=tx_1-({4'd0,col_1}<<3)-({4'd0,col_1}<<2);";assert old in s
s=s.replace(old,'gx_2<=cell_gx;')
if a.bram32:
 s=s.replace('wire [7:0] cell_word;', 'wire [15:0] cell_word;')
 s=s.replace("resource_ui_cell9 u_cell(.clk(video_clk),.addr({1'b0,tx_0}),.q(cell_word));", "resource_ui_cell32 u_cell(.clk(video_clk),.addr(tx_0),.addr_b(9'd0),.q(cell_word),.q_b());")
 s+=rom('resource_ui_cell32',words,9)
else:s+=byte_rom9('resource_ui_cell9',words)
f.write_text(s,encoding='utf-8')
e=a.destination.parent/'ui-cell-generation';e.mkdir(parents=True,exist_ok=True)
(e/'original_cell_index.v').write_text(fun,encoding='utf-8')
