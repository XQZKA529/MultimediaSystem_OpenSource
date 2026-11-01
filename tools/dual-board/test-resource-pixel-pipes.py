"""Independent full-frame pixel oracles for BRAM pixel pipeline candidates."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--test',choices=['tb_text_osd_overlay','tb_ui_text_overlay','tb_clock_overlay'])
p.add_argument('--frame-digits',action='store_true',help='Exercise the production CLOCK formatter parameter')
p.add_argument('--native-only',action='store_true')
p.add_argument('--first-case',type=int,default=0)
p.add_argument('--last-case',type=int,default=10)
a=p.parse_args();b=a.candidate.resolve()
tests={
 'tb_text_osd_overlay':['ui/font_rom.v','ui/text_osd_overlay.v'],
 'tb_ui_text_overlay':['ui/font_rom.v','ui/ui_text_overlay.v'],
 'tb_clock_overlay':['ui/clock_overlay.v','ui/volume_overlay.v','ui/font_rom.v',
                     'emergency/emergency_overlay.v','video/error_overlay.v']}
for top,rtl in tests.items():
 if a.test and top!=a.test:continue
 testbench=b/'sim'/(top+'.v')
 if a.frame_digits:
    if top!='tb_clock_overlay':continue
    generated=b.parent/'clock-frame-digits-oracle'/f'cases_{a.first_case}_{a.last_case}';generated.mkdir(parents=True,exist_ok=True)
    text=testbench.read_text(encoding='utf-8-sig')
    assert 'clock_overlay dut(' in text
    testbench=generated/'tb_clock_overlay_frame_digits.v'
    testbench.write_text(text.replace('clock_overlay dut(','clock_overlay #(.FRAME_DIGITS(1)) dut('),encoding='utf-8')
 for native in ((True,) if a.native_only else (False,True)):
    base=b.parent/('clock-frame-digits-oracle' if a.frame_digits else 'pixel-pipe-oracle')
    if a.frame_digits:base=base/f'cases_{a.first_case}_{a.last_case}'
    simulate(base/top/('native' if native else 'behavioral'),top,
             [*[b/'rtl'/r for r in rtl],testbench],
             includes=[b/'rtl',b/'rtl/ui',b/'sim'],native=True,
             defines=[] if native else ['DB_BEHAVIORAL_RAM'],
             plus=['+AA_ATLAS='+str(b/'sim/aa-font/atlas.hex')]+(
                  [f'-gFIRST_CASE={a.first_case}',f'-gLAST_CASE={a.last_case}'] if top=='tb_clock_overlay' else []))
