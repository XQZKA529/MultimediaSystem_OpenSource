"""Compare final Text OSD pixels and handshakes against the prior pipeline."""
import argparse
import re
from pathlib import Path

from resource_sim import simulate

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--candidate", type=Path, required=True)
parser.add_argument("--reference", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
board = args.candidate.resolve()
work = args.output.resolve()
work.mkdir(parents=True, exist_ok=True)
reference = (args.reference / "rtl/ui/text_osd_overlay.v").read_text(encoding="utf-8-sig")
names = re.findall(r"\bmodule\s+(\w+)\s*[(#]", reference)
reference = re.sub(r"\b(" + "|".join(map(re.escape, names)) + r")\b",
                   lambda match: "golden_" + match[0], reference)
(work / "reference.v").write_text(reference, encoding="utf-8")
testbench = r'''
`include "pkg/text_osd_model.vh"
module tb;
reg clk=0,rst=1,hs=0,vs=0,de=0,active=1,page=1,diag=0,source=0,reset_banner=0;
reg [23:0] pixel=0;
reg [1:0] coverage=0;
reg [`TEXT_OSD_META_W-1:0] view=0;
wire [23:0] actual,expected;
wire ah,av,ad,eh,ev,ed;
wire [7:0] aa,ea;
wire [6:0] ac,ec;
wire [3:0] ax,ay,ex,ey;
integer checks=0,cycle=0,frame,x,y;
always #5 clk=~clk;
INSTANCE_ACTUAL
INSTANCE_EXPECTED
always @(posedge clk) begin
 #1;
 if({actual,ah,av,ad,aa,ac,ax,ay}!=={expected,eh,ev,ed,ea,ec,ex,ey})
  $fatal(1,"Text blend cycle %0d RGB %h/%h sync/lookup mismatch",cycle,actual,expected);
 checks=checks+1;
end
task drive;
 input h,v,d;
 begin
  @(negedge clk);hs=h;vs=v;de=d;
  cycle=cycle+1;pixel=$random;coverage=cycle[1:0];
  view[`TEXT_OSD_VIEW_FOCUS]=(cycle/127)%30;
 end
endtask
initial begin
 repeat(3) drive(0,0,0);rst=0;
 view[`TEXT_OSD_VIEW_ENABLE]=1;view[`TEXT_OSD_VIEW_LEN]=100;
 for(frame=0;frame<3;frame=frame+1) begin
  active=frame!=1;page=active;source=frame[0];
  repeat(4) drive(0,1,0);drive(0,0,0);
  for(y=0;y<(active ? 160:32);y=y+1) begin
   for(x=0;x<(active ? 400:1280);x=x+1) drive(0,0,1);
   repeat(4) drive(1,0,0);
   if(frame==2 && y==79) begin rst=1;repeat(3) drive(0,0,0);rst=0;end
  end
 end
 active=0;diag=1;repeat(12) drive(0,0,0);
 if(checks<160000)$fatal(1,"Insufficient streaming comparisons");
 $display("PASS Text OSD exact RGB/sync/addresses: %0d cycles, 30 highlights, banner, four alpha levels, warm reset",checks);
 $finish;
end
endmodule
'''
for name, module, prefix in (("INSTANCE_ACTUAL", "text_osd_overlay", "a"),
                             ("INSTANCE_EXPECTED", "golden_text_osd_overlay", "e")):
    pixel = "actual" if prefix == "a" else "expected"
    instance = f'''{module} #(.WIN_X0(2),.WIN_Y0(2),.TEXT_Y(8),.EXTERNAL_FONT(1)) {prefix}(
 .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.pix_in(pixel),
 .ui_active_frame(active),.text_osd_page_frame(page),.diag_show(diag),
 .banner_source(source),.banner_reset(reset_banner),.view(view),
 .text_addr({prefix}a),.text_data({prefix}a ^ 8'h53),
 .hs_out({prefix}h),.vs_out({prefix}v),.de_out({prefix}d),.pix_out({pixel}),
 .font_char({prefix}c),.font_x({prefix}x),.font_y({prefix}y),.font_alpha(coverage));'''
    testbench = testbench.replace(name, instance)
(work / "tb.v").write_text(testbench, encoding="utf-8")
simulate(work / "native", "tb", [board / "rtl/ui/text_osd_overlay.v",
                                 work / "reference.v", work / "tb.v"],
         includes=[board / "rtl", board / "rtl/ui"], native=True)
