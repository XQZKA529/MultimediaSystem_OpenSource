"""Pack twelve 10x14 audio glyphs and the blue glass palette into one BRAM9K.

Four adjacent coverage pixels occupy one byte. Twelve 16x16 padded glyphs
use addresses 0..767; all 256 blue values use 768..1023 on the second port.
Existing gx/gy/character registers select the coverage after the same read
edge. Outside the original glyph bounds alpha stays zero; generic SCALE
keeps its original fallback. No output/handshake stage is added.
"""
import argparse,re,json
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import byte_dual_rom9
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/ui/osd_paint_text.v';s=f.read_text(encoding='utf-8-sig')
entries={int(i):int(v,16) for i,v in re.findall(r"12'd(\d+): audio_font_row = 20'h([0-9a-fA-F]+);",
    (a.source/'rtl/ui/font_audio_rows.vh').read_text(encoding='utf-8-sig'))}
codes=sorted({i>>5 for i in entries});assert codes==list(range(47,59))
words=[0]*1024
for n,code in enumerate(codes):
 for row in range(16):
  value=entries.get(code*32+row,0)
  for group in range(4):words[n*64+row*4+group]=(value>>(group*8))&255
for src in range(256):words[768+src]=(src+(src>>1)+13)>>2
start=s.index('     function [3:0] glyph_index;');end=s.index('    end else begin: generic_audio_font',start)
s=s[:start]+'''     function [3:0] glyph_index;input [6:0] code;begin
       glyph_index=(code>=47 && code<=58) ? code-7'd47:4'd12;
     end endfunction
     wire [7:0] glyph_word,shared_blue_word;
     resource_audio_compact9 u_font(.clk(clk),
       .a({glyph_index(ch_a[6:0]),ly[3:0],rem_x_a[3:2]}),
       .b({2'b11,(SHARED_GLASS ? glass_blue_src:8'd0)}),.qa(glyph_word),.qb(shared_blue_word));
     assign glass_blue_rgb=shared_blue_word;
     // Unsupported characters use zero coverage, independently of palette
     // reads in the unused glyph-index range. Full 8-bit ink choice is kept.
     assign coverage=(ch_r[6:0]>=47 && ch_r[6:0]<=58) ?
       glyph_word[{gx_r[1:0],1'b0} +:2]:2'd0;
'''+s[end:]
start=s.index('\nmodule resource_audio_shared_rom(')
s=s[:start]+byte_dual_rom9('resource_audio_compact9',words)
f.write_text(s,encoding='utf-8')
(a.destination.parent/'audio-compact9.json').write_text(json.dumps(dict(
    codes=codes,glyph_bytes=768,palette_bytes=256,added_latency=0,
    native_bram9k=1,native_bram32k_saved=1),indent=2),encoding='utf-8')
