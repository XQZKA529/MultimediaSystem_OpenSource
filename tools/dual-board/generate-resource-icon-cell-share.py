"""Share the icon bitmap ROM's unused space/read port with the UI cell table.

All four adjacent x inputs have the same seven-bit cell word: divisors are
multiples of four and the low two glyph bits already bypass the ROM. The
128 words fit at 768..895, above all 47*16 reachable bitmap words (0..751).
Independent synchronous ports retain both existing one-cycle read stages.
"""
import argparse, json, re
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import byte_dual_rom9

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args()
snapshot(a.source,a.destination)
f=a.destination/'rtl/ui/ui_text_overlay.v'
s=f.read_text(encoding='utf-8-sig')
def words(name):
    module=re.search(r'\nmodule '+name+r'\(.*?\nendmodule\n',s,re.S)[0]
    data={int(i):int(v) for i,v in re.findall(r"mem\[(\d+)\]=8'd(\d+);",module)}
    assert len(data)==1024
    return module,[data[i] for i in range(1024)]
cell_module,cell=words('resource_ui_cell9')
pixel_module,pixel=words('resource_icon_pixels')
row_module,rows=words('resource_icon_rows')
assert max(rows)==46
for x in range(512):assert cell[x]==cell[(x>>2)<<2]
assert all(v==0 for v in pixel[752:])
pixel[768:896]=cell[:512:4]
cell_instance="    resource_ui_cell9 u_cell(.clk(video_clk),.addr({1'b0,tx_0}),.q(cell_word));"
assert s.count(cell_instance)==1
s=s.replace(cell_instance,'')
# The shared instance now precedes the original cell wire declaration. Keep
# explicit widths ahead of either user so Verilog cannot infer a scalar net.
assert s.count('wire [7:0] cell_word;')==1
s=s.replace('wire [7:0] cell_word;','')
s=s.replace('wire [7:0] icon_row_id,icon_bits;',
            'wire [7:0] icon_row_id,icon_bits;\n    wire [7:0] cell_word;')
old='resource_icon_pixels u_icon_pixels(.clk(video_clk),.addr({icon_row_id[5:0],ix_0[6:3]}),.q(icon_bits));'
assert s.count(old)==1
s=s.replace(old,"resource_icon_cell_shared u_icon_pixels(.clk(video_clk),.a({icon_row_id[5:0],ix_0[6:3]}),\n      .b({3'b110,tx_0[8:2]}),.qa(icon_bits),.qb(cell_word));")
s=s.replace(cell_module,'').replace(pixel_module,'')
f.write_text(s+byte_dual_rom9('resource_icon_cell_shared',pixel),encoding='utf-8')
(a.destination.parent/'icon-cell-share.json').write_text(json.dumps(dict(
    reachable_bitmap_last_address=751,cell_start=768,cell_words=128,
    checked_cell_inputs=512,changed_latency=False,native_bram9k_saved=1),indent=2),encoding='utf-8')
