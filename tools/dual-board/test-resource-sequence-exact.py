"""Mirror real link traffic into the prior RTL, comparing every public output/state."""
import argparse,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);p.add_argument('--tag',default='sequence-exact');a=p.parse_args()
for board in ('media','render'):
 b=a.candidate/board;work=a.candidate/a.tag/board;work.mkdir(parents=True,exist_ok=True)
 original=(a.reference/board/'rtl/link/db_link.v').read_text(encoding='utf-8-sig')
 ref=work/'reference.v';ref.write_text(original.replace('module db_link #(', 'module reference_link #('),encoding='utf-8')
 header=re.sub(r'//[^\n]*','',original[:original.index('\n);')])
 identifier=r'(?!(?:input|output|wire|reg)\b)[A-Za-z_]\w*'
 pattern=r'\b(input|output)\s+(?:wire|reg)\s*(\[[^]]+\])?\s*('+identifier+r'(?:\s*,\s*'+identifier+r')*)'
 ports=[(direction,width,name.strip()) for direction,width,names in re.findall(pattern,header) for name in names.split(',')]
 assert len(ports)>35,len(ports)
 s=(a.candidate/'sequence-oracle-v2'/board/'tb_link_delayed.v').read_text(encoding='utf-8-sig')
 # Original bench changes phy at the active edge after a fixed # delay.
 # Give the primitive data/CE mux actual setup time, in both DUT and mirror.
 # Asynchronous reset assertions remain asynchronous and unchanged.
 s=s.replace('phy=0;#2000;', '@(negedge clk);phy=0;#2000;')
 s=s.replace('phy=1;wait(up0 && up1);', '@(negedge clk);phy=1;wait(up0 && up1);')
 logic='\n'
 for instance in ('a','b'):
  match=re.search(r'db_link\s*(#\([^;]*?\))?\s+'+instance+r'\s*\(',s,re.S);assert match
  logic+='reference_link '+(match[1] or '')+' mirror_'+instance+'(\n'+',\n'.join(
   f'.{name}({instance}.{name})' if direction=='input' else f'.{name}()' for direction,width,name in ports)+'\n);\n'
  comparisons=[]
  for direction,width,name in ports:
   if direction=='output':
    logic+=f'wire {width or ""} observed_{instance}_{name}={instance}.{name},expected_{instance}_{name}=mirror_{instance}.{name};\n'
    comparisons.append(name)
  for bank in ('next_seq','expect_seq'):
   for n in range(3):
    name=bank+str(n);comparisons.append(name)
    logic+=f'wire [31:0] observed_{instance}_{name}={instance}.{bank}[{n}],expected_{instance}_{name}=mirror_{instance}.{bank}[{n}];\n'
  logic+='always @(posedge clk)begin #2;if(!rst)begin\n'
  for name in comparisons:
   logic+=f'if(observed_{instance}_{name}!==expected_{instance}_{name})$fatal(1,"sequence exact mismatch {instance}.{name}: got=%h expected=%h",observed_{instance}_{name},expected_{instance}_{name});\n'
  logic+='end end\n'
 s=s.replace("force a.next_seq[2]=32'hfffffff8;", "mirror_a.next_seq[2]=32'hfffffff8;mirror_b.expect_seq[2]=32'hfffffff8;force a.next_seq[2]=32'hfffffff8;")
 i=s.index('    initial begin #10000000;');s=s[:i]+logic+s[i:]
 tb=work/'tb_link_exact.v';tb.write_text(s,encoding='utf-8')
 files=[*[b/'rtl/link'/f'{n}.v' for n in ('db_packet_ram','db_async_fifo','db_mac_rx','db_link')],ref,tb]
 for native in (False,True):
  simulate(work/('native' if native else 'behavioral'),'tb_link',files,
   includes=[b/'rtl',b/'rtl/link'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
