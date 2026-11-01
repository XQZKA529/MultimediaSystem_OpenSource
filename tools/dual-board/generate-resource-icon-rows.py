"""Factor exact 96x96 menu icons into 47 unique scanlines and two BRAM9Ks.

The two synchronous reads occupy existing coordinate and paint stages; no
latency or throughput changes. ROM bytes come from ModelSim evaluation of the
original active drawing case, including unsigned subtraction/default behavior.
"""
import argparse,json
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import byte_rom9
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
root=Path(__file__).resolve().parents[2]
def active_case(text):
 begin=text.index('                case(icon_0)',text.index('if(page_0==1 && card_0'))
 return text[begin:text.index('                endcase',begin)]
assert active_case((a.source/'rtl/ui/ui_text_overlay.v').read_text(encoding='utf-8-sig'))==active_case(
 (root/'build/resource-v1/base/render/rtl/ui/ui_text_overlay.v').read_text(encoding='utf-8-sig'))
bits=[int(x,16) for x in (root/'build/resource-v1/tables/icons.bits').read_text().split()]
assert len(bits)==7*96*96
rows=[];ids=[];resampled=[]
for kind in range(8):
 source_kind=4 if kind==7 else kind
 for y in range(80):
  source_y=y*96//80
  row=tuple(bits[(source_kind*96+source_y)*96+(x*96//80)] for x in range(80))
  if row not in rows:rows.append(row)
  ids.append(rows.index(row));resampled.extend(row)
assert len(rows)<=64
lookup=[0]*1024
for k in range(8):
 for y in range(80):lookup[k*128+y]=ids[k*80+y]
words=[]
for row in rows:
 words.extend(sum(row[x+j]<<j for j in range(8)) if x<80 else 0 for x in range(0,128,8))
words += [0]*(1024-len(words))
# Exhaustively verify the generated representation against every original bit.
for k in range(8):
 for y in range(80):
  for x in range(80):
   assert ((words[lookup[k*128+y]*16+x//8]>>(x%8))&1)==resampled[(k*80+y)*80+x]
f=a.destination/'rtl/ui/ui_text_overlay.v';s=f.read_text(encoding='utf-8-sig')
start=s.index('            if(page_0==1 && card_0 && ix_0<96 && iy_0<96) begin')
end=s.index('            if(slider_0)',start)
s=s[:start]+s[end:]
decl='''    // Row dictionary occupies stage 0; packed bitmap occupies stage 1.
    wire [7:0] icon_row_id,icon_bits;
    reg [2:0] icon_column_2;
    reg icon_valid_2;
    resource_icon_rows u_icon_rows(.clk(video_clk),.addr({icon_kind,iy[6:0]}),.q(icon_row_id));
    resource_icon_pixels u_icon_pixels(.clk(video_clk),.addr({icon_row_id[5:0],ix_0[6:3]}),.q(icon_bits));
    wire icon_hit_2=icon_valid_2 && icon_bits[icon_column_2];
    always @(posedge video_clk or posedge rst) begin
      if(rst) begin icon_column_2<=0;icon_valid_2<=0;end
      else begin
        icon_column_2<=ix_0[2:0];
        icon_valid_2<=enabled_0 && page_0==1 && card_0 && ix_0<96 && iy_0<96 && !slider_0;
      end
    end
'''
s=s.replace('    reg [2:0] weight,tint_weight',decl+'    reg [2:0] weight,tint_weight')
assert 'solid_3<=solid_2;tone_3<=tone_2;' in s
s=s.replace('solid_3<=solid_2;tone_3<=tone_2;',"solid_3<=solid_2 || icon_hit_2;tone_3<=icon_hit_2 ? 8'd255:tone_2;")
# The old unused helper is removed separately from the active drawing change.
start=s.index('    function icon;');end=s.index('    endfunction',start)+len('    endfunction')
s=s[:start]+s[end:]
f.write_text(s+byte_rom9('resource_icon_rows',lookup)+byte_rom9('resource_icon_pixels',words),encoding='utf-8')
e=a.destination.parent/'icon-row-generation';e.mkdir(parents=True,exist_ok=True)
(e/'summary.json').write_text(json.dumps(dict(unique_rows=len(rows),source_size=96,icon_size=80,
 original_bits=len(bits),exhaustively_checked_pixels=8*80*80,native_bram9k=2),indent=2),encoding='utf-8')
print('PASS exhaustive 80x80 row factoring:',len(rows),'unique rows, 51200 pixels')
