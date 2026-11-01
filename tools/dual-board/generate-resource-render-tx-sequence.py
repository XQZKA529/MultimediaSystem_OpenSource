"""Use the final two render DSPs for one complete 32-bit transmit sequence."""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args()
for board in ('media','render'):snapshot(a.source/board,a.destination/board)
f=a.destination/'render/rtl/link/db_link.v';s=f.read_text(encoding='utf-8-sig')
old='if(ROLE==1)begin:transmit_dsp';assert s.count(old)==1
s=s.replace(old,'if(ROLE==1 || sequence_channel==2)begin:transmit_dsp')
f.write_text(s,encoding='utf-8')
