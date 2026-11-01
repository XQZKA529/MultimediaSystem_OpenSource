"""Compose frozen independently verified CLOCK/Text palette and DDC changes."""
import argparse,hashlib,json
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--clock',type=Path,required=True);p.add_argument('--text',type=Path)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination);inputs={}
leaves=[(a.clock,'rtl/ui/clock_overlay.v')]
if a.text:leaves.append((a.text,'rtl/ui/text_osd_overlay.v'))
for origin,name in leaves:
 data=(origin/name).read_bytes();(a.destination/name).write_bytes(data)
 inputs[name]=dict(source=str((origin/name).resolve()),sha256=hashlib.sha256(data).hexdigest())
(a.destination.parent/'combined-leaves.json').write_text(json.dumps(inputs,indent=2),encoding='utf-8')
