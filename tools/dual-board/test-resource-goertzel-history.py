"""Full-bit recurrence and exact public-cycle oracle for persistent history RAM."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);a=p.parse_args();b=a.candidate.resolve();r=a.reference.resolve()
w=b.parent/'goertzel-history-equivalence';w.mkdir(parents=True,exist_ok=True)
ref=w/'reference.v';ref.write_text((r/'rtl/fft/audio_fft_osd.v').read_text(encoding='utf-8-sig').replace('module audio_goertzel_osd #(', 'module reference_goertzel #('),encoding='utf-8')
text='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst=1,vs=0,pcm_valid=0,play_run=1,paused=0,restart=0;
reg [23:0] l=0,r=0;integer n,checks=0,writes=0,nonzero=0;reg [3:0] reset_hits=0;
'''
for i,(bands,stw,block,log2b,win) in enumerate([(12,25,256,8,1),(4,25,8,3,0),(12,26,32,5,1)]):
 sw=bands*5;params=f'#(.NBANDS({bands}),.STW({stw}),.BLOCK({block}),.LOG2B({log2b}),.WIN_EN({win}))'
 text+=f'wire [{sw-1}:0] a{i},e{i};\n'
 for module,name,out in [('audio_goertzel_osd',f'd{i}',f'a{i}'),('reference_goertzel',f'r{i}',f'e{i}')]:
  text+=f'{module} {params} {name}(.clk(clk),.rst(rst),.vs(vs),.pcm_valid(pcm_valid),.pcm_left(l),.pcm_right(r),.play_run(play_run),.paused(paused),.stream_restart(restart),.heights({out}));\n'
 for signal,width in [('ph',4),('band',4),('smp_cnt',log2b),('prod_r',stw+16),('s1q',stw),('s2h',stw),('wd1',stw),('wd2',stw)]:
  text+=f'wire [{width-1}:0] a{i}_{signal}=d{i}.{signal},e{i}_{signal}=r{i}.{signal};\n'
 text+=f'''always @(posedge clk)begin #1;if(!rst)begin
  if(a{i}!==e{i})$fatal(1,"public height mismatch config {i} cycle=%d",checks);
  if({{a{i}_ph,a{i}_band,a{i}_smp_cnt,a{i}_prod_r}}!=={{e{i}_ph,e{i}_band,e{i}_smp_cnt,e{i}_prod_r}})
   $fatal(1,"phase/sample/product mismatch config {i} cycle=%d",checks);
 end end
always @(negedge clk)if(!rst)begin
 if((a{i}_ph==3 || a{i}_ph==6) && a{i}_s1q!==e{i}_s1q)
  $fatal(1,"full signed S1 read mismatch config {i} cycle=%d",checks);
 if(a{i}_ph==4 && a{i}_s2h!==e{i}_s2h)
  $fatal(1,"full signed S2 read mismatch config {i} cycle=%d",checks);
 if(a{i}_ph==4 || a{i}_ph==7)begin
  if({{a{i}_wd1,a{i}_wd2}}!=={{e{i}_wd1,e{i}_wd2}})
   $fatal(1,"full signed state write mismatch config {i} cycle=%d",checks);
  writes=writes+1;
 end
end
'''
text+='''always @(posedge clk)begin checks=checks+1;if(a0!=0)nonzero=nonzero+1;end
initial begin
repeat(12)@(negedge clk);rst=0;
for(n=0;n<1000000;n=n+1)begin
 pcm_valid=n%128==0;l=$random;r=$random;vs=n%7919==0;
 if(n%997==0)begin l=24'h7fffff;r=24'h7fffff;end
 if(n%991==0)begin l=24'h800000;r=24'h800000;end
 paused=(n%170000>=90000 && n%170000<90100);
 play_run=!(n%230000>=190000 && n%230000<190123);
 restart=n!=0 && n%120001==0;
 // Reset between read/write phases must retain exactly the original partial
 // per-band state. No cursor/tag is reset independently of its state RAM.
 if(n>500000 && !reset_hits[0] && a0_ph==3)begin reset_hits[0]=1;rst=1;#2;rst=0;end
 else if(n>510000 && !reset_hits[1] && a0_ph==4)begin reset_hits[1]=1;rst=1;#2;rst=0;end
 else if(n>520000 && !reset_hits[2] && a0_ph==6)begin reset_hits[2]=1;rst=1;#2;rst=0;end
 else if(n>530000 && !reset_hits[3] && a0_ph==7)begin reset_hits[3]=1;rst=1;#2;rst=0;end
 else if(n>600000 && n%1879==0)begin rst=1;#2;rst=0;end
 @(negedge clk);
end
if(reset_hits!==4'hf || writes<10000 || nonzero==0)$fatal(1,"missing phase/reset/recurrence/display coverage");
$display("PASS %d exact Goertzel public/phase/product cycles, %d full-width state writes, nonzero display %d cycles; 12/4 bands, window on/off, STW26 fallback, restart/pause/stop and warm resets between G1/G2/M1/M2",checks,writes,nonzero);$finish;
end endmodule
'''
tb=w/'tb.v';tb.write_text(text,encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[ref,b/'rtl/fft/audio_fft_osd.v',tb],includes=[r/'rtl',r/'rtl/fft',r/'rtl/clock'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=True)
