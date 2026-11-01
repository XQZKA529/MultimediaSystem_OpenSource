"""Mirror every service output and all seven complete pending metadata words.

Both services instantiate the real unchanged FAT engine. Colliding client
requests, overwrites, resets and aborts exercise bank independence, reset zero
semantics, arbitration and the original capture/launch cycle relationship.
"""
import argparse
from pathlib import Path
import re
from resource_sim import simulate

p=argparse.ArgumentParser()
p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True)
p.add_argument('--tag',default='storage-context-equivalence-v2')
p.add_argument('--owner-qualified',action='store_true')
a=p.parse_args();b=a.candidate.resolve();r=a.reference.resolve()
w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
s=(r/'rtl/storage/storage_service.v').read_text(encoding='utf-8-sig')
ref=w/'reference_service.v';ref.write_text(s.replace('module storage_service #(', 'module reference_service #('),encoding='utf-8')
header=re.sub(r'//[^\n]*','',s[:s.index('\n);')])
header=header[header.index('input',header.index('module storage_service')):]
# ANSI declarations may share a direction/width across comma-separated names.
ports=[];direction=None;width=''
for part in header.split(','):
    part=part.strip()
    m=re.match(r'(input|output)\b',part)
    if m:
        direction=m[1]
        bits=re.search(r'\[[^]]+\]',part)
        width=bits[0] if bits else ''
    name=re.search(r'(\w+)\s*$',part)
    assert direction and name,part
    ports.append((direction,width,name[1]))
assert len(ports)==57 and {'txt_file_size','txt_file_ok'} <= {name for _,_,name in ports}
tb='`include "fat_dir_bus.vh"\nmodule tb;reg clk=0,rst=1;always #5 clk=~clk;integer n,checks=0;reg [63:0] rng=64\'ha369215f83c102ed;\n'
inputs=[(width,name) for direction,width,name in ports if direction=='input' and name not in ('clk','rst')]
outputs=[name for direction,width,name in ports if direction=='output']
for width,name in inputs:tb+=f'reg {width} {name}=0;\n'
for module,inst in [('storage_service','dut'),('reference_service','golden')]:
    tb+=module+' '+inst+'('+','.join(f'.{name}({name})' if direction=='input' else f'.{name}()' for direction,width,name in ports)+');\n'
if a.owner_qualified:
    tb+='''reg [2:0] seen=0;
always @(posedge clk or posedge rst)begin
 if(rst)seen<=0;
 else begin if(file_start)seen[0]<=1;if(txt_file_start)seen[1]<=1;if(map_start)seen[2]<=1;end
end
always @(negedge clk)if(!rst)begin
 if(dut.ro_file_start && ((dut.owner==dut.BMP && !seen[0]) || (dut.owner==dut.TXT && !seen[1])))
  $fatal(1,"FAT file launch before matching payload capture");
 if(dut.ro_map_start && !seen[2])$fatal(1,"FAT map launch before payload capture");
end
'''
tb+='always @(posedge clk)begin #1;\n'
for name in outputs+['bmp_cluster_q','bmp_size_q','bmp_limit_q','txt_cluster_q','txt_size_q','map_cluster_q','map_size_q']:
    group=0 if name.startswith('bmp_') else 1 if name.startswith('txt_') else 2
    guard=f'seen[{group}] && ' if a.owner_qualified and name.endswith('_q') else ''
    tb+=f' if({guard}dut.{name}!==golden.{name})$fatal(1,"Storage service exact mismatch {name} cycle %d",checks);\n'
tb+='checks=checks+1;end\ninitial begin repeat(5)@(negedge clk);rst=0;\nfor(n=0;n<240000;n=n+1)begin\n'
for width,name in inputs:
    tb+=f" rng=rng*64'd6364136223846793005+64'd1442695040888963407;{name}=rng;\n"
# Long enough quiet periods let the real FAT return to IDLE. Bursts include
# simultaneous captures of every bank, with upper bits independent/random.
tb+=''' file_start=n%37==0 || n%1000<4;
 txt_file_start=n%41==0 || n%1000<4;map_start=n%43==0 || n%1000<4;
 mount_start=n%397==0;c0_dir_start=n%53==0;c1_dir_start=n%59==0;c2_dir_start=n%61==0;
 file_abort=n%71==0;map_abort=n%73==0;
 if(n%2003==17)begin rst=1;#2;rst=0;end
 @(negedge clk);
end
 $display("PASS 240005 storage-service public checks and full-32-bit pending fields at their owning capture lifetime: independent simultaneous captures, queued overwrites, arbitration, aborts, real FAT and short warm resets");$finish;
end endmodule
'''
f=w/'tb.v';f.write_text(tb,encoding='utf-8')
for native in (False,True):
    simulate(w/('native' if native else 'behavioral'),'tb',[ref,b/'rtl/storage/storage_service.v',b/'rtl/fat/fat32_ro.v',f],
             includes=[b/'rtl',b/'rtl/pkg',b/'rtl/storage',b/'rtl/fat'],native=native,
             defines=[] if native else ['DB_BEHAVIORAL_RAM'])
