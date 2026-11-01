"""Combine independently verified BMP/WAV leaf changes on a frozen media input."""
import argparse,hashlib,json
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--bmp',type=Path,required=True);p.add_argument('--wav',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination);inputs={}
for origin,name in [(a.bmp,'rtl/image/bmp_header_parser.v'),(a.wav,'rtl/audio/wav_header_parse.v')]:
 data=(origin/name).read_bytes();(a.destination/name).write_bytes(data)
 inputs[name]=dict(source=str((origin/name).resolve()),sha256=hashlib.sha256(data).hexdigest())
(a.destination.parent/'combined-leaves.json').write_text(json.dumps(inputs,indent=2),encoding='utf-8')
