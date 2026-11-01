"""Share the disjoint DIR and FILE/MAP active hop-counter lifetimes.

Directory admission initializes the full 32-bit count; FILE/MAP admission also
initializes it, and retain their original 24/20-bit arithmetic and overflow.
Pending requests, Brent cycle state, limits and externally visible fields are
independent. No state/latency or initialization edge changes.
"""
import argparse
import re
from pathlib import Path
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
file=a.destination/'rtl/fat/fat32_ro.v'
s=file.read_text(encoding='utf-8-sig')
assert s.count('reg [23:0] walk_hops, walk_hops_next;')==1
s=s.replace('reg [23:0] walk_hops, walk_hops_next;', 'reg [31:0] walk_hops;reg [23:0] walk_hops_next;')
s=s.replace('reg [31:0] dir_hops;', '''// Active DIR and FILE/MAP traversal lifetimes cannot overlap.
// Their original admission edges initialize this shared full-width counter.
wire [31:0] dir_hops=walk_hops;''')
s=re.sub(r'\bdir_hops\s*<=', 'walk_hops<=',s)
file.write_text(s,encoding='utf-8')
