"""Use the audio glyph ROM's unused read port/space for the blue panel table.

Both lookups use video_clk and one synchronous read. Neither port output
feeds the other's address. The new internal painter ports carry only this
independent blue lookup; generic non-default scale keeps exact arithmetic.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import rom
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/ui/osd_paint_text.v';s=f.read_text(encoding='utf-8-sig')
i=s.index('\nmodule resource_audio_glyph_rom(')
words={int(n):int(v,16) for n,v in re.findall(r"mem\[(\d+)\]=16'h([0-9a-fA-F]+);",s[i:])}
assert len(words)==1024
table=[words[n] for n in range(1024)]+[0]*1024
for x in range(256):table[1024+x]=(x+(x>>1)+13)>>2
s=s[:i]
s=s.replace('parameter integer CHARS = `OSD_TXT_CHARS', 'parameter integer CHARS = `OSD_TXT_CHARS,\n    parameter SHARED_GLASS=0')
s,n=re.subn(r'(output reg\s+\[2:0\]\s+ink)\s*\n',r'\1,\n    input wire [7:0] glass_blue_src,output wire [7:0] glass_blue_rgb\n',s)
assert n==1
s=s.replace('wire [15:0] glyph_word;', 'wire [15:0] glyph_word,shared_blue_word;')
s=s.replace('resource_audio_glyph_rom u_font', 'resource_audio_shared_rom u_font')
s=s.replace('.addr({glyph_index(ch_a[6:0]),ly[4:0],rem_x_a[3]})', ".addr({1'b0,glyph_index(ch_a[6:0]),ly[4:0],rem_x_a[3]})")
s=s.replace(".addr_b(10'd0),.q(glyph_word),.q_b());", ".addr_b(SHARED_GLASS ? {3'b100,glass_blue_src}:11'd1024),.q(glyph_word),.q_b(shared_blue_word));\n     assign glass_blue_rgb=shared_blue_word[7:0];")
s=s.replace('end else begin: generic_audio_font', '''end else begin: generic_audio_font
     wire [7:0] blue_src=SHARED_GLASS ? glass_blue_src:8'd0;
     wire [9:0] blue_mix={2'd0,blue_src}+({2'd0,blue_src}>>1)+10'd13;
     assign glass_blue_rgb=blue_mix[9:2];''')
assert 'assign glass_blue_rgb=shared_blue_word[7:0];' in s
f.write_text(s+rom('resource_audio_shared_rom',table,11),encoding='utf-8')
f=a.destination/'rtl/ui/audio_osd_overlay.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('    reg [23:0] pix_d1;', '')
s=s.replace('    osd_paint_text #(', '    reg [23:0] pix_d1;\n    wire [7:0] glass_b;\n    osd_paint_text #(')
s=s.replace('.SCALE ( TXT_SCALE )', '.SCALE ( TXT_SCALE ),.SHARED_GLASS(1)')
old='.alpha(txt_alpha)';assert s.count(old)==1
s=s.replace(old,'.alpha(txt_alpha),.glass_blue_src(pix_d1[7:0]),.glass_blue_rgb(glass_b)')
s=s.replace('wire [15:0] glass_r,glass_g,glass_b;', 'wire [15:0] glass_r,glass_g;')
s,n=re.subn(r'    resource_audio_glass_b u_glass_b\([^;]+;\n','',s);assert n==1
i=s.index('\nmodule resource_audio_glass_b(');s=s[:i]
f.write_text(s,encoding='utf-8')
