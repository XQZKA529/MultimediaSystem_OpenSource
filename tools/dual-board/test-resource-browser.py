"""Compare all browser control outputs and every valid UI write to frozen RTL."""
import argparse
from pathlib import Path
import re
from resource_sim import simulate

ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser()
p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,default=ROOT/'build/resource-v1/base/media')
args=p.parse_args();b=args.candidate.resolve();ref=args.reference.resolve()
work=b.parent/'browser-cycle-equivalence';work.mkdir(parents=True,exist_ok=True)
original=(ref/'rtl/ui/file_browser.v').read_text(encoding='utf-8-sig')
reference=work/'reference_browser.v'
reference.write_text(original.replace('module file_browser #(', 'module reference_browser #('),encoding='utf-8')
clean=re.sub(r'/\*.*?\*/|//[^\n]*','',original,flags=re.S)
start=clean.index('input',clean.index('module file_browser'))
header=clean[start:clean.index(');',start)]
outputs=[];direction=None
for part in header.split(','):
    part=part.strip();m=re.match(r'(input|output|inout)\b',part)
    if m:direction=m[1]
    if direction=='output':
        name=re.search(r'(\w+)\s*$',part)
        if name:outputs.append(name[1])
assert {'ui_wr_en','ui_wr_data','dir_req','ext_load_req'}<=set(outputs)
s=(b/'sim/tb_settings_menu.v').read_text(encoding='utf-8-sig')
instance=re.search(r'    file_browser #\(.*?\) dut\(.*?;',s,re.S)[0]
duplicate=instance.replace('file_browser #(', 'reference_browser #(',1).replace(') dut(',') golden(',1)
for name in outputs:duplicate=re.sub(r'\.'+name+r'\([^)]*\)', '.'+name+'()',duplicate)
comparisons=[]
for name in outputs:
    if name in ('ui_wr_addr','ui_wr_data'):continue
    comparisons.append(f' if(dut.{name}!==golden.{name}) $fatal(1,"Browser output {name} differs");')
comparisons.append(' if(dut.ui_wr_en && {dut.ui_wr_addr,dut.ui_wr_data}!=={golden.ui_wr_addr,golden.ui_wr_data}) $fatal(1,"Browser valid UI write differs");')
assertion='\n    always @(posedge clk) begin #1;if(!rst) begin\n'+'\n'.join(comparisons)+'\n    end end\n'
s=s.replace(instance,instance+'\n'+duplicate+assertion)
tb=work/'tb_settings_menu.v';tb.write_text(s,encoding='utf-8')
files=[b/'rtl'/f for f in ('clock/key_debounce.v','clock/key_click_decode.v','audio/volume_controller.v',
                           'ui/settings_menu_text_rom.v','ui/file_browser.v')]+[reference,tb]
for native in (False,True):
    simulate(work/('native' if native else 'behavioral'),'tb_settings_menu',files,
             includes=[b/'rtl',b/'rtl/ui',b/'rtl/pkg'],native=native,
             defines=[] if native else ['DB_BEHAVIORAL_RAM'])
