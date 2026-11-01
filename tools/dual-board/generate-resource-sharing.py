from pathlib import Path
import re
from resource_experiment import snapshot

ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'build/resource-v1'
base=OUT/'base/media'

def candidate(name):
    dest=OUT/name/'media'
    if not dest.exists():snapshot(base,dest)
    return dest

# Mount/DBR capture and active file walking are serialized. Share the raw and
# decoded copies, retaining all 32 input bits and every validation predicate.
p=base/'rtl/fat/fat32_ro.v';s=p.read_text(encoding='utf-8-sig')
s=s.replace('reg [7:0] bpb_spc, bpb_nfats;', 'reg [7:0] bpb_spc;')
s=s.replace('reg [15:0] bpb_bps, bpb_reserved, bpb_tot16;', 'reg [15:0] bpb_bps, bpb_tot16;')
s=s.replace('reg [31:0] bpb_tot32, bpb_fat32, bpb_root;', '')
s=s.replace('reg [31:0] tmp32a, tmp32b, data_sectors, cluster_count;', 'reg [31:0] tmp32a, tmp32b, data_sectors;\nwire [31:0] cluster_count;')
s=s.replace('reg [31:0] cluster_count_p1;', '// max_cluster is the same mount working result; it is valid only after mount_ok.\n//')
for old,new in [('bpb_nfats','num_fats'),('bpb_reserved','reserved_sectors'),('bpb_tot32','total_sectors'),('bpb_fat32','fat_sectors'),('bpb_root','root_cluster'),('cluster_count_p1','max_cluster')]:
    s=re.sub(r'\b'+old+r'\b',new,s)
s=re.sub(r'cluster_count<=geometry_clusters;','',s)
s=s.replace('wire [31:0] geometry_clusters=data_sectors>>cluster_shift;', 'wire [31:0] geometry_clusters=data_sectors>>cluster_shift;\nassign cluster_count=geometry_clusters;')
# max_cluster must have one driver. Move its update from the geometry helper
# always block to the original main FSM; remove helper reset and final self-write.
s=s.replace('max_cluster<=0;cluster_x4<=0;', 'cluster_x4<=0;')
s=re.sub(r"if\(geom4_write\) max_cluster<=geometry_clusters\+32'd1;", '',s)
s=s.replace('      state_hot[S_MOUNT_GEOM4]: begin', '      state_hot[S_MOUNT_GEOM4]: begin')
s=s.replace('      state_hot[S_MOUNT_GEOM3_CHECK]: begin', '      state_hot[S_MOUNT_GEOM3_CHECK]: begin')
# GEOM4 consumes the previous geometry result; assigning on entry (GEOM3_CHECK)
# preserves the helper's original geom4_write edge, which occurs one stage later.
s=s.replace("           data_sectors<=total_sectors-data_start_offset;", "           data_sectors<=total_sectors-data_start_offset;")
s=s.replace("      state_hot[S_MOUNT_GEOM4]: begin\n", "      state_hot[S_MOUNT_GEOM4]: begin\n        max_cluster<=geometry_clusters+32'd1;\n")
s=s.replace('max_cluster<=max_cluster; mount_ok<=1;', 'mount_ok<=1;')
# Keep the merged reserved-sector register in the main FSM's single driver.
capture="""    if(!rst && boot_capture && blk_data_valid_i) begin
        if(rd_index==14) reserved_sectors[7:0]<=blk_data_i;
        if(rd_index==15) reserved_sectors[15:8]<=blk_data_i;
    end
"""
s=s.replace(capture,'')
s=s.replace('    mount_done<=0; dir_done<=0;',capture.replace('!rst && ','')+'    mount_done<=0; dir_done<=0;')
(candidate('media_mount_sharing')/'rtl/fat/fat32_ro.v').write_text(s,encoding='utf-8')

# The dispatch edge freezes only the selected object. The separately published
# audio dispatch epoch retains its original lifetime, independent of TX traffic.
s=(base/'rtl/seam/seam_media.v').read_text(encoding='utf-8-sig')
a=s.index('    reg [7:0] object_select;');b=s.index('    always @(posedge clk or posedge rst) begin\n        if(rst) audio_dispatch_valid',a)
s=s[:a]+'''    reg [31:0] selected_object,object_begin;
    assign audio_consumed_epoch=feedback_id;assign audio_dispatch_epoch=object_begin;
    assign obj_r=selected_object;
    wire [31:0] next_object=
        ({32{obj_volume}} & volume_revision) |
        ({32{obj_error || obj_emergency}} & (obj_emergency ? emergency_reply_revision:error_object)) |
        ({32{obj_audio_begin}} & audio_pending_id) |
        ({32{obj_audio_control || obj_audio_stream}} & audio_id) |
        ({32{obj_subtitle}} & subtitle_revision) |
        ({32{obj_ui}} & ui_revision) |
        ({32{obj_image_abort}} & abort_image_id) |
        ({32{obj_image}} & image_id);
    always @(posedge clk or posedge rst) begin
        if(rst) begin selected_object<=0;object_begin<=0;end
        else if(idle_can_send) begin
            selected_object<=next_object;
            if(obj_audio_begin) object_begin<=audio_pending_id;
        end
    end
'''+s[b:]
(candidate('media_object_sharing')/'rtl/seam/seam_media.v').write_text(s,encoding='utf-8')
