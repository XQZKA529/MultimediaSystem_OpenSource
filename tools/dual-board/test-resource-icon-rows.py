"""Check full menu frames with behavioral and native dictionary/bitmap ROMs."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
a=p.parse_args();b=a.candidate.resolve()
for native in (False,True):
 simulate(b.parent/'icon-row-oracle'/('native' if native else 'behavioral'),'tb_ui_text_overlay',
          [b/'rtl/ui/font_rom.v',b/'rtl/ui/ui_text_overlay.v',b/'sim/tb_ui_text_overlay.v'],
          includes=[b/'rtl',b/'rtl/ui',b/'sim'],native=True,
          defines=[] if native else ['DB_BEHAVIORAL_RAM'],
          plus=['+AA_ATLAS='+str(b/'sim/aa-font/atlas.hex')])
