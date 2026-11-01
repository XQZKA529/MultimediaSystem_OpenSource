"""Mirror actual subtitle controller and FAT oracles across all public ports."""
import argparse,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);a=p.parse_args();b=a.candidate.resolve();r=a.reference.resolve()
root=Path(__file__).resolve().parents[2];w=b.parent/'subtitle-found-equivalence';w.mkdir(parents=True,exist_ok=True)
s=(r/'rtl/ui/sd_subtitle_controller.v').read_text(encoding='utf-8-sig')
ref=w/'reference.v';ref.write_text(s.replace('module sd_subtitle_controller #(', 'module reference_subtitle #('),encoding='utf-8')
header=s[s.index(')(\n')+3:s.index(');')]
ports=[];direction=width=None
for item in header.split(','):
 m=re.fullmatch(r'\s*(?:(input|output)\s+(?:wire|reg)\s*(\[[^]]+\])?\s*)?(\w+)\s*',item)
 assert m,item
 if m[1]:direction,width=m[1],m[2]
 ports.append((direction,width,m[3]))
for name in ('tb_sd_subtitle_controller','tb_sd_subtitle_fat'):
 text=(b/'sim'/f'{name}.v').read_text(encoding='utf-8-sig')
 match=re.search(r'sd_subtitle_controller\s*(#\(.*?\))?\s+(dut|controller)\s*\(',text,re.S)
 assert match,name
 instance=match[2]
 logic='\nreference_subtitle '+(match[1] or '')+' reference_model('+','.join(
  f'.{port}({instance}.{port})' if direction=='input' else f'.{port}()'
  for direction,width,port in ports)+');\n'
 logic+='integer exact_checks=0;always @(posedge clk)begin #1;if(!rst)begin exact_checks=exact_checks+1;\n'
 for direction,width,port in ports:
  if direction=='output':logic+=f'if({instance}.{port}!==reference_model.{port})$fatal(1,"subtitle public mismatch {port} cycle %0d",exact_checks);\n'
 logic+='end end\n'
 i=text.rindex('endmodule');text=text[:i]+logic+text[i:]
 tb=w/(name+'.v');tb.write_text(text,encoding='utf-8')
 files=[ref,b/'rtl/ui/sd_subtitle_controller.v',b/'rtl/ui/subtitle_ram.v',b/'rtl/ui/txt_prefix_parser.v',
        b/'rtl/storage/storage_service.v',b/'rtl/fat/fat32_ro.v',root/'render/rtl/ui/sd_subtitle_view.v',tb]
 for native in (False,True):
  simulate(w/name/('native' if native else 'behavioral'),name,files,
   includes=[b/'rtl',b/'rtl/pkg',b/'rtl/ui',b/'rtl/fat'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
