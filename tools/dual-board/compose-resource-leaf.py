"""Freeze a board and compose explicitly named independently measured RTL leaves."""
import argparse,hashlib,json
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--leaf',type=Path,required=True);p.add_argument('--file',action='append',required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args()
for name in a.file:
 assert name.startswith('rtl/') and '..' not in Path(name).parts
 assert (a.leaf/name).is_file() and (a.source/name).is_file()
snapshot(a.source,a.destination);manifest={}
for name in a.file:
 data=(a.leaf/name).read_bytes();(a.destination/name).write_bytes(data)
 manifest[name]=dict(source=str((a.leaf/name).resolve()),sha256=hashlib.sha256(data).hexdigest())
(a.destination.parent/'composed-leaves.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
