"""Select BRAM32K for media's existing full-capacity TX packet memory.

No common link RTL, ports, clocks, pointer synchronizers or memory cycles change.
The per-instance native implementation parameter only changes physical mapping.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args()
snapshot(a.source,a.destination)
f=a.destination/'rtl/top_media.v';s=f.read_text(encoding='utf-8-sig')
assert 'db_link ' in s and s.count('endmodule')==1
s=s.replace('\nendmodule','''
`ifndef DB_BEHAVIORAL_RAM
    // Keep both independent 32-bit ports and all 2048 words. Only the native
    // RAM type changes; common link RTL and its CDC structure are identical.
    defparam u_link.u_packet_ram.u_ram.IMPLEMENT="32K";
`endif
endmodule''')
f.write_text(s,encoding='utf-8')
