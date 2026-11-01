"""Pack every pair of exact five-bit glyph rows into one BRAM32K word."""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import rom
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/emergency/emergency_overlay.v';s=f.read_text(encoding='utf-8-sig')
fun=re.search(r'    function \[4:0\] glyph_row;.*?    endfunction',s,re.S)[0]
entries=re.findall(r"12'h([0-9a-fA-F]+):glyph_row=5'b([01]+);",fun)
assert len(entries)==96 and 'default:glyph_row=0;' in fun
rows=[0]*4096
for address,value in entries:rows[int(address,16)]=int(value,2)
words=[rows[i]|(rows[i+1]<<5) for i in range(0,4096,2)]
s=s.replace(fun,'').replace('    reg [4:0] glyph2;', '''    wire [15:0] glyph_word;
    reg glyph_valid,glyph_odd;
    wire [4:0] glyph2=!glyph_valid ? 5'd0:(glyph_odd ? glyph_word[9:5]:glyph_word[4:0]);
    resource_emergency_pair_rom u_glyph(.clk(clk),
      .addr({character1,text_y1[4:2]}),.addr_b(11'd0),.q(glyph_word),.q_b());''')
s=s.replace('glyph2<=0;','glyph_valid<=0;glyph_odd<=0;').replace('glyph2<=glyph_row(character1,text_y1[4:1]);','glyph_valid<=1;glyph_odd<=text_y1[1];')
assert not re.search(r'\bglyph2\s*<=',s)
f.write_text(s+rom('resource_emergency_pair_rom',words,11),encoding='utf-8')
