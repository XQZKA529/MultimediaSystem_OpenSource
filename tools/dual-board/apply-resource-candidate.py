"""Promote measured RTL while rejecting concurrent production-source changes.

Constraints, IP, clocks, build scripts and delivered artifacts are not copied.
The frozen reference must match every production RTL byte before promotion.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser()
p.add_argument('--board',choices=['media','render'],required=True)
p.add_argument('--baseline',type=Path,required=True)
p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--physical-run',type=Path,required=True)
args=p.parse_args()
report=json.loads((args.physical_run/'resource-experiment.json').read_text(encoding='utf-8'))
if not report['experiment_pass']:raise RuntimeError('Candidate failed experimental acceptance')
expected=json.loads((args.physical_run/'inputs.json').read_text(encoding='utf-8-sig'))
candidate=args.candidate.resolve()
production=ROOT/args.board
base=args.baseline.resolve()
def files(root):return {str(p.relative_to(root)).replace('\\','/'):p for p in (root/'rtl').rglob('*') if p.is_file()}
before,after,current=files(base),files(candidate),files(production)
if before.keys()!=current.keys() or any(before[k].read_bytes()!=current[k].read_bytes() for k in before):
    raise RuntimeError('Production RTL changed since freeze; refusing to overwrite it')
if before.keys()!=after.keys():raise RuntimeError('RTL file set changed; explicit source-list review required')
changes=[]
for k,path in after.items():
    digest=hashlib.sha256(path.read_bytes()).hexdigest()
    if expected.get(k)!=digest:raise RuntimeError(f'Candidate differs from measured RTL: {k}')
    if path.read_bytes()!=before[k].read_bytes():
        changes.append(dict(path=k,before=hashlib.sha256(before[k].read_bytes()).hexdigest(),after=digest))
for item in changes:shutil.copy2(after[item['path']],current[item['path']])
dest=ROOT/'build/resource-v1'/f'promoted-{args.board}.json'
dest.write_text(json.dumps(dict(board=args.board,candidate=str(candidate),physical_run=str(args.physical_run.resolve()),
                               target_complete=report['target_90_percent'],changes=changes),indent=2),encoding='utf-8')
print(json.dumps(dict(board=args.board,changed_files=[x['path'] for x in changes]),ensure_ascii=False))
