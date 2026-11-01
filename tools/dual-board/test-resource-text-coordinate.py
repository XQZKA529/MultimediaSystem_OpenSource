"""Run the existing independent Text OSD pixel oracle against a candidate."""
import argparse
from pathlib import Path
from resource_sim import simulate

p=argparse.ArgumentParser()
p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--work-tag',default='text-coordinate-oracle')
args=p.parse_args()
b=args.candidate.resolve()
for native in (False,True):
    simulate(b.parent/args.work_tag/('native' if native else 'behavioral'),
             'tb_text_osd_overlay', [b/'rtl/ui/font_rom.v',b/'rtl/ui/text_osd_overlay.v',b/'sim/tb_text_osd_overlay.v'],
             includes=[b/'rtl',b/'rtl/ui',b/'sim'],native=native,
             defines=[] if native else ['DB_BEHAVIORAL_RAM'],
             plus=['+AA_ATLAS='+str(b/'sim/aa-font/atlas.hex')])
