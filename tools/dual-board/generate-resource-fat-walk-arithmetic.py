"""Share actual arithmetic by reusing disjoint active-operation operands.

FILE decrements the already shared remaining word by one; MAP subtracts its
cluster byte count. The MAP byte operand is dead throughout FILE, so initialize
it to one at FILE_SELECT and use one full-width subtraction for both updates.
Optionally share DIR/FILE sector counters and initialize the unused FILE burst
operand to one at DIR admission, sharing their incrementer without a data mux.
No extra states, cycles, pending changes, narrower operands or timeouts.
"""
import argparse
from pathlib import Path
import re
from resource_experiment import snapshot

p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);p.add_argument('--share-sectors',action='store_true')
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
assert s.count('      S_FILE_SELECT: begin')==1
s=s.replace('      S_FILE_SELECT: begin', '''      S_FILE_SELECT: begin
        // This operand's MAP lifetime starts at S_MAP_USE. FILE owns it now.
        map_use_bytes<=32'd1;''')
marker='reg [31:0] map_use_bytes;';assert s.count(marker)==1
s=s.replace(marker,marker+'\nwire [31:0] walk_remaining_next=walk_remaining-map_use_bytes;')
assert s.count('walk_remaining<=file_remaining-1;')==1
assert s.count('walk_remaining      <= map_remaining - map_use_bytes;')==1
s=s.replace('walk_remaining<=file_remaining-1;', 'walk_remaining<=walk_remaining_next;')
s=s.replace('walk_remaining      <= map_remaining - map_use_bytes;', 'walk_remaining<=walk_remaining_next;')
if a.share_sectors:
    assert s.count('reg [7:0] dir_sector;')==1 and s.count('reg [7:0] file_cluster_sector;')==1
    s=s.replace('reg [7:0] dir_sector;', '''reg [7:0] traversal_sector;
wire [7:0] dir_sector=traversal_sector;''')
    declaration='reg [7:0] file_read_sectors;'
    assert s.count(declaration)==1
    s=s.replace(declaration,declaration+'\nwire [7:0] traversal_sector_next=traversal_sector+file_read_sectors;')
    s=s.replace('reg [7:0] file_cluster_sector;', 'wire [7:0] file_cluster_sector=traversal_sector;')
    old='dir_hops<=0; dbg_dir_entry_count<=0;';assert s.count(old)==1
    s=s.replace(old,"file_read_sectors<=8'd1;"+old)
    s=s.replace('dir_sector<=dir_sector+1;', 'dir_sector<=traversal_sector_next;')
    s=s.replace('file_cluster_sector<=file_cluster_sector+file_read_sectors;', 'file_cluster_sector<=traversal_sector_next;')
    s=re.sub(r'\b(?:dir_sector|file_cluster_sector)\s*<=','traversal_sector<=',s)
f.write_text(s,encoding='utf-8')
