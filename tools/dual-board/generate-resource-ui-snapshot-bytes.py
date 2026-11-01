"""Write UI snapshot bytes directly into four synchronous byte RAM lanes.

Keep all 128 words, the live/snapshot separation, copy/commit/dirty rules,
word endianness and one-cycle read. Remove only the redundant 24-bit shift
assembly. Snapshot publication still waits for the same final byte edge.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/seam/seam_media.v';s=f.read_text(encoding='utf-8-sig')
old='    reg [31:0] ui_snapshot[0:127] /* fehdl force_ram=1, ram_style="bram" */;'
assert s.count(old)==1
s=s.replace(old,'\n'.join(f'    reg [7:0] ui_snapshot_{i}[0:127] /* fehdl force_ram=1, ram_style="bram" */;' for i in range(4)))
s=s.replace('reg [31:0] ui_build,ui_flags;','reg [31:0] ui_flags;')
old='''        if(copy_state==2 && copy_index[1:0]==3)
            ui_snapshot[copy_index[8:2]]<={ui_build[23:0],ui_q};
        ui_send_q<=ui_snapshot[ui_read_word];'''
assert s.count(old)==1
new=''
for i in range(4):
 new+=f'''        if(copy_state==2 && copy_index[1:0]==2'd{i})
            ui_snapshot_{i}[copy_index[8:2]]<=ui_q;
        ui_send_q[{31-8*i}:{24-8*i}]<=ui_snapshot_{i}[ui_read_word];
'''
s=s.replace(old,new)
s=s.replace('ui_build<=0;','').replace('                    ui_build<={ui_build[23:0],ui_q};','')
assert 'ui_build' not in s
f.write_text(s,encoding='utf-8')
