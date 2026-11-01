"""Give FAT scratch words operation-local write enables, without storage changes.

Mount states belong to OP_MOUNT, directory LBA to OP_DIR, map LBA to OP_MAP,
and file prep/LBA states to OP_FILE. Their local enables therefore need the
file-abort guard only in file states. Pending requests and shared read states
retain the original main-FSM guard and independent lifetimes.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
mb='state_encoded==S_RD_WAIT && blk_data_valid_i && rd_kind==RD_MOUNT && blk_lba==0 && rd_index>=446 && rd_index<510 && rd_index[3:0]==13 && !mbr_found && is_fat32_type(mbr_work_type) && mbr_work_lba!=0'
fields=[
 ('fat_area_sectors','state_encoded==S_MOUNT_GEOM1','fat_sectors*num_fats',['fat_sectors*num_fats']),
 ('data_start_offset','state_encoded==S_MOUNT_GEOM2',"{16'd0,reserved_sectors}+fat_area_sectors",["{16'd0,reserved_sectors}+fat_area_sectors"]),
 ('file_sector_count','state_encoded==S_FILE_PREP1 && !file_abort_i',"({1'b0,file_remaining}+33'd511)>>9",["({1'b0,file_remaining}+33'd511)>>9"]),
 ('file_hop_limit','state_encoded==S_FILE_PREP3 && !file_abort_i','geometry_clusters[23:0]',['geometry_clusters[23:0]']),
 ('cluster_lba_offset','state_encoded==S_DIR_LBA || state_encoded==S_MAP_LBA || (state_encoded==S_FILE_LBA && !file_abort_i)','lba_cluster_offset',['lba_cluster_offset']*3),
 ('data_sectors','(state_encoded==S_FILE_PREP2 && !file_abort_i) || (state_encoded==S_MOUNT_GEOM3_CHECK && !geom3_bad)',
  "state_encoded==S_FILE_PREP2 ? {8'd0,file_hop_rounded}:total_sectors-data_start_offset",["{8'd0,file_hop_rounded}",'total_sectors-data_start_offset']),
 ('mbr_sel_lba',mb,'mbr_work_lba',['mbr_work_lba']),
 ('mbr_sel_size',mb,'{blk_data_i,mbr_work_size}',['{blk_data_i,mbr_work_size}'])]
for name,ce,data,expected in fields:
 actual=re.findall(r'\b'+name+r'\s*<=\s*([^;]+);',s)
 assert sorted(v.replace(' ','') for v in actual)==sorted(expected),(name,actual)
 s=re.sub(r'\b'+name+r'\s*<=\s*[^;]+;','',s)
logic='''
// These unreset work words keep their exact old capture edges. A local write
// enable avoids routing a file-cancel/state mux into unrelated mount words.
always @(posedge clk)begin
 if(!rst)begin
'''
for name,ce,data,expected in fields:logic+=f'  if({ce}){name}<=({data});\n'
logic+=' end\nend\n'
i=s.index('\nendmodule');s=s[:i]+logic+s[i:]
f.write_text(s,encoding='utf-8')
