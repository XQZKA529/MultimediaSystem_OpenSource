"""Remove a duplicate segment cursor held unchanged throughout each burst/retry."""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/storage/lba_stream.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('reg [15:0] burst_nsec;', '''localparam BURST_BITS=(MAX_BURST[15:0]==0) ? 1:$clog2({1'b0,MAX_BURST[15:0]}+1);
    reg [BURST_BITS-1:0] burst_nsec;''')
s,n=re.subn(r'    reg \[23:0\] burst_base_nsec;\n','',s);assert n==1
s,n=re.subn(r'\s*burst_base_nsec <= (?:0|cur_nsec);','',s);assert n==2
s=s.replace('cur_nsec <= burst_base_nsec - burst_nsec;', '''// cur_nsec cannot change between S_CALC and S_NEXT, including
                    // retries and backpressure. Reuse the active cursor.
                    cur_nsec <= cur_nsec - burst_nsec;''')
assert 'burst_base_nsec' not in s
f.write_text(s,encoding='utf-8')
