"""Exhaust both channel ports against the original independent-channel helper."""
import argparse,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);a=p.parse_args();b=a.candidate.resolve()
w=b.parent/'dual-palette-address-equivalence';w.mkdir(parents=True,exist_ok=True)
original=(a.reference/'rtl/ui/ui_text_overlay.v').read_text(encoding='utf-8-sig')
helper=re.search(r'module resource_ui_channel\b.*?endmodule',original,re.S)[0]
ref=w/'reference.v';ref.write_text(helper.replace('module resource_ui_channel(', 'module reference_channel('),encoding='utf-8')
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0;always #5 clk=~clk;
reg [7:0] sr=0,sg=0,wr=0,wg=0;reg [2:0] mode=0;reg [1:0] alpha=0;
wire [7:0] abr,abg,arr,arg,ebr,ebg,err,erg;
resource_ui_pair dut(.clk(clk),.src_r(sr),.src_g(sg),.white_r(wr),.white_g(wg),.mode(mode),.alpha(alpha),
 .background_r(abr),.background_g(abg),.result_r(arr),.result_g(arg));
reference_channel r(.clk(clk),.src(sr),.white_src(wr),.mode(mode),.alpha(alpha),.background(ebr),.white(err));
reference_channel g(.clk(clk),.src(sg),.white_src(wg),.mode(mode),.alpha(alpha),.background(ebg),.white(erg));
integer n,checks=0;
initial begin
repeat(25)@(negedge clk);
for(n=0;n<48192;n=n+1)begin
 if(n<8192)begin sr=n;sg=255-sr;wr=n;wg=255-wr;mode=n>>8;alpha=n>>11;end
 else begin sr=$random;sg=$random;wr=$random;wg=$random;mode=$random;alpha=$random;end
 @(posedge clk);#1;
 if({abr,abg,arr,arg}!=={ebr,ebg,err,erg})$fatal(1,"dual palette differs %d",n);
 checks=checks+1;@(negedge clk);
end
$display("PASS %d exact R/G background/white reads: all source/mode/coverage addresses on both ports, parity and random independent colors",checks);$finish;
end endmodule
''',encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[b/'rtl/ui/ui_text_overlay.v',ref,tb],
  includes=[b/'rtl',b/'rtl/ui'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
