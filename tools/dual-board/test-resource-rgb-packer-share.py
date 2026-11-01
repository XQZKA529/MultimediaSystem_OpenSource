"""Exact packer outputs for full 720p, counter wrap, small/illegal parameters."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);a=p.parse_args();b=a.candidate.resolve();r=a.reference.resolve()
w=b.parent/'rgb-packer-share-equivalence';w.mkdir(parents=True,exist_ok=True)
ref=w/'reference.v';ref.write_text((r/'rtl/framebuffer/rgb888_word_packer.v').read_text(encoding='utf-8-sig').replace(
    'module rgb888_word_packer #(', 'module reference_packer #('),encoding='utf-8')
tb='''module tb;
reg clk=0,rst=1,start=0,valid=0;always #5 clk=~clk;
reg [23:0] rgb=0;integer n,checks=0;
'''
for i,limit in enumerate([0,1,2,3,4,5,1280,921600,1048576,-1]):
 for module,name in [('rgb888_word_packer',f'd{i}'),('reference_packer',f'r{i}')]:
  tb+=f'wire [31:0] {name}_data;wire {name}_valid,{name}_align,{name}_over;\n'
  tb+=f'''{module} #(.FRAME_PIXELS({limit})) {name}(.clk(clk),.rst(rst),.frame_start(start),.pixel_valid(valid),.pixel_rgb(rgb),
    .word_valid({name}_valid),.word_data({name}_data),.alignment_error({name}_align),.overflow_error({name}_over));
'''
 tb+=f'''always @(posedge clk)begin #1;
 if({{d{i}_data,d{i}_valid,d{i}_align,d{i}_over}}!=={{r{i}_data,r{i}_valid,r{i}_align,r{i}_over}})
  $fatal(1,"RGB888 packer exact output mismatch parameter {limit} cycle %0d",n);
end
'''
tb+='''always @(posedge clk)checks=checks+10;
initial begin
repeat(5)@(negedge clk);#1;rst=0;start=1;
@(negedge clk);#1;start=0;valid=1;
// Includes the complete 921600-pixel frame and the legacy 20-bit wrap.
for(n=0;n<1048600;n=n+1)begin @(negedge clk);#1;rgb=$random;end
for(n=0;n<300000;n=n+1)begin
 @(negedge clk);#1;rgb=$random;valid=$random;start=($random&31)==0;
 if(n%1237==0)begin rst=1;#2;rst=0;end
end
@(negedge clk);
$display("PASS %0d exact RGB888 packer checks: ten parameter sets, full 720p, 20-bit wrap, stalls, incomplete starts, overflow and short async resets",checks);$finish;
end endmodule
'''
test=w/'tb.v';test.write_text(tb,encoding='utf-8')
simulate(w/'behavioral','tb',[ref,b/'rtl/framebuffer/rgb888_word_packer.v',test],includes=[b/'rtl',b/'rtl/pkg'])
