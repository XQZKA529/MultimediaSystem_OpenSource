"""Reuse cross_w for the selected dividend, then for the quotient.

State 2 consumes both cross products to latch wide/divisor and select min.
Thereafter neither original cross product is needed. Nonblocking assignments
keep all state-2 comparisons on the original values. Divider bit count, round
and all output cycles are unchanged, including invalid/interrupted operations.
"""
import argparse
from pathlib import Path
import re
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/image/image_scale_geometry.v'
s=f.read_text(encoding='utf-8-sig')
assert s.count('reg [28:0] cross_w,numerator;')==1
s=s.replace('reg [28:0] cross_w,numerator;', '''// Cross product, then selected dividend, then completed quotient.
    reg [28:0] cross_w;''')
s=re.sub(r'\bnumerator\b','cross_w',s)
f.write_text(s,encoding='utf-8')
