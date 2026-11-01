"""Retain only exact validation results for fixed BPS and MBR type bytes.

Unreset capture edges remain unchanged, including partial/repeated streams.
No LBA, size, geometry arithmetic or protocol field is narrowed.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
pairs=[('reg [7:0]  mbr_work_type;','reg mbr_work_isfat;'),
       ('2:mbr_work_type<=blk_data_i;','2:mbr_work_isfat<=is_fat32_type(blk_data_i);'),
       ('is_fat32_type(mbr_work_type)','mbr_work_isfat'),
       ('reg [15:0] bpb_bps, bpb_tot16;','reg [15:0] bpb_tot16;\nreg bpb_bps_low_bad,bpb_bps_high_bad;\nwire bpb_bps_bad=bpb_bps_low_bad || bpb_bps_high_bad;'),
       ('11:bpb_bps[7:0]<=blk_data_i; 12:bpb_bps[15:8]<=blk_data_i;',
        "11:bpb_bps_low_bad<=blk_data_i!=8'd0; 12:bpb_bps_high_bad<=blk_data_i!=8'd2;"),
       ('(bpb_bps==512)','(!bpb_bps_bad)'),('bpb_bps!=512','bpb_bps_bad')]
for old,new in pairs:
 assert s.count(old)==1,old;s=s.replace(old,new)
f.write_text(s,encoding='utf-8')
