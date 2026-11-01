"""Compare production CLOCK formatting/paint with frozen original RTL per cycle.

Two complete 720p scans use randomized pixels/coverage and independently chosen
frame-stable calendar fields. Font request/address, sync and RGB all match.
This isolates formatter/paint logic from the separately verified font atlas.
"""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
a=p.parse_args();b=a.candidate.resolve();root=Path(__file__).resolve().parents[2]
w=b.parent/'clock-production-equivalence';w.mkdir(parents=True,exist_ok=True)
ref=w/'reference.v';ref.write_text((root/'build/resource-v1/base/render/rtl/ui/clock_overlay.v').read_text(
 encoding='utf-8-sig').replace('module clock_overlay(','module clock_reference('),encoding='utf-8')
tb='''module tb;
reg clk=0,rst=1,hs=0,vs=0,de=0,editing=0;always #5 clk=~clk;
reg [23:0] rgb=0;reg [47:0] live=48'h261014123456,draft=48'h000229235959;
reg [2:0] focus=0;reg [1:0] alpha=0;integer frame,y,x,n,checks=0;
'''
ports='''.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb_in(rgb),
.live_digits(live),.draft_digits(draft),.focus(focus),.editing(editing),.font_alpha(alpha),
'''
for role,module,param in [('ref','clock_reference',''),('dut','clock_overlay','#(.FRAME_DIGITS(1))')]:
 tb+=f'''wire h_{role},v_{role},d_{role},request_{role};wire [23:0] rgb_{role};
wire [6:0] char_{role};wire [3:0] x_{role},y_{role};
{module} {param} {role}('''+ports+f'''.hs_out(h_{role}),.vs_out(v_{role}),.de_out(d_{role}),.rgb_out(rgb_{role}),
.font_char(char_{role}),.font_x(x_{role}),.font_y(y_{role}),.font_request(request_{role}));
'''
tb+='''always @(negedge clk) if(!rst) begin
 if({h_ref,v_ref,d_ref,rgb_ref,char_ref,x_ref,y_ref,request_ref}!==
    {h_dut,v_dut,d_dut,rgb_dut,char_dut,x_dut,y_dut,request_dut})
 $fatal(1,"Production CLOCK differs frame=%0d y=%0d x=%0d char=%h/%h rgb=%h/%h",frame,y,x,char_ref,char_dut,rgb_ref,rgb_dut);
 checks=checks+1;
end
initial begin
repeat(4)@(negedge clk);rst=0;
for(frame=0;frame<2;frame=frame+1) begin
 de=0;vs=1;editing=frame!=0;focus=2;
 if(frame!=0)begin live={$random,$random};draft={$random,$random};end
 repeat(8)@(negedge clk);vs=0;
 for(y=0;y<720;y=y+1) begin
  de=1;hs=0;
  for(x=0;x<1280;x=x+1)begin rgb=$random;alpha=$random;@(negedge clk);end
  de=0;hs=1;repeat(8)@(negedge clk);hs=0;
 end
end
de=0;repeat(8)@(negedge clk);
$display("PASS production FRAME_DIGITS=1 vs frozen original: %0d exact cycles, two 720p frames, random RGB/coverage/calendar",checks);$finish;
end endmodule
'''
(w/'tb.v').write_text(tb,encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[ref,b/'rtl/ui/clock_overlay.v',w/'tb.v'],
 includes=[b/'rtl',b/'rtl/ui'],native=True,defines=[] if native else ['DB_BEHAVIORAL_RAM'])
