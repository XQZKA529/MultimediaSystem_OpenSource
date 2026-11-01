"""Mirror every real FAT oracle transaction into the retained reference RTL."""
import argparse,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);p.add_argument('--watch-scratch',action='store_true')
p.add_argument('--defined-scratch',action='store_true',help='Ignore wholly undefined reference scratch words only; public outputs remain exact')
p.add_argument('--watch-lfn',action='store_true')
p.add_argument('--watch-mbr-owner',action='store_true')
p.add_argument('--watch-hop-owner',action='store_true',help='Compare each shared active hop counter throughout its owning operation')
p.add_argument('--watch-walk-arithmetic',action='store_true',help='Check shared remaining word and each active sector operand lifetime')
p.add_argument('--tag',default='fat-dsp-equivalence');a=p.parse_args();b=a.candidate.resolve()
original=(a.reference/'rtl/fat/fat32_ro.v').read_text(encoding='utf-8-sig')
header=original[:original.index('\n);')]
header=re.sub(r'//[^\n]*','',header)
ports=re.findall(r'\b(input|output)\s+(?:wire|reg)\s*(\[[^]]+\])?\s*(\w+)',header)
assert len(ports)>45
work=b.parent/a.tag;work.mkdir(parents=True,exist_ok=True)
ref=work/'reference.v';ref.write_text(original.replace('module fat32_ro #(', 'module reference_fat #(').replace('resource_fat_dsp_hold','reference_fat_dsp_hold'),encoding='utf-8')
for test in ('tb_fat32_ro','tb_fat32_directory','tb_fat32_map','tb_fat32_timeout'):
 s=(b/'sim'/f'{test}.v').read_text(encoding='utf-8-sig')
 match=re.search(r'fat32_ro\s*(#\(.*?\))?\s+dut\s*\(',s,re.S)
 assert match,test
 logic='\nreference_fat '+(match[1] or '')+' reference_model(\n'+',\n'.join(
  f'.{name}(dut.{name})' if direction=='input' else f'.{name}()' for direction,width,name in ports)+'\n);\n'
 for direction,width,name in ports:
  if direction=='output':
   logic+=f'wire {width or ""} observed_{name}=dut.{name};\n'
   logic+=f'wire {width or ""} expected_{name}=reference_model.{name};\n'
 scratch=['captured_file_size','captured_read_limit','mbr_sel_lba','mbr_sel_size','fat_cache_lba','fat_req_lba','fat_area_sectors','data_start_offset','cluster_lba_offset','data_sectors','fat_next_cluster','file_sector_count','file_hop_limit'] if a.watch_scratch else []
 if a.watch_mbr_owner:
  # Direct assembly intentionally changes these private bytes before selection.
  # The owner checks below compare both complete words at consumption and
  # throughout mount_ok; every public output is still checked on every clock.
  scratch=[name for name in scratch if name not in ('mbr_sel_lba','mbr_sel_size')]
 if a.watch_lfn:scratch+=['lfn_base','lfn_len','lfn_ord','lfn_expected','lfn_checksum','lfn_active','lfn_valid','lfn_char_no','lfn_write_index']
 for name in ['fat_lba','data_lba','max_cluster','map_pend_cluster','map_pend_size']+scratch:
  logic+=f'wire [31:0] observed_{name}=dut.{name},expected_{name}=reference_model.{name};\n'
 compare=[name for direction,width,name in ports if direction=='output']+['fat_lba','data_lba','max_cluster','map_pend_cluster','map_pend_size']+scratch
 logic+='integer exact_checks=0;\nalways @(posedge clk)begin #1;if(!rst)begin\nexact_checks=exact_checks+1;\n'
 for name in compare:
  width=24 if name in ('file_sector_count','file_hop_limit') else 32
  guard=f"expected_{name}[{width-1}:0]!=={width}'bx && " if a.defined_scratch and name in scratch else ''
  logic+=f'if({guard}observed_{name}!==expected_{name})$fatal(1,"FAT exact cycle mismatch {name} at %d",exact_checks);\n'
 logic+='end end\n'
 candidate_rtl=(b/'rtl/fat/fat32_ro.v').read_text(encoding='utf-8-sig')
 if a.watch_walk_arithmetic:
  logic+='''always @(negedge clk)if(!rst)begin
   if(dut.walk_remaining!==reference_model.walk_remaining)$fatal(1,"Shared full-32-bit remaining word differs");
   if(dut.active_op==dut.OP_FILE && dut.control_state==dut.S_RD_WAIT && dut.rd_kind==dut.RD_FILE &&
      dut.map_use_bytes!==32'd1)$fatal(1,"FILE subtraction operand is not one");
   if(dut.control_state!=dut.S_IDLE && dut.control_state!=dut.S_FAIL)begin
    if(dut.active_op==dut.OP_DIR && dut.dir_sector!==reference_model.dir_sector)$fatal(1,"DIR active sector counter differs");
    if(dut.active_op==dut.OP_FILE && (dut.file_cluster_sector!==reference_model.file_cluster_sector ||
       dut.file_read_sectors!==reference_model.file_read_sectors))$fatal(1,"FILE active sector counter/operand differs");
   end
  end
'''
 if a.watch_hop_owner:
  logic+='''always @(negedge clk)if(!rst && dut.control_state!=dut.S_IDLE && dut.active_op==reference_model.active_op)begin
   case(dut.active_op)
    dut.OP_DIR:if(dut.dir_hops!==reference_model.dir_hops)$fatal(1,"DIR full-width active hop counter differs");
    dut.OP_FILE:if(dut.file_hops!==reference_model.file_hops)$fatal(1,"FILE 24-bit active hop counter differs");
    dut.OP_MAP:if(dut.map_hops!==reference_model.map_hops)$fatal(1,"MAP 20-bit active hop counter differs");
   endcase
  end
'''
 if a.watch_mbr_owner:
  # Assembling the private context starts earlier. Compare at every original
  # consumption/publication edge, then throughout its mounted lifetime.
  logic+='''always @(negedge clk)if(!rst)begin
   if(dut.control_state==dut.S_MOUNT_MBR && dut.mbr_found)begin
    if(dut.partition_lba!==reference_model.mbr_sel_lba ||
       dut.partition_sectors!==reference_model.mbr_sel_size)
       $fatal(1,"selected MBR context differs at original consumption");
   end
   if(dut.mount_ok)begin
    if(dut.partition_lba!==reference_model.partition_lba ||
       dut.partition_sectors!==reference_model.partition_sectors)
       $fatal(1,"published MBR context differs");
   end
  end
'''
 if re.search(r'reg\s*\[6:0\]\s*control_state\b',candidate_rtl):
  codes=sorted({int(v) for v in re.findall(r"\bS_\w+\s*=\s*8'd(\d+)",candidate_rtl)})
  assert len(codes)==72
  logic+='wire [6:0] actual_fat_control=dut.control_state;\n'
  logic+='always @(negedge clk)if(!rst)case(actual_fat_control)\n'
  logic+=','.join(f"7'd{v}" for v in codes)+':begin end\n'
  logic+='default:$fatal(1,"FAT actual control encoding is undefined/unused");endcase\n'
 i=s.rindex('endmodule');s=s[:i]+logic+s[i:];tb=work/(test+'.v');tb.write_text(s,encoding='utf-8')
 for native in (False,True):
  simulate(work/test/('native' if native else 'behavioral'),test,[ref,b/'rtl/fat/fat32_ro.v',tb],
   includes=[b/'rtl',b/'rtl/pkg',b/'rtl/fat'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
