"""Share identical R/G lookup contents across two native read ports per stage.

The background and white stages remain separate physical memories. No RAM
output feeds another port of the same RAM; latency and the RGB stream stay six
clocks. This frees two BRAM32Ks without changing lookup values or bit selection.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import byte_dual_rom9
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);p.add_argument('--white9',action='store_true')
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/ui/ui_text_overlay.v';s=f.read_text(encoding='utf-8-sig')
start=s.index('    resource_ui_channel r_table(');end=s.index('    resource_ui_channel b_table(',start)
s=s[:start]+'''    resource_ui_pair rg_table(.clk(video_clk),.src_r(rgb_2[23:16]),.src_g(rgb_2[15:8]),.mode(palette_mode),
        .white_r(solid_3 ? tone_3:br_3),.white_g(solid_3 ? tone_3:bg_3),.alpha(white_alpha),
        .background_r(br_3),.background_g(bg_3),.result_r(cr_4),.result_g(cg_4));
'''+s[end:]
s+='''
module resource_ui_pair(input wire clk,input wire [7:0] src_r,src_g,white_r,white_g,
 input wire [2:0] mode,input wire [1:0] alpha,
 output wire [7:0] background_r,background_g,result_r,result_g);
 wire [15:0] bg_r,bg_g,fg_r,fg_g;
 reg [3:0] low_bits;
 always @(posedge clk)low_bits<={src_r[0],src_g[0],white_r[0],white_g[0]};
 resource_ui_background u_bg(.clk(clk),.addr({1'b0,mode,src_r[7:1]}),
   .addr_b({1'b0,mode,src_g[7:1]}),.q(bg_r),.q_b(bg_g));
 resource_ui_white u_white(.clk(clk),.addr({alpha,white_r[7:1]}),
   .addr_b({alpha,white_g[7:1]}),.q(fg_r),.q_b(fg_g));
 assign background_r=low_bits[3] ? bg_r[15:8]:bg_r[7:0];
 assign background_g=low_bits[2] ? bg_g[15:8]:bg_g[7:0];
 assign result_r=low_bits[1] ? fg_r[15:8]:fg_r[7:0];
 assign result_g=low_bits[0] ? fg_g[15:8]:fg_g[7:0];
endmodule
'''
if a.white9:
 start=s.index('module resource_ui_pair(')
 pair=s[start:]
 pair=pair.replace('wire [15:0] bg_r,bg_g,fg_r,fg_g;', 'wire [15:0] bg_r,bg_g;\n wire [7:0] fg_r,fg_g;')
 pair=pair.replace('reg [3:0] low_bits;', 'reg [1:0] low_bits;')
 pair=pair.replace('low_bits<={src_r[0],src_g[0],white_r[0],white_g[0]};', 'low_bits<={src_r[0],src_g[0]};')
 first=pair.index(' resource_ui_white u_white(');last=pair.index(' assign background_r=',first)
 pair=pair[:first]+''' resource_ui_white_pair9 u_white(.clk(clk),.a({alpha,white_r}),.b({alpha,white_g}),.qa(fg_r),.qb(fg_g));
'''+pair[last:]
 pair=pair.replace('low_bits[3]','low_bits[1]').replace('low_bits[2]','low_bits[0]')
 pair=pair.replace('assign result_r=low_bits[1] ? fg_r[15:8]:fg_r[7:0];', 'assign result_r=fg_r;')
 pair=pair.replace('assign result_g=low_bits[0] ? fg_g[15:8]:fg_g[7:0];', 'assign result_g=fg_g;')
 white=s[s.index('module resource_ui_white('):start]
 entries={int(i):int(v,16) for i,v in re.findall(r"mem\[(\d+)\]=16'h([0-9a-fA-F]{4});",white)}
 assert len(entries)==512 and set(entries)==set(range(512))
 words=[byte for i in range(512) for byte in (entries[i]&255,entries[i]>>8)]
 s=s[:start]+pair+byte_dual_rom9('resource_ui_white_pair9',words)
f.write_text(s,encoding='utf-8')
