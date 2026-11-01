"""Share five 32-bit mount work fields with disjoint active-operation fields.

No new states/latency; pending request storage is deliberately excluded. Each
active owner initializes its field before use after mount_ok becomes true.
All writers remain in the original main clocked process.
"""
import argparse
from pathlib import Path
import re
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
args=p.parse_args()
snapshot(args.source,args.destination)
pairs=[('partition_lba','walk_cluster'),('total_sectors','cycle_tortoise'),
       ('partition_sectors','captured_file_size'),('fat_area_sectors','captured_read_limit'),
       ('data_start_offset','map_cluster_prev')]
file=args.destination/'rtl/fat/fat32_ro.v'
s=file.read_text(encoding='utf-8-sig')
remove={a for a,b in pairs}
def declaration(m):
    items=m[1].split(',')
    kept=[item for item in items if item.strip() not in remove]
    return 'reg [31:0] '+','.join(kept)+';' if kept else ''
s=re.sub(r'reg \[31:0\]\s+([^;]+);',declaration,s)
for old,new in pairs:s=re.sub(r'\b'+old+r'\b',new,s)
s=s.replace('reg [31:0] walk_cluster, walk_remaining;', '''// Mount LBA and runtime walking never overlap. Runtime DIR/FILE/MAP admission
// initializes walk_cluster before offset calculation. The remaining pairs are
// documented in mount-lifetime-map.json next to this experimental board.
reg [31:0] walk_cluster, walk_remaining;''')
file.write_text(s,encoding='utf-8')
import json
(args.destination/'mount-lifetime-map.json').write_text(json.dumps(
    dict(pairs=pairs,precision_bits=32,pending_storage_shared=False,latency_changed=False),indent=2),encoding='utf-8')
tb=args.destination/'sim/tb_fat32_ro.v'
s=tb.read_text(encoding='utf-8-sig')
if 'dut.state_hot' in s:
    start=s.index('wire [63:0] observed_state_hot');end=s.index('reg mount_start=',start)
    s=s[:start]+'''wire [6:0] observed_state=dut.state_encoded;
wire [7:0] observed_diagnostic=dut.state;
wire [7:0] expected_diagnostic={1'b0,observed_state};
always @(negedge clk) if(!rst) begin
 if((observed_state ^ observed_state)!==7'd0 || observed_state>=72)
  $fatal(1,"FAT control state undefined/out of range");
 if(observed_diagnostic!==expected_diagnostic) $fatal(1,"FAT diagnostic state disagrees with control");
end
'''+s[end:]
s=s.replace('dut.partition_lba','dut.walk_cluster')
tb.write_text(s,encoding='utf-8')
