"""Fold constant BMP validation bytes and provably unused dimension high bits.

Every header byte is consumed exactly once by the existing bounded lane index.
Sticky invalid flags preserve rejection of all illegal input values. Generic
MAX_DIM values above the 13-bit output range retain full 32-bit input fields.
File sizes, offsets, overflow validation and result latency are unchanged.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/image/bmp_header_parser.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('reg [15:0] signature,planes,bpp;', '''reg signature_bad,planes_bad,bpp_bad,compression_bad;
    localparam DIM_BITS=(MAX_DIM>=0 && MAX_DIM<8192) ? 13:32;
    reg [DIM_BITS-1:0] w,h;
    reg w_high_bad,h_high_bad;''')
s=s.replace('declared_size,dib_size,w,h,compression','declared_size,dib_size')
s=s.replace('signature<=0;planes<=0;bpp<=0;',
            'signature_bad<=0;planes_bad<=0;bpp_bad<=0;compression_bad<=0;w_high_bad<=0;h_high_bad<=0;')
s=s.replace('w<=0;h<=0;compression<=0;', 'w<=0;h<=0;')
for lane,field,value in [(0,'signature',0x42),(1,'signature',0x4d),(26,'planes',1),(27,'planes',0),
                         (28,'bpp',24),(29,'bpp',0),*[(n,'compression',0) for n in range(30,34)]]:
    import re
    s,n=re.subn(r"if\(\(lane==6'd"+str(lane)+r"\)\) "+field+r"\[\d+:\d+\]<=byte_data;",
                f"if((lane==6'd{lane})) {field}_bad<={field}_bad || byte_data!=8'd{value};",s)
    assert n==1
for field,first in [('w',18),('h',22)]:
    for offset in range(1,4):
        lane=first+offset;low=offset*8;high=low+7
        old=f"if((lane==6'd{lane})) {field}[{high}:{low}]<=byte_data;"
        new=f"if((lane==6'd{lane})) begin\n                    {field}<=({field} & 32'h{(0xffffffff ^ (255<<low)):08x}) | ({{24'd0,byte_data}}<<{low});\n"
        new+=f"                    {field}_high_bad<={field}_high_bad || "+ ('(|byte_data[7:5]);' if offset==1 else '(|byte_data);')+'\n                end'
        assert old in s;s=s.replace(old,new)
s=s.replace("signature==16'h4d42",'!signature_bad')
s=s.replace('planes==1 && bpp==24 && compression==0', '!planes_bad && !bpp_bad && !compression_bad')
s=s.replace('w!=0 && w<=MAX_DIM && h!=0 && h<=MAX_DIM;',
'''w!=0 && w<=MAX_DIM && h!=0 && h<=MAX_DIM &&
                        (DIM_BITS!=13 || (!w_high_bad && !h_high_bad));''')
f.write_text(s,encoding='utf-8')
