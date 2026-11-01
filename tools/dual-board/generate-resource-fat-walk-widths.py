"""Trim private walker values only after full-width admission has validated them.

Keep incoming clusters, file lengths, LBAs and output words at 32 bits. A
mounted FAT32 cluster is below 0x0ffffff0; its next-contiguous value fits 28
bits. DIR hop count stops at max_cluster. MAP_USE=min(remaining, SPC*512)
is at most 65536 for every legal mounted SPC, including its terminal value.
"""
import argparse,re,json
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
fields=dict(map_use_bytes=(17,'min(remaining, bytes_per_cluster) <= 65536'),
 cycle_tortoise=(28,'used only after full32 FILE/MAP admission; subsequently valid FAT entries'),
 dir_hops=(28,'starts at zero; original dir_hops_max stops increments at valid max_cluster'),
 map_cluster_prev=(28,'captures only an admitted valid MAP cluster'),
 map_cluster_prev_p1=(28,'valid cluster+1 <= 0x0ffffff0; no discarded carry'))
for name,(width,reason) in fields.items():
 s,n=re.subn(r'reg \[31:0\] '+name+r';',f'reg [{width-1}:0] {name};',s);assert n==1,name
f.write_text(s,encoding='utf-8')
(a.destination.parent/'walker-width-ranges.json').write_text(json.dumps(dict(
    fields={name:dict(bits=width,proof=reason) for name,(width,reason) in fields.items()},
    public_widths_changed=False,admission_checks_changed=False,latency_changed=False),indent=2),encoding='utf-8')
