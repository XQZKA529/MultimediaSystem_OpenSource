"""Fit the shared AA font in one ROM, then use the freed ROM for audio glyphs.

Central columns 1..8 occupy one 2048x16 dual-port ROM. Only 23 nonzero
outer-column rows need a small exact case decoder. Both independent reads
retain the original one-clock interface. Audio glyph coverage absorbs its
existing character/coordinate register stage; no pixel latency is added.
"""
import argparse,re,json
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import rom
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/ui/font_rom.v';old=f.read_text(encoding='utf-8-sig')
w={int(i):int(v,16) for i,v in re.findall(r"mem\[(\d+)\]=16'h([0-9a-fA-F]+);",old)}
assert len(w)==4096
middle=[];edges={}
for c in range(128):
 for y in range(16):
  pixels=[(w[c*32+y*2+x//8]>>(2*(x%8)))&3 for x in range(10)]
  middle.append(sum(pixels[x]<<(2*(x-1)) for x in range(1,9)))
  if pixels[0] or pixels[9]:edges[c*16+y]=pixels[0]|(pixels[9]<<2)
assert len(edges)==23
s='''// Exact 10x14 coverage: central eight columns in RAM, sparse edges in LUTs.
module font_rom #(parameter SECOND_PORT=0)(input wire clk,input wire [6:0] char_code,
 input wire [3:0] gx,gy,output wire [1:0] alpha,
 input wire [6:0] char_code_b,input wire [3:0] gx_b,gy_b,output wire [1:0] alpha_b);
 function [3:0] edge_row;
  input [10:0] addr;begin case(addr)
'''
s+=''.join(f"11'd{k}:edge_row=4'h{v:x};\n" for k,v in edges.items())
s+='''default:edge_row=0;endcase end endfunction
 wire [15:0] qa,qb;reg [3:0] xa,xb,ea,eb;reg va,vb;
 always @(posedge clk)begin
  xa<=gx;xb<=gx_b;ea<=edge_row({char_code,gy});eb<=edge_row({char_code_b,gy_b});
  va<=char_code>=32 && char_code<=126 && gx<10 && gy<14;
  vb<=SECOND_PORT && char_code_b>=32 && char_code_b<=126 && gx_b<10 && gy_b<14;
 end
 wire [2:0] pa=xa[2:0]-3'd1,pb=xb[2:0]-3'd1;
 resource_font_middle u_font(.clk(clk),.addr({char_code,gy}),.addr_b({char_code_b,gy_b}),.q(qa),.q_b(qb));
 assign alpha=!va ? 2'd0:xa==0 ? ea[1:0]:xa==9 ? ea[3:2]:qa[{pa,1'b0} +:2];
 assign alpha_b=!vb ? 2'd0:xb==0 ? eb[1:0]:xb==9 ? eb[3:2]:qb[{pb,1'b0} +:2];
endmodule
'''
f.write_text(s+rom('resource_font_middle',middle,11),encoding='utf-8')
f=a.destination/'rtl/ui/osd_paint_text.v';s=f.read_text(encoding='utf-8-sig')
rows=(a.destination/'rtl/ui/font_audio_rows.vh').read_text(encoding='utf-8-sig')
entries={int(i):int(v,16) for i,v in re.findall(r"12'd(\d+): audio_font_row = 20'h([0-9a-fA-F]+);",rows)}
codes=sorted({i>>5 for i in entries});assert len(codes)<16
words=[0]*1024
for n,c in enumerate(codes,1):
 for y in range(32):
  value=entries.get(c*32+y,0)
  for half in range(2):words[n*64+y*2+half]=(value>>(half*16))&65535
logic='''wire [1:0] coverage;
    generate if(SCALE==2)begin: packed_audio_font
     function [3:0] glyph_index;input [6:0] code;begin case(code)
'''
logic+=''.join(f"7'd{c}:glyph_index=4'd{n};\n" for n,c in enumerate(codes,1))
logic+='''default:glyph_index=0;endcase end endfunction
     wire [15:0] glyph_word;
     resource_audio_glyph_rom u_font(.clk(clk),.addr({glyph_index(ch_a[6:0]),ly[4:0],rem_x_a[3]}),
       .addr_b(10'd0),.q(glyph_word),.q_b());
     assign coverage=glyph_word[{gx_r[2:0],1'b0} +:2];
    end else begin: generic_audio_font
     wire [19:0] coverage_row=audio_font_row(ch_r[6:0],gy_r[4:0]);
     assign coverage=coverage_row[gx_r*2 +:2];
    end endgenerate'''
old='wire [19:0] coverage_row=audio_font_row(ch_r[6:0],gy_r[4:0]);'
assert s.count(old)==1;s=s.replace(old,logic).replace('coverage_row[gx_r*2 +: 2]', 'coverage')
f.write_text(s+rom('resource_audio_glyph_rom',words,10),encoding='utf-8')
(a.destination.parent/'font-strips-layout.json').write_text(json.dumps(dict(outer_rows=len(edges),audio_codes=codes,shared_rows=len(middle),audio_words=len(words)),indent=2),encoding='utf-8')
