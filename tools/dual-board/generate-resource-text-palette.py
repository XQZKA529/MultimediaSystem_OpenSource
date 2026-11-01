"""Replace Text OSD stage-C glass/shadow arithmetic with exact synchronous ROMs.

One dual-port BRAM32K packs independent R/G answers into each word, while one
BRAM9K serves B. Reads replace glyph_bg_d's existing register, preserving all
four pixel/sync stages and arbitrary per-cycle focus/coverage inputs.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import rom,byte_rom9
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/ui/text_osd_overlay.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('rgb_c,rgb_d,glyph_bg_d;','rgb_c,rgb_d;')
s=s.replace('glyph_bg_d<=0;','')
begin=s.index('            glyph_bg_d<=');end=s.index('            hs_pipe<=',begin)
s=s[:begin]+s[end:]
decl='''    reg [1:0] background_mode;
    always @(*) begin
      background_mode=txt_c ? (high_c ? 2'd2:2'd1):
                      ((line_d && coverage!=0) ? 2'd3:2'd0);
    end
    wire [15:0] background_r,background_g;
    wire [7:0] background_b;
    reg background_valid;
    always @(posedge clk or posedge rst) if(rst) background_valid<=0;else background_valid<=1;
    wire [23:0] glyph_bg_d=background_valid ? {background_r[7:0],background_g[15:8],background_b}:24'd0;
    resource_text_background_rg u_background_rg(.clk(clk),.addr({background_mode,rgb_c[23:16]}),
      .addr_b({background_mode,rgb_c[15:8]}),.q(background_r),.q_b(background_g));
    resource_text_background_b u_background_b(.clk(clk),.addr({background_mode,rgb_c[7:0]}),.q(background_b));
'''
s=s.replace('    wire [23:0] glyph_background=glyph_bg_d;',decl+'    wire [23:0] glyph_background=glyph_bg_d;')
rgb=[[],[],[]]
for mode in range(4):
 for src in range(256):
  for c,(bg,cursor,shadow) in enumerate([(20,58,32),(23,63,37),(27,70,44)]):
   rgb[c].append([src,(3*src+bg)//4,(src+cursor)//2,(shadow+2*src+1)//3][mode])
s+=rom('resource_text_background_rg',[r|(g<<8) for r,g in zip(rgb[0],rgb[1])],10)
s+=byte_rom9('resource_text_background_b',rgb[2])
f.write_text(s,encoding='utf-8')
