"""Remove proven unnecessary borrow bits; optionally share address additions.

Only subtract the low nine skip bits when they are nonzero, so no borrow can
reach the retained high 23 bits. Optional preparation reuses dead sec_need_r
to select the two addends before their original consumers; public cycles stay.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);p.add_argument('--share-address',action='store_true')
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/storage/lba_stream.v';s=f.read_text(encoding='utf-8-sig')
old="skip_bytes <= skip_bytes - 1'b1;";assert s.count(old)==1
s=s.replace(old,"skip_bytes[8:0] <= skip_bytes[8:0] - 9'd1; // Guard proves no borrow into bit 9.")
if a.share_address:
 old='cur_lba <= map_rd_lba + (skip_bytes >> 9);';assert s.count(old)==1
 s=s.replace(old,"cur_lba <= map_rd_lba;\n                    sec_need_r <= {1'b0,skip_bytes[31:9]};")
 s=s.replace('                S_MAP_CHECK: begin',
  "                S_MAP_CHECK: begin\n                    cur_lba <= prepared_lba_sum;")
 s=s.replace('                S_BURST: begin',
  "                S_BURST: begin\n                    sec_need_r <= burst_nsec; // Old ceil operand is dead after S_CALC.")
 old="cur_lba  <= cur_lba + {16'd0, burst_nsec};";assert s.count(old)==1
 s=s.replace(old,'cur_lba <= prepared_lba_sum;')
 s=s.replace('    reg [23:0] sec_need_r;',
  "    wire [31:0] prepared_lba_sum=cur_lba+{8'd0,sec_need_r};\n    reg [23:0] sec_need_r;")
 # Declare the referenced word first, to avoid implicit Verilog scalar nets.
 s=s.replace("    wire [31:0] prepared_lba_sum=cur_lba+{8'd0,sec_need_r};\n    reg [23:0] sec_need_r;",
  "    reg [23:0] sec_need_r;\n    wire [31:0] prepared_lba_sum=cur_lba+{8'd0,sec_need_r};")
f.write_text(s,encoding='utf-8')
