"""Exercise full-width active hop-counter updates at arithmetic boundaries.

This supplements real FAT transaction mirrors with state injection: no shortened
counter range, no simulation millions of sectors to reach overflow boundaries.
"""
import argparse
from pathlib import Path
import re
from resource_sim import simulate

p=argparse.ArgumentParser()
p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True)
a=p.parse_args();b=a.candidate.resolve();r=a.reference.resolve()
w=b.parent/'fat-hop-boundary-equivalence';w.mkdir(parents=True,exist_ok=True)
original=(r/'rtl/fat/fat32_ro.v').read_text(encoding='utf-8-sig')
ref=w/'reference.v';ref.write_text(original.replace('module fat32_ro #(', 'module reference_fat #(').replace('resource_fat_dsp_hold','reference_fat_dsp_hold'),encoding='utf-8')
header=re.sub(r'//[^\n]*','',original[:original.index('\n);')])
ports=re.findall(r'\b(input|output)\s+(?:wire|reg)\s*(\[[^]]+\])?\s*(\w+)',header)
tb='module tb;reg clk=0,rst=1;always #5 clk=~clk;integer n;reg [31:0] v,rng=32\'h938acf21;\n'
for module,inst in [('fat32_ro','dut'),('reference_fat','golden')]:
    tb+=module+' '+inst+'('+','.join(f'.{name}({name if name in ("clk","rst") else "0"})' if direction=='input' else f'.{name}()' for direction,width,name in ports)+');\n'
for direction,width,name in ports:
    if direction=='output':tb+=f'wire {width or ""} actual_{name}=dut.{name},expected_{name}=golden.{name};\n'
tb+='''initial begin repeat(5)@(negedge clk);rst=0;repeat(3)@(negedge clk);
for(n=0;n<100000;n=n+1)begin
 @(negedge clk);rng=rng*32'd1664525+32'd1013904223;
 case(n%16)
  0:v=0;1:v=1;2:v=32'h000ffffe;3:v=32'h000fffff;
  4:v=32'h00100000;5:v=32'h00fffffe;6:v=32'h00ffffff;
  7:v=32'h01000000;8:v=32'h0fffffef;9:v=32'h0ffffff0;
  10:v=32'hfffffffe;11:v=32'hffffffff;default:v=rng;
 endcase
'''
for inst in ('dut','golden'):
    tb+=f''' {inst}.active_op=1+n%3;
 {inst}.fat_next_eoc=0;{inst}.fat_next_valid=1;{inst}.fat_next_cycle=0;
 {inst}.fat_next_cluster=32'h01234567;{inst}.dir_hops_max=0;
 {inst}.cycle_lam_eq_power=0;{inst}.cycle_lam_next=24'd31;
 {inst}.map_next_eoc=0;{inst}.map_next_valid=1;{inst}.map_next_cycle=0;
 {inst}.map_cycle_last=0;{inst}.cycle_lam=24'd42;
 {inst}.walk_hops_next=v[23:0]+24'd1;
 if(n%3==2){inst}.control_state={inst}.S_MAP_FAT_CHK;
 else begin {inst}.control_state={inst}.S_FAT_CHECK;
  {inst}.fat_context=n%3==0 ? {inst}.FAT_FOR_DIR:{inst}.FAT_FOR_FILE;
 end
'''
tb+=''' if(n%3==0)begin dut.walk_hops=v;golden.dir_hops=v;end
 else begin dut.walk_hops={8'd0,v[23:0]};golden.walk_hops=v[23:0];end
 @(posedge clk);#1;
 case(n%3)
  0:if(dut.dir_hops!==golden.dir_hops || dut.dir_hops!==(v+32'd1))$fatal(1,"32-bit DIR carry/wrap differs %h",v);
  1:if(dut.file_hops!==golden.file_hops || dut.file_hops!==(v[23:0]+24'd1))$fatal(1,"24-bit FILE carry/wrap differs %h",v);
  2:if(dut.map_hops!==golden.map_hops || dut.map_hops!==(v[19:0]+20'd1))$fatal(1,"20-bit MAP carry/wrap differs %h",v);
 endcase
'''
for direction,width,name in ports:
    if direction=='output':tb+=f' if(actual_{name}!==expected_{name})$fatal(1,"Hop boundary public output differs {name} at %d",n);\n'
tb+='''end
$display("PASS 100000 active DIR32/FILE24/MAP20 hop updates, carries/wraps/high bits and all public outputs");$finish;
end endmodule
'''
test=w/'tb.v';test.write_text(tb,encoding='utf-8')
for native in (False,True):
    simulate(w/('native' if native else 'behavioral'),'tb',[ref,b/'rtl/fat/fat32_ro.v',test],
             includes=[b/'rtl',b/'rtl/fat',b/'rtl/pkg'],native=native,
             defines=[] if native else ['DB_BEHAVIORAL_RAM'])
