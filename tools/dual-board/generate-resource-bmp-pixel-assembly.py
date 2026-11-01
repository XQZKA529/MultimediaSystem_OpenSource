"""Assemble RGB directly in the existing ready/valid output register.

Blue/green private lifetimes end at the red-byte publication edge. Assemble
those bytes in the invalid output instead of duplicating 16 storage bits.
Valid pixels, all handshake/done cycles, reset and stalled valid data remain
identical. Invalid pixel_rgb is unspecified by the ready/valid interface.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args()
snapshot(a.source,a.destination)
f=a.destination/'rtl/image/bmp_pixel_unpack.v';s=f.read_text(encoding='utf-8-sig')
assert s.count('reg [7:0] b,g;')==1
s=s.replace('reg [7:0] b,g;','// RGB is assembled only while invalid or after the preceding pixel is accepted.')
assert 'b<=0;g<=0;' in s;s=s.replace('b<=0;g<=0;','')
assert 'b<=byte_data;' in s and 'g<=byte_data;' in s
s=s.replace('b<=byte_data;', 'pixel_rgb[7:0]<=byte_data;')
s=s.replace('g<=byte_data;', 'pixel_rgb[15:8]<=byte_data;')
assert 'pixel_rgb<={byte_data,g,b};' in s
s=s.replace('pixel_rgb<={byte_data,g,b};', 'pixel_rgb[23:16]<=byte_data;')
f.write_text(s,encoding='utf-8')
