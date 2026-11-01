"""Compare UI snapshot publication, retries and valid stalls cycle by cycle."""
import argparse,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True)
p.add_argument('--tag',default='ui-snapshot-equivalence');a=p.parse_args();b=a.candidate.resolve();r=a.reference.resolve()
w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
s=(r/'rtl/seam/seam_media.v').read_text(encoding='utf-8-sig')
ref=w/'reference.v';ref.write_text(s.replace('module seam_media #(', 'module reference_seam #('),encoding='utf-8')
head=s[s.index(')(\n')+3:s.index('\n);')]
ports=[];direction=width=None
for item in head.split(','):
 m=re.fullmatch(r'\s*(?:(input|output)\s+(?:wire|reg)\s*(\[[^]]+\])?\s*)?(\w+)\s*',item)
 assert m,item
 if m[1]:direction,width=m[1],m[2]
 ports.append((direction,width,m[3]))
tb='''module tb;
reg clk=0,rst=1;always #5 clk=~clk;
reg link_up=1,session_reset=0,ui_wr_en=0,ui_commit_toggle=0,tx_meta_ready=0,tx_ready=0;
reg [8:0] ui_wr_addr=0;reg [7:0] ui_wr_data=0;
reg [4:0] volume_level=20,contrast_level=10;reg [3:0] brightness_level=10,ui_cursor_row=0;
reg [2:0] ui_page=0;reg text_osd_page=0,ui_active=1,ui_cursor_en=1;
integer n,i,checks=0,words=0,stalls=0;reg previous_valid=0,previous_last;
reg [31:0] previous_data;
'''
driven=set(re.findall(r'\b(?:link_up|session_reset|ui_wr_en|ui_commit_toggle|tx_meta_ready|tx_ready|ui_wr_addr|ui_wr_data|volume_level|contrast_level|brightness_level|ui_cursor_row|ui_page|text_osd_page|ui_active|ui_cursor_en)\b',tb))|{'clk','rst'}
for module,name in [('seam_media','dut'),('reference_seam','ref')]:
 tb+=module+' #(.FRAME_WORDS(432)) '+name+'('+','.join(
  f'.{port}({port if port in driven else "32\'d0"})' if direction=='input' else f'.{port}()'
  for direction,width,port in ports)+');\n'
tb+='always @(posedge clk)begin #1;if(!rst)begin checks=checks+1;\n'
for direction,width,name in ports:
 if direction!='output' or name=='tx_data':continue
 tb+=f'if(dut.{name}!==ref.{name})$fatal(1,"snapshot public mismatch {name} cycle %0d",checks);\n'
tb+='''if(dut.tx_valid && dut.tx_data!==ref.tx_data)$fatal(1,"snapshot valid word differs");
end end
// Sample VALID and READY at their actual acceptance edge. Sampling READY on
// the preceding falling edge would miss stimulus changes before this edge.
always @(posedge clk or posedge rst)begin
 if(!rst && link_up && !session_reset)begin
  if(previous_valid && (!dut.tx_valid || {dut.tx_last,dut.tx_data}!=={previous_last,previous_data}))
   $fatal(1,"snapshot data changed during valid backpressure");
  previous_valid=dut.tx_valid && !tx_ready;
  previous_data=dut.tx_data;previous_last=dut.tx_last;
  if(dut.tx_valid && tx_ready)words=words+1;
  if(dut.tx_valid && !tx_ready)stalls=stalls+1;
 end else previous_valid=0;
end
initial begin
repeat(5)@(negedge clk);#1;rst=0;
for(i=0;i<512;i=i+1)begin @(negedge clk);#2;ui_wr_en=1;ui_wr_addr=i;ui_wr_data=i^(i>>2);end
@(negedge clk);#2;ui_wr_en=0;ui_commit_toggle=1;
for(n=0;n<500000;n=n+1)begin
 @(negedge clk);#2;
 tx_meta_ready=($random&3)!=0;tx_ready=($random&3)!=0;
 if(n%6000>=4500 && n%6000<5100)tx_ready=0;
 ui_wr_en=n%997<40;ui_wr_addr=$random;ui_wr_data=$random;
 if(n%997==40)ui_commit_toggle=~ui_commit_toggle;
 if(n%3001==0)begin ui_page=$random;ui_cursor_row=$random;contrast_level=$random;brightness_level=$random;end
 session_reset=n!=0 && n%29011==0;
 link_up=!(n%33011>=32000 && n%33011<32100);
 if(n!=0 && n%61001==0)begin rst=1;#2;rst=0;ui_commit_toggle=~ui_commit_toggle;end
end
if(words<500 || stalls<100)$fatal(1,"missing snapshot transmit/backpressure coverage");
$display("PASS %0d UI snapshot public cycles, %0d words and %0d stalled cycles: all byte lanes, dirty/commit collisions, controls, reconnect and async reset",checks,words,stalls);$finish;
end endmodule
'''
test=w/'tb.v';test.write_text(tb,encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',
  [ref,b/'rtl/seam/seam_media.v',b/'rtl/seam/db_stream_fifo.v',test],
  includes=[b/'rtl',b/'rtl/pkg',b/'rtl/seam',b/'rtl/link'],
  defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=True)
