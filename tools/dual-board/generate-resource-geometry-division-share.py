"""Reuse consumed dividend bits for quotient bits in restoring division.

Exactly 29 shift/subtract steps replace all dividend bits with quotient bits.
Every decision still sees the original next dividend bit; public timing and
round-to-even (including zero/invalid geometry) remain unchanged.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args()
snapshot(a.source,a.destination)
file=a.destination/'rtl/image/image_scale_geometry.v'
s=file.read_text(encoding='utf-8-sig')
assert 'reg [28:0] cross_w,cross_h,numerator,quotient;' in s
s=s.replace('reg [28:0] cross_w,cross_h,numerator,quotient;', 'reg [28:0] cross_w,cross_h,numerator;')
s=s.replace(' && quotient[0]', ' && numerator[0]')
s=s.replace('quotient<=0;remainder<=0;', 'remainder<=0;')
s=s.replace('numerator<=numerator<<1;\n                quotient<={quotient[27:0],shifted>={1\'b0,divisor}};',
'''// The next dividend bit leaves bit 28 before the new quotient
                // decision enters bit zero. After 29 steps this is the quotient.
                numerator<={numerator[27:0],shifted>={1'b0,divisor}};''')
s=s.replace('rounded_dim<=quotient[15:0]+round_latched;', 'rounded_dim<=numerator[15:0]+round_latched;')
assert 'quotient[' not in s and 'quotient<=' not in s
file.write_text(s,encoding='utf-8')
