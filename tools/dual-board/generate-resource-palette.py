"""Generate the measured split-ROM UI palette without a same-BRAM feedback path.

Reads the frozen current-source baseline. Both original arithmetic stages stay
in place: background on stage 3, white coverage on stage 4, output on stage 5.
"""
import argparse
from pathlib import Path
import re
from resource_experiment import snapshot
from resource_rom import rom

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/resource-v1'

def generate(source, destination):
    snapshot(source, destination)
    s = (source / 'rtl/ui/ui_text_overlay.v').read_text(encoding='utf-8-sig')
    a = s.index('    function [9:0] blend_sum;')
    b = s.index('    always @(posedge video_clk or posedge rst) begin', a)
    s = s[:a] + '''    wire [7:0] br_3,bg_3,bb_3,cr_4,cg_4,cb_4;
    reg [2:0] palette_mode;
    always @(*) begin
        palette_mode=0;
        if(weight_2==3) palette_mode=1;
        else if(weight_2==2) case(tint_2)
            66:palette_mode=2;106:palette_mode=3;58:palette_mode=4;
            18:palette_mode=5;62:palette_mode=6;default:palette_mode=0;
        endcase
    end
    wire [1:0] white_alpha=solid_3 ? 2'd0:(text_3 ? coverage:2'd0);
    resource_ui_channel r_table(.clk(video_clk),.src(rgb_2[23:16]),.mode(palette_mode),
        .white_src(solid_3 ? tone_3:br_3),.alpha(white_alpha),.background(br_3),.white(cr_4));
    resource_ui_channel g_table(.clk(video_clk),.src(rgb_2[15:8]),.mode(palette_mode),
        .white_src(solid_3 ? tone_3:bg_3),.alpha(white_alpha),.background(bg_3),.white(cg_4));
    resource_ui_channel b_table(.clk(video_clk),.src(rgb_2[7:0]),.mode(palette_mode),
        .white_src(solid_3 ? tone_3:bb_3),.alpha(white_alpha),.background(bb_3),.white(cb_4));
    reg [1:0] palette_valid;
    always @(posedge video_clk or posedge rst)
        if(rst) palette_valid<=0;else palette_valid<={palette_valid[0],1'b1};
''' + s[b:]
    s = s.replace('br_3<=0;bg_3<=0;bb_3<=0;cr_4<=0;cg_4<=0;cb_4<=0;', '')
    s = re.sub(r'            br_3<=blend_sum.*?;bb_3<=blend_sum.*?;\n', '', s)
    s = '\n'.join(l for l in s.splitlines() if not re.match(r'\s*c[rgb]_4<=solid_3', l)) + '\n'
    s = s.replace('pix_out<={cr_4[9:2],cg_4[9:2],cb_4[9:2]};', "pix_out<=palette_valid[1] ? {cr_4,cg_4,cb_4}:24'd0;")
    bg = [0] * 2048
    for mode, tint in enumerate([0,20,66,106,58,18,62]):
        for n in range(128):
            def value(v):
                return v if mode == 0 else (3*v+tint)//4 if mode == 1 else (v+tint)//2
            bg[mode*128+n] = value(2*n) | (value(2*n+1) << 8)
    white = [0] * 512
    for alpha in range(4):
        for n in range(128):
            def value(v):
                return [v,(3*v+255)//4,(v+765)//4,255][alpha]
            white[alpha*128+n] = value(2*n) | (value(2*n+1) << 8)
    channel = '''module resource_ui_channel(input wire clk,input wire [7:0] src,white_src,
 input wire [2:0] mode,input wire [1:0] alpha,output wire [7:0] background,white);
 wire [15:0] qa,qb;reg a_bit,b_bit;
 always @(posedge clk) begin a_bit<=src[0];b_bit<=white_src[0];end
 resource_ui_background u_bg(.clk(clk),.addr({1'b0,mode,src[7:1]}),.addr_b(11'd0),.q(qa),.q_b());
 resource_ui_white u_white(.clk(clk),.addr({alpha,white_src[7:1]}),.addr_b(9'd0),.q(qb),.q_b());
 assign background=a_bit ? qa[15:8]:qa[7:0];assign white=b_bit ? qb[15:8]:qb[7:0];
endmodule
'''
    (destination / 'rtl/ui/ui_text_overlay.v').write_text(
        s + channel + rom('resource_ui_background', bg, 11) + rom('resource_ui_white', white, 9), encoding='utf-8')

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--source', type=Path, default=OUT/'base/render')
    p.add_argument('--destination', type=Path, required=True)
    args = p.parse_args()
    generate(args.source, args.destination)
