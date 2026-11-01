"""Boundaries/random transaction equality; generic invalid-input behavior retained."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);p.add_argument('--tag',default='geometry-width-equivalence')
p.add_argument('--generic-only',action='store_true');p.add_argument('--native',action='store_true');a=p.parse_args();b=a.candidate.resolve()
w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
ref=w/'reference.v';ref.write_text((a.reference/'rtl/image/image_scale_geometry.v').read_text(encoding='utf-8-sig').replace('module image_scale_geometry(', 'module reference_geometry('),encoding='utf-8')
tb='''module tb;
reg clk=0,rst=1,start=0;always #5 clk=~clk;
reg [12:0] sw=1,sh=1;reg [1:0] mode=0;
integer n,j,cycles=0,checks=0;reg [31:0] rng=32'h17ab2e31;
'''
for i,(mw,mh,bits) in enumerate([(1,1,1),(32,18,6),(1280,720,11),(65535,65535,16)]):
 tb+=f'reg [15:0] dw{i}=1,dh{i}=1;\n'
 for role,module,param in [('ref','reference_geometry',''),('dut','image_scale_geometry','' if a.generic_only else f'#(.DIM_BITS({bits}))')]:
  tb+=f'''wire done_{role}{i},ok_{role}{i};wire [15:0] w_{role}{i},h_{role}{i},l_{role}{i},b_{role}{i};
{module} {param} {role}{i}(.clk(clk),.rst(rst),.start(start),.src_w(sw),.src_h(sh),.dst_w(dw{i}),.dst_h(dh{i}),.mode(mode),
.done(done_{role}{i}),.ok(ok_{role}{i}),.scaled_w(w_{role}{i}),.scaled_h(h_{role}{i}),.left(l_{role}{i}),.bottom(b_{role}{i}));
'''
 tb+=f'''always @(negedge clk)if(!rst)begin
 if({{done_ref{i},ok_ref{i}}}!=={{done_dut{i},ok_dut{i}}})$fatal(1,"geometry handshake {i}");
 if(done_ref{i})begin
  if({{w_ref{i},h_ref{i},l_ref{i},b_ref{i}}}!=={{w_dut{i},h_dut{i},l_dut{i},b_dut{i}}})$fatal(1,"geometry result {i} transaction %d",n);
  checks=checks+1;
 end
 if(done_ref{i} && ok_ref{i} && (w_dut{i}>dw{i} || h_dut{i}>dh{i} || l_dut{i}+w_dut{i}>dw{i} || b_dut{i}+h_dut{i}>dh{i}))
  $fatal(1,"CONTAIN range proof {i}");
end
'''
tb+='''initial begin
repeat(5)@(negedge clk);rst=0;
for(n=0;n<100000;n=n+1)begin
 @(negedge clk);#1;rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};sw=rng[12:0];sh=rng[25:13];mode=n%23==0 ? 3:0;
 if(n%7==0)sw=1;if(n%11==0)sh=8191;if(n%13==0)sw=8191;if(n%17==0)sh=1;
'''
for i,(mw,mh,bits) in enumerate([(1,1,1),(32,18,6),(1280,720,11),(65535,65535,16)]):
 tb+=f'dw{i}=1+(rng%{mw});dh{i}=1+((rng>>8)%{mh});if(n%19==0)begin dw{i}={mw};dh{i}={mh};end\n'
tb+=''' if(n%59==0)begin dw0=0;dw1=0;dw2=0;dw3=0;end
 if(n%61==0)begin dh0=0;dh1=0;dh2=0;dh3=0;end
 start=1;@(negedge clk);start=0;
 cycles=0;while(!done_dut0)begin @(negedge clk);cycles=cycles+1;if(cycles>50)$fatal(1,"deadline changed");end
 if(n%101==0)begin rst=1;#2;rst=0;end
end
$display("PASS 400000 geometry transactions: exact valid dimensions/padding/latency, 1x1 to 65535 targets, full 13-bit sources, ties, illegal mode/source and generic invalid outputs; %d result checks",checks);$finish;
end endmodule
'''
tbfile=w/'tb.v';tbfile.write_text(tb,encoding='utf-8')
simulate(w/'simulation','tb',[ref,b/'rtl/image/image_scale_geometry.v',tbfile],includes=[b/'rtl/image',b/'rtl'],native=a.native,defines=[] if a.native else ['DB_BEHAVIORAL_RAM'])
