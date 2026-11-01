"""Reuse the second product's operand storage for its completed result.

start stores {src_h,dst_w} in the 29-bit cross_h bank. State 1 consumes those
operands and overwrites the same bank with product. State 2 consumes the result.
The start-priority multiplier mux still selects live src_w/dst_h directly, so
multi-cycle/interrupted starts and all arithmetic widths/cycles are preserved.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/image/image_scale_geometry.v'
s=f.read_text(encoding='utf-8-sig')
assert s.count('reg [12:0] second_src;reg [15:0] second_dst;')==1
# Declare the shared bank before its combinational use (no implicit nets).
s=s.replace('reg [12:0] second_src;reg [15:0] second_dst;', '''// Before state 1: {second source,second destination}; afterwards: product.
    reg [28:0] cross_h;''')
s=s.replace('start ? src_w:second_src', 'start ? src_w:cross_h[28:16]')
s=s.replace('start ? dst_h:second_dst', 'start ? dst_h:cross_h[15:0]')
s=s.replace('cross_w,cross_h,numerator', 'cross_w,numerator')
s=s.replace('second_src<=src_h;second_dst<=dst_w;', 'cross_h<={src_h,dst_w};')
assert 'second_src' not in s and 'second_dst' not in s
f.write_text(s,encoding='utf-8')
