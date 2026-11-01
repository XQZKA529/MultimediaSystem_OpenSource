"""Mirror the real FAT/subtitle storage workload into the frozen old service."""
import argparse,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);p.add_argument('--tag',default='file-context-equivalence')
p.add_argument('--pending-stress',action='store_true');a=p.parse_args()
b=a.candidate.resolve();r=a.reference.resolve();w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
old=(r/'rtl/storage/storage_service.v').read_text(encoding='utf-8-sig')
header=re.sub(r'//[^\n]*','',old[:old.index('\n);')])
identifier=r'(?!(?:input|output|wire|reg)\b)[A-Za-z_]\w*'
pattern=r'\b(input|output)\s+(?:wire|reg)\s*(\[[^]]+\])?\s*('+identifier+r'(?:\s*,\s*'+identifier+r')*)'
ports=[(direction,width,name.strip()) for direction,width,names in re.findall(pattern,header) for name in names.split(',')]
assert len(ports)==57,len(ports)
ref_service=w/'reference_service.v';ref_service.write_text(old.replace('module storage_service #(', 'module reference_service #(').replace('fat32_ro #(', 'reference_fat #('),encoding='utf-8')
fat=(r/'rtl/fat/fat32_ro.v').read_text(encoding='utf-8-sig')
ref_fat=w/'reference_fat.v';ref_fat.write_text(fat.replace('module fat32_ro #(', 'module reference_fat #(').replace('resource_fat_dsp_hold','reference_fat_dsp_hold'),encoding='utf-8')
s=(b/'sim/tb_sd_subtitle_fat.v').read_text(encoding='utf-8-sig')
if a.pending_stress:
 s=s.replace('reg bmp_start=0,map_start=0,bmp_ready=0;', '''reg bmp_start=0,map_start=0,bmp_ready=0;
 reg stress=0;integer stress_offset=0,stress_completed=0;
 reg [31:0] stress_size=600,stress_limit=0;''')
 s=s.replace(".file_size(32'd600),.file_read_limit(32'd0)", '.file_size(stress_size),.file_read_limit(stress_limit)')
 old_check='if(bmp_valid) begin if(bmp_data!==bmp_bytes[7:0]) $fatal(1,"BMP response ownership");bmp_bytes=bmp_bytes+1;end'
 assert old_check in s
 s=s.replace(old_check,'''if(stress)begin
   if(bmp_valid)begin
    if(bmp_data!==stress_offset[7:0])$fatal(1,"pending overwrite changed active data");
    stress_offset=stress_offset+1;
   end
   if(bmp_done)begin
    if(!bmp_ok || stress_offset!=(stress_completed==0 ? 600:stress_completed==1 ? 128:257))
     $fatal(1,"pending/active length crossed %d %d",stress_completed,stress_offset);
    stress_offset=0;stress_completed=stress_completed+1;
   end
  end else '''+old_check)
 marker='  $display("*** PASS *** real FAT subtitle:'
 i=s.index(marker)
 s=s[:i]+'''  // Keep the first request active under credit backpressure while two
  // later pending requests overwrite one another. The last pending request
  // wins, matching the original one-slot-per-client queue. Then queue again
  // while the second file is active; all three lengths remain independent.
  wait(idle);@(negedge clk);stress=1;bmp_ready=0;stress_size=600;stress_limit=0;
  bmp_start=1;tick(1);bmp_start=0;tick(30);
  stress_size=200;stress_limit=17;bmp_start=1;tick(1);bmp_start=0;tick(2);
  stress_size=600;stress_limit=128;bmp_start=1;tick(1);bmp_start=0;tick(20);
  bmp_ready=1;wait(stress_completed==1);tick(30);
  stress_size=257;stress_limit=0;bmp_start=1;tick(1);bmp_start=0;
  wait(stress_completed==3);tick(20);
  // Independent short warm reset invalidates pending work before reuse.
  @(negedge clk);rst=1;#2;rst=0;tick(5);
  stress=0;
'''+s[i:]
 s=s.replace('parse and block failures', 'parse/block failures, pending overwrite during two active reads, independent request sizes/limits and warm reset')
logic='\nreference_service #(.FILE_MAX_BURST(1)) reference_model(\n'+',\n'.join(f'.{name}(storage.{name})' if direction=='input' else f'.{name}()' for direction,width,name in ports)+'\n);\n'
for direction,width,name in ports:
 if direction=='output':logic+=f'wire {width or ""} observed_{name}=storage.{name},expected_{name}=reference_model.{name};\n'
logic+='integer exact_checks=0;\nalways @(posedge clk)begin #1;if(!rst)begin exact_checks=exact_checks+1;\n'
for direction,width,name in ports:
 if direction=='output':logic+=f'if(observed_{name}!==expected_{name})$fatal(1,"Storage exact mismatch {name} cycle %d",exact_checks);\n'
logic+='end end\n'
i=s.rindex('endmodule');s=s[:i]+logic+s[i:]
tb=w/'tb_sd_subtitle_fat.v';tb.write_text(s,encoding='utf-8')
files=[ref_service,ref_fat,b/'rtl/ui/subtitle_ram.v',b/'rtl/ui/txt_prefix_parser.v',b/'rtl/ui/sd_subtitle_controller.v',b/'rtl/storage/storage_service.v',b/'rtl/fat/fat32_ro.v',r.parents[2]/'render/rtl/ui/sd_subtitle_view.v',tb]
# The render view is unchanged by this storage-only candidate. Freeze a copy.
root=Path(__file__).resolve().parents[2];view=w/'sd_subtitle_view.v';view.write_bytes((root/'render/rtl/ui/sd_subtitle_view.v').read_bytes());files[-2]=view
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb_sd_subtitle_fat',files,includes=[b/'rtl',b/'rtl/pkg'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
