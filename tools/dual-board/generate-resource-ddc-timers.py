"""Trim DDC counters to proven reachable ranges; keep CDC and absolute deadlines."""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/driver/ddc_i2c_master.v';s=f.read_text(encoding='utf-8-sig')
assert 'reg [31:0] tick,age;' in s
s=s.replace('reg [31:0] tick,age;', '''// tick is cleared at HALF-1. Timeout age increments once on the
    // timeout edge too, then holds TIMEOUT+1 while idle.
    localparam TICK_BITS=$clog2(HALF);
    localparam AGE_BITS=(TIMEOUT>=0 && TIMEOUT<32'h7fffffff) ?
        (($clog2(TIMEOUT+2)>0) ? $clog2(TIMEOUT+2):1):32;
    reg [TICK_BITS-1:0] tick;
    reg [AGE_BITS-1:0] age;''')
f.write_text(s,encoding='utf-8')
