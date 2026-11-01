"""Serial mount product using dead preparation fields and one registered adder.

Preserve all 256 FAT-count values and the original 32-bit modular product.
At most eight additional preparation clocks; no changed I/O/absolute timeout.
data_start_offset is the shifting operand until GEOM2 publishes its usual value.
num_fats is dead after this product and reloaded from the next boot sector.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('reg [6:0] state_encoded',"localparam S_MOUNT_PRODUCT=8'd72;\nreg [6:0] state_encoded",1)
s=s.replace('wire [31:0] lba_cluster_offset=',
 'wire [31:0] mount_preparation_sum=fat_area_sectors+data_start_offset;\nwire [31:0] lba_cluster_offset=',1)
old='''        fat_area_sectors<=fat_sectors*num_fats;
        state_encoded<=S_MOUNT_GEOM2;'''
new='''        fat_area_sectors<=0;
        data_start_offset<=fat_sectors;
        state_encoded<=S_MOUNT_PRODUCT;'''
assert old in s;s=s.replace(old,new)
s=s.replace('      S_MOUNT_GEOM2: begin', '''      S_MOUNT_PRODUCT:begin
        if(num_fats[0]) fat_area_sectors<=mount_preparation_sum;
        num_fats<=num_fats>>1;
        if(num_fats<=1) begin
          // Supply GEOM2's next addend on this edge; no state mux in the adder.
          data_start_offset<={16'd0,reserved_sectors};
          state_encoded<=S_MOUNT_GEOM2;
        end else data_start_offset<=data_start_offset<<1;
      end
      S_MOUNT_GEOM2: begin''',1)
assert "data_start_offset<={16'd0,reserved_sectors}+fat_area_sectors;" in s
s=s.replace("data_start_offset<={16'd0,reserved_sectors}+fat_area_sectors;",
            'data_start_offset<=mount_preparation_sum;')
f.write_text(s,encoding='utf-8')
tb=a.destination/'sim/tb_fat32_ro.v';s=tb.read_text(encoding='utf-8-sig')
s=s.replace('observed_state>=72','observed_state>=73');tb.write_text(s,encoding='utf-8')
