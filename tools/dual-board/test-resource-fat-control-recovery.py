"""Inject every unused grouped FAT code and compare recovery/public outputs."""
import argparse,json,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);p.add_argument('--tag',default='fat-control-recovery');a=p.parse_args();b=a.candidate.resolve();r=a.reference.resolve()
w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
source=(r/'rtl/fat/fat32_ro.v').read_text(encoding='utf-8-sig')
ref=w/'reference.v';ref.write_text(source.replace('module fat32_ro #(', 'module reference_fat #(').replace('resource_fat_dsp_hold','reference_fat_dsp_hold'),encoding='utf-8')
header=re.sub(r'//[^\n]*','',source[:source.index('\n);')])
ports=re.findall(r'\b(input|output)\s+(?:wire|reg)\s*(\[[^]]+\])?\s*(\w+)',header)
mapping=json.loads((b.parent/'fat-control-map.json').read_text());used={entry['encoded'] for entry in mapping.values()}
tb='module tb;\nreg clk=0,rst=1,clock_enable=0;always #5 if(clock_enable)clk=~clk;\n'
for module,instance in [('fat32_ro','dut'),('reference_fat','ref')]:
 tb+=module+' '+instance+'('+','.join(f'.{name}({name if name in ("clk","rst") else "0"})' if direction=='input' else f'.{name}()' for direction,width,name in ports)+');\n'
for direction,width,name in ports:
 if direction=='output':tb+=f'wire {width or ""} observed_{name}=dut.{name},expected_{name}=ref.{name};\n'
tb+='integer checks=0;\ninitial begin\n'
for entry in mapping.values():
 tb+=f"dut.control_state=7'd{entry['encoded']};#1;if(observed_dbg_fat_state!==8'd{entry['diagnostic']})$fatal(1,\"legal diagnostic decode differs\");\n"
tb+='clock_enable=1;repeat(5)@(negedge clk);rst=0;repeat(3)@(negedge clk);\n'
for code in sorted(set(range(128))-used):
 tb+=f"dut.control_state=7'd{code};ref.state_encoded=7'd127;\n@(posedge clk);#1;\n"
 for direction,width,name in ports:
  if direction=='output':tb+=f'if(observed_{name}!==expected_{name})$fatal(1,"illegal code {code} recovery differs {name}");\n'
 tb+='if(observed_dbg_fat_state!==0)$fatal(1,"illegal control code did not recover to IDLE");checks=checks+1;repeat(2)@(negedge clk);\n'
tb+='$display("PASS all 72 legal diagnostic codes and %d unused control codes recover in the original one clock with every public output matching",checks);$finish;end endmodule\n'
f=w/'tb.v';f.write_text(tb,encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[ref,b/'rtl/fat/fat32_ro.v',f],includes=[b/'rtl',b/'rtl/pkg',b/'rtl/fat'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
