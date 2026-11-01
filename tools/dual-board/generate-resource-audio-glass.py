"""Absorb exact static panel-tint arithmetic into the existing second stage."""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import rom
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/ui/audio_osd_overlay.v';s=f.read_text(encoding='utf-8-sig')
fun=re.search(r'    function \[23:0\] glass_rgb;.*?    endfunction',s,re.S)[0]
s=s.replace(fun,'')
old='glass_rgb(pix_r,C_PANEL_BG)';assert s.count(old)==1;s=s.replace(old,'glass_pixel')
i=s.index('    assign pix_out =')
logic='''    // Same edge as pix_r: tint lookups consume pix_d1, preserving two clocks.
    wire [15:0] glass_r,glass_g,glass_b;
    wire [23:0] glass_pixel={glass_r[7:0],glass_g[15:8],glass_b[7:0]};
    resource_audio_glass_rg u_glass_rg(.clk(video_clk),.addr(pix_d1[23:16]),
      .addr_b(pix_d1[15:8]),.q(glass_r),.q_b(glass_g));
    resource_audio_glass_b u_glass_b(.clk(video_clk),.addr(pix_d1[7:0]),
      .addr_b(8'd0),.q(glass_b),.q_b());
'''
s=s[:i]+logic+s[i:]
def value(x,tint):return (x+(x>>1)+(tint>>1))>>2
rg=[value(x,20)|(value(x,23)<<8) for x in range(256)]
blue=[value(x,27) for x in range(256)]
f.write_text(s+rom('resource_audio_glass_rg',rg,8)+rom('resource_audio_glass_b',blue,8),encoding='utf-8')
