"""Pack the exact emergency glyph rows into one BRAM9K, retaining one read stage."""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import byte_rom9
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args()
snapshot(a.source,a.destination)
f=a.destination/'rtl/emergency/emergency_overlay.v';s=f.read_text(encoding='utf-8-sig')
fun=re.search(r'    function \[4:0\] glyph_row;.*?    endfunction',s,re.S)[0]
entries=re.findall(r"12'h([0-9a-fA-F]+):glyph_row=5'b([01]+);",fun)
assert len(entries)==96 and 'default:glyph_row=0;' in fun
words=[0]*1024
for address,value in entries:
 address=int(address,16);char=address>>4;row=address&15
 assert char<128 and 2<=row<=8
 words[char*8+(row&7)]=int(value,2)
s=s.replace(fun,'').replace('    reg [4:0] glyph2;', '''    // Rows 2..8 are the only nonzero rows. Row 8 occupies index 0;
    // the registered guard distinguishes it from rows 0 and 9..15.
    wire [7:0] glyph_word;
    reg glyph_valid;
    wire [4:0] glyph2=glyph_valid ? glyph_word[4:0]:5'd0;
    resource_emergency_glyph9 u_glyph(.clk(clk),
      .addr({character1[6:0],text_y1[3:1]}),.q(glyph_word));''')
s=s.replace('glyph2<=0;','glyph_valid<=0;').replace('glyph2<=glyph_row(character1,text_y1[4:1]);',
 'glyph_valid<=!character1[7] && text_y1[4:1]>=2 && text_y1[4:1]<=8;')
f.write_text(s+byte_rom9('resource_emergency_glyph9',words),encoding='utf-8')
