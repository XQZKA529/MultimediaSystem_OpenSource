"""Exact final Text OSD AA lookup, adding one aligned streaming pixel stage.

RGB and HS/VS/DE become five stages; the existing font, coordinate and shadow
stages stay aligned. One dual-port RG BRAM32K plus one B BRAM9K replaces the
three combinational /3 blends. Each cycle still produces one output pixel.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import rom,byte_rom9
from resource_text_latency import align_composed_tests
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
p.add_argument('--original-font',action='store_true',help='Restore original single BRAM32K font to fit combined palette budget')
a=p.parse_args();snapshot(a.source,a.destination)
if a.original_font:
 root=Path(__file__).resolve().parents[2]
 (a.destination/'rtl/ui/font_rom.v').write_bytes((root/'build/resource-v1/base/render/rtl/ui/font_rom.v').read_bytes())
f=a.destination/'rtl/ui/text_osd_overlay.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('// Four stages: coordinates, character index, byte lookup, synchronous font.',
 '// Five stages: coordinates, character index, byte lookup, font, exact AA ROM.')
s=s.replace('output reg [23:0] pix_out','output wire [23:0] pix_out')
s=s.replace('reg [3:0] hs_pipe,vs_pipe,de_pipe;','reg [4:0] hs_pipe,vs_pipe,de_pipe;')
for name,pin in [('hs_pipe','hs'),('vs_pipe','vs'),('de_pipe','de')]:
 s=s.replace('{'+name+'[2:0],'+pin+'}','{'+name+'[3:0],'+pin+'}')
start=s.index('    wire [23:0] glyph_rgb=font_blend(');end=s.index('\nendmodule',start)
s=s[:start]+'''    reg [23:0] palette_src;
    reg [1:0] palette_alpha;
    always @(*) begin
      palette_src=rgb_d;palette_alpha=0;
      if(de_pipe[3]) begin
        if(win_d && !txt_d) palette_src=C_BORDER;
        else if(txt_d || line_d) begin palette_src=glyph_background;palette_alpha=coverage;end
      end
    end
    wire [15:0] final_r,final_g;
    wire [7:0] final_b;
    reg final_valid;
    always @(posedge clk or posedge rst) if(rst) final_valid<=0;else final_valid<=1;
    assign pix_out=final_valid ? {final_r[7:0],final_g[15:8],final_b}:24'd0;
    resource_text_final_rg u_final_rg(.clk(clk),.addr({palette_alpha,palette_src[23:16]}),
      .addr_b({palette_alpha,palette_src[15:8]}),.q(final_r),.q_b(final_g));
    resource_text_final_b u_final_b(.clk(clk),.addr({palette_alpha,palette_src[7:0]}),.q(final_b));
    assign hs_out=hs_pipe[4];assign vs_out=vs_pipe[4];assign de_out=de_pipe[4];
'''+s[end:]
rgb=[[],[],[]]
for alpha in range(4):
 for src in range(256):
  for c,fg in enumerate([245,247,250]):
   rgb[c].append([src,(fg+2*src+1)//3,(2*fg+src+1)//3,fg][alpha])
s+=rom('resource_text_final_rg',[r|(g<<8) for r,g in zip(rgb[0],rgb[1])],10)
s+=byte_rom9('resource_text_final_b',rgb[2]);f.write_text(s,encoding='utf-8')
# Only the oracle queue's extra allowed latency changes; golden pixels do not.
tb=a.destination/'sim/tb_text_osd_overlay.v';s=tb.read_text(encoding='utf-8-sig')
s=s.replace('expected[0:3]','expected[0:4]').replace('reg [3:0] eh=','reg [4:0] eh=')
s=s.replace('expected[3]<=0;eh<=0;', 'expected[3]<=0;expected[4]<=0;eh<=0;')
s=s.replace('expected[3]<=expected[2];','expected[3]<=expected[2];expected[4]<=expected[3];')
for name,pin in [('eh','hs'),('ev','vs'),('ed','de')]:
 s=s.replace('{'+name+'[2:0],'+pin+'}','{'+name+'[3:0],'+pin+'}')
 s=re.sub(r'\b'+name+r'\[3\]',name+'[4]',s)
s=s.replace('result!==expected[3]','result!==expected[4]').replace('result,expected[3],','result,expected[4],')
s=s.replace('4-stage sync/bypass','5-stage sync/bypass')
tb.write_text(s,encoding='utf-8')
align_composed_tests(a.destination)
