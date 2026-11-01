"""Share mutually exclusive FAT address additions with registered operands.

One extra mount cycle and one extra directory-sector preparation cycle; file
issue uses its existing preparation stage. Full LBA/size precision is retained.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
args=p.parse_args()
snapshot(args.source,args.destination)
file=args.destination/'rtl/fat/fat32_ro.v'
s=file.read_text(encoding='utf-8-sig')
pos=s.index('reg [6:0] state_encoded')
s=s[:pos]+'''localparam S_MOUNT_LBA_SECOND=8'd72;
localparam S_DIR_READ_EXEC=8'd73;
reg [7:0] sector_lba_addend;
'''+s[pos:]
s=s.replace('wire [31:0] lba_cluster_offset=', '''wire [31:0] prepared_sector_lba=map_cur_lba+{24'd0,sector_lba_addend};
// fat_area_sectors is dead after GEOM2 has captured data_start_offset.
// Reuse that operand register for the two subsequent mount address sums.
wire [31:0] prepared_mount_lba=partition_lba+fat_area_sectors;
wire [31:0] lba_cluster_offset=''')
s=s.replace("data_start_offset<={16'd0,reserved_sectors}+fat_area_sectors;", "data_start_offset<={16'd0,reserved_sectors}+fat_area_sectors;\n        fat_area_sectors<={16'd0,reserved_sectors};")
s=s.replace('fat_lba<=partition_lba+{16\'d0,reserved_sectors};\n          data_lba<=partition_lba+data_start_offset;\n          state_encoded<=S_MOUNT_GEOM4;', '''fat_lba<=prepared_mount_lba;
          fat_area_sectors<=data_start_offset;
          state_encoded<=S_MOUNT_LBA_SECOND;''')
s=s.replace('      S_MOUNT_GEOM4: begin', '''      S_MOUNT_LBA_SECOND:begin
        data_lba<=prepared_mount_lba;
        state_encoded<=S_MOUNT_GEOM4;
      end
      S_MOUNT_GEOM4: begin''')
s=s.replace('      S_DIR_READ: begin', '''      S_DIR_READ:begin
        sector_lba_addend<=dir_sector;
        state_encoded<=S_DIR_READ_EXEC;
      end
      S_DIR_READ_EXEC: begin''')
s=s.replace('tmp32a=map_cur_lba+dir_sector;', 'tmp32a=prepared_sector_lba;')
s=s.replace('      S_FILE_READ: begin', '      S_FILE_READ: begin\n        sector_lba_addend<=file_cluster_sector;')
s=s.replace("start_buffer_read(map_cur_lba+\n                          {24'd0,file_cluster_sector},", 'start_buffer_read(prepared_sector_lba,')
s=s.replace('fat_area_sectors<=0;', 'fat_area_sectors<=0;sector_lba_addend<=0;')
assert 'partition_lba+data_start_offset' not in s
assert 'map_cur_lba+dir_sector' not in s
file.write_text(s,encoding='utf-8')
# Only implementation-encoding assertions change, business oracles stay.
tb=args.destination/'sim/tb_fat32_ro.v'
s=tb.read_text(encoding='utf-8-sig')
if 'dut.state_hot' in s:
    start=s.index('wire [63:0] observed_state_hot');end=s.index('reg mount_start=',start)
    s=s[:start]+'''wire [6:0] observed_state=dut.state_encoded;
wire [7:0] observed_diagnostic=dut.state;
wire [7:0] expected_diagnostic={1'b0,observed_state};
always @(negedge clk) if(!rst) begin
 if((observed_state ^ observed_state)!==7'd0 || observed_state>=74)
  $fatal(1,"FAT control state undefined/out of range");
 if(observed_diagnostic!==expected_diagnostic) $fatal(1,"FAT diagnostic state disagrees with control");
end
'''+s[end:]
else:s=s.replace('observed_state>=72','observed_state>=74')
tb.write_text(s,encoding='utf-8')
