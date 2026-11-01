"""Exhaust every shared-font address and mirror audio painters across parameters."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);p.add_argument('--shared-glass',action='store_true')
p.add_argument('--tag',default='font-strips-equivalence');a=p.parse_args();b=a.candidate.resolve();r=a.reference.resolve()
w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
ref_font=w/'reference_font.v';ref_font.write_text((r/'rtl/ui/font_rom.v').read_text(encoding='utf-8-sig').replace('module font_rom #(', 'module reference_font #(').replace('resource_padded_font','reference_padded_font'),encoding='utf-8')
ref_audio=w/'reference_audio.v';ref_audio.write_text((r/'rtl/ui/osd_paint_text.v').read_text(encoding='utf-8-sig').replace('module osd_paint_text #(', 'module reference_audio #('),encoding='utf-8')
tb=w/'tb.v';tb.write_text('''`include "pkg/osd_model_bus.vh"
module tb;
reg clk=0,rst=1;always #5 clk=~clk;
reg [6:0] ca=0,cb=0;reg [3:0] xa=0,xb=0,ya=0,yb=0;
wire [1:0] aa,ab,ea,eb;
font_rom #(.SECOND_PORT(1)) f(clk,ca,xa,ya,aa,cb,xb,yb,ab);
reference_font #(.SECOND_PORT(1)) rf(clk,ca,xa,ya,ea,cb,xb,yb,eb);
reg [10:0] lx=0,ly=0;reg [`OSD_TXT_W-1:0] txt=0;
wire [23:0] actual,expected;
genvar g;
generate for(g=0;g<4;g=g+1)begin: painters
 localparam SCALE=g==0 ? 1:g==1 ? 2:g==2 ? 4:2;
 localparam CHARS=g==3 ? 12:13;
 osd_paint_text #(.SCALE(SCALE),.CHARS(CHARS)) u(clk,rst,lx,ly,txt,actual[g*6],actual[g*6+1+:2],actual[g*6+3+:3]);
 reference_audio #(.SCALE(SCALE),.CHARS(CHARS)) v(clk,rst,lx,ly,txt,expected[g*6],expected[g*6+1+:2],expected[g*6+3+:3]);
end endgenerate
integer n,j,checks=0;
always @(posedge clk)begin #1;
 if({aa,ab}!=={ea,eb})$fatal(1,"shared glyph mismatch %d",checks);
 if(actual!==expected)$fatal(1,"audio glyph parameter mismatch %d lx=%d ly=%d",checks,lx,ly);
 checks=checks+1;
end
initial begin
 repeat(5)@(negedge clk);rst=0;
 // Both independent ROM ports cover every character/row/column including
 // invalid ASCII and blank coordinates, in opposite orders.
 for(n=0;n<32768;n=n+1)begin
  ca=n[14:8];ya=n[7:4];xa=n[3:0];
  cb=~ca;yb=~ya;xb=~xa;
  lx=n%2048;ly=n/2048;
  for(j=0;j<13;j=j+1)txt[j*8+:8]=n+j;
  @(negedge clk);
 end
 for(n=0;n<150000;n=n+1)begin
  ca=$random;cb=$random;xa=$random;xb=$random;ya=$random;yb=$random;
  lx=$random;ly=$random;
  for(j=0;j<13;j=j+1)txt[j*8+:8]=$random;
  if(n%5000==0)begin rst=1;#2;rst=0;end
  @(negedge clk);
 end
 $display("PASS %d exact two-port glyph and four parameterized audio painter cycles; full 128x16x16 addresses, random ASCII/coordinates/async resets",checks);$finish;
end
endmodule
''',encoding='utf-8')
if a.shared_glass:
 s=tb.read_text(encoding='utf-8')
 s=s.replace('localparam CHARS=g==3 ? 12:13;', 'localparam CHARS=g==3 ? 12:13;\n wire [7:0] unused_glass;')
 s=s.replace('actual[g*6+3+:3]);', "actual[g*6+3+:3],8'd0,unused_glass);")
 tb.write_text(s,encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[ref_font,ref_audio,b/'rtl/ui/font_rom.v',b/'rtl/ui/osd_paint_text.v',tb],includes=[b/'rtl',b/'rtl/ui'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
