"""Compare complete audio OSD streams against the frozen pre-change module."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);a=p.parse_args();b=a.candidate.resolve();r=a.reference.resolve()
w=b.parent/'audio-overlay-equivalence';w.mkdir(parents=True,exist_ok=True)
ref=w/'reference.v';ref.write_text((r/'rtl/ui/audio_osd_overlay.v').read_text(encoding='utf-8-sig').replace('module audio_osd_overlay #(', 'module reference_audio_overlay #(').replace('osd_paint_text #(', 'reference_audio_text #('),encoding='utf-8')
ref_text=w/'reference_text.v';ref_text.write_text((r/'rtl/ui/osd_paint_text.v').read_text(encoding='utf-8-sig').replace('module osd_paint_text #(', 'module reference_audio_text #('),encoding='utf-8')
tb=w/'tb.v';tb.write_text('''`include "pkg/osd_model_bus.vh"
module tb;
reg clk=0,rst=1,hs=0,vs=0,de=0;always #5 clk=~clk;
reg [23:0] rgb=0;reg [`OSD_M_W-1:0] model=0;
wire ah,av,ad,eh,ev,ed;wire [23:0] a,e;
audio_osd_overlay dut(clk,rst,hs,vs,de,rgb,model,ah,av,ad,a);
reference_audio_overlay ref(clk,rst,hs,vs,de,rgb,model,eh,ev,ed,e);
integer frame,x,y,n,j,checks=0;
always @(posedge clk)begin #1;
 if({ah,av,ad,a}!=={eh,ev,ed,e})$fatal(1,"audio OSD RGB/sync differs cycle=%d rgb=%h/%h",checks,a,e);
 checks=checks+1;
end
initial begin
repeat(5)@(negedge clk);rst=0;
for(frame=0;frame<3;frame=frame+1)begin
 vs=1;repeat(3)@(negedge clk);vs=0;repeat(2)@(negedge clk);
 model={`OSD_M_W{1'b1}};
 for(y=0;y<720;y=y+1)begin
  de=1;for(x=0;x<1280;x=x+1)begin
   rgb=$random;
   // Changes every pixel exercise the existing live-model sampling phase.
   model[`OSD_M_FILLPX]=$random;model[`OSD_M_BEAT]=$random;
   model[`OSD_M_SPEC]=$random;model[`OSD_M_PAUSED]=x[5];model[`OSD_M_BLINK1]=y[4];
   model[`OSD_M_SHOW]=frame==0 ? 1'b1:frame==1 ? x[6]:!y[3];
   for(j=0;j<13;j=j+1)model[12+j*8+:8]=x+y+j;
   @(negedge clk);
  end
  de=0;hs=1;@(negedge clk);hs=0;@(negedge clk);
 end
 rst=1;#2;rst=0;repeat(5)@(negedge clk);
end
for(n=0;n<100000;n=n+1)begin
 rgb=$random;model=$random;hs=$random;vs=(n%2500==0);de=$random;
 @(negedge clk);
end
$display("PASS %d exact audio OSD pixels/sync: three complete 720p frames, live model/palette/font/priority changes, random stream and short async resets",checks);$finish;
end endmodule
''',encoding='utf-8')
files=[ref,ref_text,*[b/'rtl/ui'/name for name in ('audio_osd_overlay.v','osd_paint_text.v','osd_paint_bar.v','osd_paint_anim.v','osd_paint_icon.v')],tb]
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',files,includes=[b/'rtl',b/'rtl/ui'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
