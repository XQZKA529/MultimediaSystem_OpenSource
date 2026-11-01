"""Assemble the first valid MBR partition directly into its mount context.

The mount owns partition_lba/sectors until publishing mount_done. Preserve
their full 32 bits; stop byte writes after the first accepted nonzero FAT32
entry. Superfloppy admission clears both words as before. Active FILE/MAP
and independently pending requests never share these registers.
"""
import argparse,re,json
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
p.add_argument('--local-capture',action='store_true');a=p.parse_args()
snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('reg [31:0] mbr_sel_lba,mbr_sel_size;',
'''// Diagnostic aliases: one owner assembles, validates and retains this pair.
wire [31:0] mbr_sel_lba=partition_lba,mbr_sel_size=partition_sectors;''')
s=s.replace('reg [31:0] mbr_work_lba;','wire [31:0] mbr_work_lba=partition_lba;')
s=s.replace('reg [23:0] mbr_work_size;','wire [23:0] mbr_work_size=partition_sectors[23:0];')
start=s.index('// The MBR work fields have a private capture enable.')
end=s.index('// Prepare the map-run write enable',start)
s=s[:start]+s[end:]
capture='''    // Mount preparation owns the pair before validation. Later MBR slots
    // cannot overwrite the first accepted entry, even with back-to-back bytes.
    if(mbr_capture && blk_data_valid_i && rd_index>=446 && rd_index<510 && !mbr_found) begin
      case(rd_index[3:0])
        2:mbr_work_type<=blk_data_i;
        6:partition_lba[7:0]<=blk_data_i;
        7:partition_lba[15:8]<=blk_data_i;
        8:partition_lba[23:16]<=blk_data_i;
        9:partition_lba[31:24]<=blk_data_i;
        10:partition_sectors[7:0]<=blk_data_i;
        11:partition_sectors[15:8]<=blk_data_i;
        12:partition_sectors[23:16]<=blk_data_i;
      endcase
    end
'''
marker='    case(control_state) // synthesis parallel_case'
assert s.count(marker)==1
s=s.replace(marker,capture+marker)
assert s.count('mbr_sel_lba<=mbr_work_lba;')==1
s=s.replace('mbr_sel_lba<=mbr_work_lba;','')
s=s.replace('mbr_sel_size<={blk_data_i,mbr_work_size};','partition_sectors[31:24]<=blk_data_i;')
s=s.replace('partition_lba<=mbr_sel_lba; partition_sectors<=mbr_sel_size;','')
if a.local_capture:
 s=s.replace(capture,'')
 s=re.sub(r'\bpartition_(?:lba|sectors)<=0;\s*','',s)
 assert s.count('partition_sectors[31:24]<=blk_data_i;')==1
 s=s.replace('partition_sectors[31:24]<=blk_data_i;','')
 marker='      control_state!=S_IDLE && control_state!=S_FAIL);'
 assert s.count(marker)==1
 local='''
    // Byte capture stays beside the mount context; unrelated runtime field
    // enables no longer share its wide main-process priority/abort mux.
    always @(posedge clk or posedge rst)begin
      if(rst)begin partition_lba<=0;partition_sectors<=0;end
      else if((control_state==S_IDLE && mount_start) ||
        (control_state==S_MOUNT_ISFS && !mount_sig_bad && mount_fs_cand))begin
        partition_lba<=0;partition_sectors<=0;
      end else if(context_case_enable)begin
        if(mbr_capture && blk_data_valid_i && rd_index>=446 && rd_index<510 && !mbr_found)begin
          case(rd_index[3:0])
            2:mbr_work_type<=blk_data_i;
            6:partition_lba[7:0]<=blk_data_i;
            7:partition_lba[15:8]<=blk_data_i;
            8:partition_lba[23:16]<=blk_data_i;
            9:partition_lba[31:24]<=blk_data_i;
            10:partition_sectors[7:0]<=blk_data_i;
            11:partition_sectors[15:8]<=blk_data_i;
            12:partition_sectors[23:16]<=blk_data_i;
          endcase
        end
        if(control_state==S_RD_WAIT && blk_data_valid_i && rd_kind==RD_MOUNT &&
          blk_lba==0 && rd_index>=446 && rd_index<510 && rd_index[3:0]==13 &&
          !mbr_found && is_fat32_type(mbr_work_type) && partition_lba!=0)
          partition_sectors[31:24]<=blk_data_i;
      end
    end
'''
 s=s.replace(marker,marker+local)
assert not re.search(r'mbr_(?:work_(?:lba|size)|sel_(?:lba|size))\s*(?:\[[^]]+\])?<=',s)
f.write_text(s,encoding='utf-8')
(a.destination.parent/'mbr-stream-context.json').write_text(json.dumps(dict(
    removed_register_bits=120,partition_bits=64,changed_latency=False,
    ownership='mount only; first valid entry locks until next mount',
    pending_storage_shared=False),indent=2),encoding='utf-8')
