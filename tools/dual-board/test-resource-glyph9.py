"""All 4096 original glyph addresses and exact emergency public-cycle comparison."""
import argparse,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True);p.add_argument('--tag',default='glyph9-equivalence')
p.add_argument('--paired-rows',action='store_true');p.add_argument('--frame-timestamps',action='store_true')
p.add_argument('--shape-only',action='store_true');p.add_argument('--all-coordinates',action='store_true');a=p.parse_args()
b=a.candidate.resolve();root=Path(__file__).resolve().parents[2];w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
original=(root/'build/resource-v1/base/render/rtl/emergency/emergency_overlay.v').read_text(encoding='utf-8-sig')
fun=re.search(r'    function \[4:0\] glyph_row;.*?    endfunction',original,re.S)[0]
ref=w/'reference.v';ref.write_text(re.sub(r'\bmodule emergency_overlay\b','module reference_emergency',original),encoding='utf-8')
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0,rst=1,hs=0,vs=0,de=0,en=0;always #5 clk=~clk;
reg [23:0] rgb=0;reg [2:0] sources=0;reg [8:0] groups=0;reg [143:0] timestamps=0;
wire ah,av,ad,eh,ev,ed;wire [23:0] a,e;
emergency_overlay dut(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb_in(rgb),.enable(en),.sources(sources),.groups(groups),.timestamps(timestamps),.hs_out(ah),.vs_out(av),.de_out(ad),.rgb_out(a));
reference_emergency ref(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb_in(rgb),.enable(en),.sources(sources),.groups(groups),.timestamps(timestamps),.hs_out(eh),.vs_out(ev),.de_out(ed),.rgb_out(e));
reg [11:0] address=0;wire [7:0] row;
resource_emergency_glyph9 u_table(.clk(clk),.addr({address[10:4],address[2:0]}),.q(row));
'''+fun+'''
integer n,x,y,frame,checks=0;
reg [4:0] expected;
always @(posedge clk)begin #1;if(!rst)begin
 if({ah,av,ad,a}!=={eh,ev,ed,e})$fatal(1,"emergency public cycle differs %d %h/%h",checks,a,e);
 checks=checks+1;end end
initial begin
repeat(10)@(negedge clk);rst=0;
for(n=0;n<4096;n=n+1)begin
 address=n;expected=glyph_row(address[11:4],address[3:0]);
 @(posedge clk);#1;
 if((!address[11] && address[3:0]>=2 && address[3:0]<=8 ? row[4:0]:5'd0)!==expected)
  $fatal(1,"glyph address %d",n);
 @(negedge clk);
end
for(frame=0;frame<3;frame=frame+1)begin
 en=1;groups=frame==0 ? 9'h001:frame==1 ? 9'h055:9'h111;
 sources=groups[2:0]|groups[5:3]|groups[8:6];timestamps={48'h990101000000,48'h000229235959,48'h261014153001};
 vs=1;repeat(3)@(negedge clk);vs=0;repeat(2)@(negedge clk);
 for(y=0;y<720;y=y+1)begin
  de=1;for(x=0;x<1280;x=x+1)begin
   rgb={$random};@(negedge clk);
   if(x==650 && y==300)begin groups=0;timestamps=0;en=0;sources=0;end
  end
  de=0;hs=1;@(negedge clk);hs=0;@(negedge clk);
 end
 de=0;repeat(10)@(negedge clk);
 // Async reset clears the validity mask, with ROM contents unchanged.
 rst=1;#2;rst=0;repeat(10)@(negedge clk);
end
$display("PASS all 4096 glyph addresses and %d exact RGB/sync cycles, three complete 720p frames, frame configuration collision and asynchronous reset",checks);$finish;
end
endmodule
''',encoding='utf-8')
s=tb.read_text(encoding='utf-8')
if a.frame_timestamps:
 s=s.replace('emergency_overlay dut(', 'emergency_overlay #(.FRAME_TIMESTAMPS(1)) dut(').replace('reference_emergency ref(', 'reference_emergency #(.FRAME_TIMESTAMPS(1)) ref(')
if a.paired_rows:
 s=s.replace('reg [11:0] address=0;wire [7:0] row;', 'reg [11:0] address=0;wire [15:0] glyph_word;wire [4:0] row=address[0]?glyph_word[9:5]:glyph_word[4:0];')
 s=s.replace('resource_emergency_glyph9 u_table(.clk(clk),.addr({address[10:4],address[2:0]}),.q(row));', "resource_emergency_pair_rom u_table(.clk(clk),.addr(address[11:1]),.addr_b(11'd0),.q(glyph_word),.q_b());")
 s=s.replace("(!address[11] && address[3:0]>=2 && address[3:0]<=8 ? row[4:0]:5'd0)", 'row')
tb.write_text(s,encoding='utf-8')
if a.shape_only:
 s=re.sub(r'reg \[11:0\] address=0;wire.*?\n'+r'resource_emergency_glyph9[^\n]+\n', '',s,flags=re.S)
 s=re.sub(r'for\(n=0;n<4096;n=n\+1\)begin.*?\nend\nfor\(frame=', 'for(frame=',s,flags=re.S)
 s=s.replace('all 4096 glyph addresses and ', '')
if a.all_coordinates:
 # A real input stream drives every wrapping coordinate pair: ordinary
 # arrows, combined arrows/warning, and warning without arrows.
 s=s.replace('frame<3','frame<6').replace('groups=frame==0 ? 9\'h001:frame==1 ? 9\'h055:9\'h111;', "groups=frame==0 ? 9'h001:frame==1 ? 9'h055:frame==2 ? 9'h111:frame==3 ? 9'h003:frame==4 ? 9'h007:9'h004;")
 s=s.replace('y<720','y<(frame<3 ? 720:2048)').replace('x<1280','x<(frame<3 ? 1280:2048)')
 s=s.replace('if(x==650 && y==300)', 'if(frame<3 && x==650 && y==300)')
 s=s.replace('three complete 720p frames,', 'three complete 720p and three exhaustive 2048x2048 coordinate frames,')
tb.write_text(s,encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[ref,b/'rtl/emergency/emergency_overlay.v',tb],
  defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
