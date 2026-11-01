"""Remove resets only from private data initialized before its owner can use it.

Keep every public output, validity/error flag, pending queue and CDC reset.
Read requests initialize index/watchdog in start_buffer_read. DBR initializes
cluster geometry before validation; GEOM5 captures derived geometry before
mount_ok. LBA2, MAP_ACC and EMIT_ADDR initialize their working fields before
any corresponding use. root_cluster and partial boot fields keep their reset
semantics: malformed/partial boot input may depend on them.
"""
import argparse,re,json
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
fields=dict(rd_index='start_buffer_read before S_RD_REQ',io_timeout='start_buffer_read before S_RD_REQ',
 sectors_per_cluster='S_MOUNT_DBR before geometry validation',cluster_shift='S_MOUNT_DBR before geometry validation',
 cluster_shift_bad='S_MOUNT_DBR before geometry validation',bytes_per_cluster='S_MOUNT_GEOM5 before mounted work',
 spc_nsec='S_MOUNT_GEOM5 before mounted work',map_cluster_prev_p1='S_MAP_ACC before map_have_run consumption',
 map_cur_lba='S_MAP_LBA2 before DIR_READ, FILE_ISSUE or MAP_ACC',name_rd_addr='S_EMIT_ADDR before EMIT_WAIT/NAME')
start=s.index('    control_state<=S_IDLE; active_op<=0;')
end=s.index('  end else begin',start)
reset=s[start:end]
for name in fields:
 reset,n=re.subn(r'\b'+name+r'<=0;\s*','',reset);assert n==1,name
s=s[:start]+reset+s[end:]
f.write_text(s,encoding='utf-8')
(a.destination.parent/'private-reset-lifetimes.json').write_text(json.dumps(dict(
    owners=fields,public_resets_changed=False,pending_resets_changed=False,latency_changed=False),indent=2),encoding='utf-8')
