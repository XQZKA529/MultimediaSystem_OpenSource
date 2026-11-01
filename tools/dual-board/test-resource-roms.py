from pathlib import Path
import re
from resource_sim import simulate

ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'build/resource-v1'
base=OUT/'base/render';work=OUT/'rom-equivalence';work.mkdir(parents=True,exist_ok=True)
ui=(base/'rtl/ui/ui_text_overlay.v').read_text(encoding='utf-8-sig')
em=(base/'rtl/emergency/emergency_overlay.v').read_text(encoding='utf-8-sig')
a=ui.index('                case(icon_0)',ui.index('if(page_0==1 && card_0'));b=ui.index('                endcase',a)+len('                endcase')
icon_case=ui[a:b].replace('begin solid=1;tone=255;end','icon_bit=1;')
glyph=re.search(r'    function \[4:0\] glyph_row;.*?    endfunction',em,re.S)[0]
cell=re.search(r'    function \[4:0\] cell_index;.*?    endfunction',ui,re.S)[0]
clock=(base/'rtl/ui/clock_overlay.v').read_text();position=re.search(r'    function \[8:0\] character_position;.*?    endfunction',clock,re.S)[0]
tables=[]
for candidate,rel,module in [('render_icons','ui/ui_text_overlay.v','resource_icon_rom'),('render_coord','ui/ui_text_overlay.v','resource_ui_coord_rom'),('render_glyph','emergency/emergency_overlay.v','resource_emergency_rom')]:
    s=(OUT/candidate/'render/rtl'/rel).read_text()
    table=work/(module+'.v');table.write_text(s[s.index('// Generated exact table.'):]);tables.append(table)
tb=work/'tb_roms.v';tb.write_text('''module tb_roms;
reg clk=0;always #5 clk=~clk;
reg [11:0] ia=0;reg [10:0] ga=0;reg [8:0] ca=0;
wire [15:0] iq,gq,cq;
resource_icon_rom i(.clk(clk),.addr(ia),.q(iq));
resource_emergency_rom g(.clk(clk),.addr(ga),.q(gq));
resource_ui_coord_rom c(.clk(clk),.addr(ca),.q(cq));
function icon_bit;input [2:0] icon_0;input [10:0] ix_0,iy_0;begin icon_bit=0;
'''+icon_case+'\nend endfunction\n'+glyph+'\n'+cell+'\n'+position+'''
integer n,j,k,y,x;reg [15:0] expected;
initial begin
 #100;
 for(n=0;n<4032;n=n+1) begin
  @(negedge clk);ia=n;k=n/576;y=(n%576)/6;x=(n%6)*16;expected=0;
  for(j=0;j<16;j=j+1) expected[j]=icon_bit(k,x+j,y);
  @(posedge clk);#1;if(iq!==expected) $fatal(1,"icon %d %h %h",n,iq,expected);
 end
 for(n=0;n<2048;n=n+1) begin
  @(negedge clk);ga=n;expected=glyph_row(n/16,n%16);
  @(posedge clk);#1;if(gq!==expected) $fatal(1,"glyph %d",n);
 end
 for(n=0;n<512;n=n+1) begin
  @(negedge clk);ca=n;expected=character_position(n);
  @(posedge clk);#1;if(cq!==expected || cq[8:4]!==cell_index(n)) $fatal(1,"coordinate %d",n);
 end
 $display("PASS 64512 icon pixels, 2048 glyph rows and all 512 coordinate inputs");$finish;
end endmodule
''')
for native in [False,True]:simulate(work/('native' if native else 'behavioral'),'tb_roms',tables+[tb],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
