"""Narrow shape arithmetic only under its existing visibility bounds.

Arrow distances are used only inside 200/240-pixel heads; slopes there are
below 256. The warning uses ty<200/340, so its maximum width is 403. A new
far-x flag rejects dx>=256 before the narrowed doubled-distance comparison.
Original coordinate wrap, text, frame commit and stream latency are retained.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/emergency/emergency_overlay.v';s=f.read_text(encoding='utf-8-sig')
assert 'reg [11:0] tri_width2,twice_dx2;' in s
s=s.replace('reg [11:0] tri_width2,twice_dx2;', 'reg [8:0] tri_width2,twice_dx2;')
s=s.replace('reg [10:0] slope2,left_distance2,right_distance2;', 'reg [7:0] slope2,left_distance2,right_distance2;')
s=s.replace('warning_bound2<=sources1[2] && ty1<(combined1 ? 200:340);', 'warning_bound2<=sources1[2] && ty1<(combined1 ? 200:340) && dx1<256;')
f.write_text(s,encoding='utf-8')
