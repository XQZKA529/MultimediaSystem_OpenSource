"""Specialize private geometry precision to the fixed destination rectangle.

CONTAIN bounds both dimensions by max(DST_W,DST_H). Width includes the terminal
dimension value. Generic geometry keeps its original 16-bit default; controller
only starts the pixel pipeline after valid header/geometry completion.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/image/image_scale_geometry.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('module image_scale_geometry(', 'module image_scale_geometry #(parameter DIM_BITS=16)(')
s=s.replace('reg [28:0] cross_w,cross_h,numerator,quotient;', 'reg [28:0] cross_w,cross_h,numerator;\n    reg [DIM_BITS-1:0] quotient;')
s=s.replace('reg [15:0] rounded_dim;', 'reg [DIM_BITS-1:0] rounded_dim;')
s=s.replace("quotient<={quotient[27:0],shifted>={1'b0,divisor}};", "quotient<=(quotient<<1) | (shifted>={1'b0,divisor});")
s=s.replace('quotient[15:0]+round_latched', 'quotient+round_latched')
assert 'quotient[27:0]' not in s
f.write_text(s,encoding='utf-8')
f=a.destination/'rtl/image/fat_bmp_controller.v';s=f.read_text(encoding='utf-8-sig')
marker='wire [15:0] scaled_w,scaled_h,left,bottom;'
assert marker in s
s=s.replace(marker,marker+'''
// Fixed destination bounds are private to this controller. Preserve generic
// parameter behavior outside the supported positive 16-bit rectangle.
localparam GEO_X_BITS=(DST_W<1 || DST_W>65535) ? 16:((DST_W<2) ? 1:$clog2(DST_W+1));
localparam GEO_Y_BITS=(DST_H<1 || DST_H>65535) ? 16:((DST_H<2) ? 1:$clog2(DST_H+1));
localparam GEO_DIM_BITS=GEO_X_BITS>GEO_Y_BITS ? GEO_X_BITS:GEO_Y_BITS;
''')
s=s.replace('image_scale_geometry geometry(', 'image_scale_geometry #(.DIM_BITS(GEO_DIM_BITS)) geometry(')
old='.scaled_w(scaled_w),.scaled_h(scaled_h),.left(left),.bottom(bottom),'
new='''.scaled_w({{(16-GEO_X_BITS){1'b0}},scaled_w[GEO_X_BITS-1:0]}),
    .scaled_h({{(16-GEO_Y_BITS){1'b0}},scaled_h[GEO_Y_BITS-1:0]}),
    .left({{(16-GEO_X_BITS){1'b0}},left[GEO_X_BITS-1:0]}),
    .bottom({{(16-GEO_Y_BITS){1'b0}},bottom[GEO_Y_BITS-1:0]}),'''
assert s.count(old)==1;s=s.replace(old,new)
f.write_text(s,encoding='utf-8')
