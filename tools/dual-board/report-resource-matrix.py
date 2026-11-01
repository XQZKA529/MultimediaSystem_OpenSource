"""Inventory actual final reports, including rejected and incomplete attempts."""
import argparse
import contextlib
import io
import json
from pathlib import Path
import re
from resource_experiment import report

ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser()
p.add_argument('--experiments',type=Path,default=ROOT/'build/resource-v1')
args=p.parse_args()
rows=[]
for run in sorted(args.experiments.glob('*/[mr]*/Runs/phy_*')):
    board=run.parents[1].name
    if board not in ('media','render'):continue
    row=dict(candidate=run.parents[2].name,board=board,run=run.name)
    if (run/'final.qor').exists() and (run/f'MultimediaSystem_{board}_pr.db').exists():
        try:
            with contextlib.redirect_stdout(io.StringIO()):report(board,run)
            row.update(json.loads((run/'resource-experiment.json').read_text(encoding='utf-8')))
            row['physical_path']=row['run']
            row['run']=run.name
            row['status']='pass' if row['experiment_pass'] else 'rejected'
        except Exception as e:
            row.update(status='invalid_evidence',reason=str(e))
    else:
        log=(run/'console.txt').read_text(errors='replace') if (run/'console.txt').exists() else ''
        errors=re.findall(r'(?m)^.*(?:ERROR|FATAL|Oops! coredump|(?:MSlice|LSlice).*exceed).*$' ,log)
        row.update(status='failed' if errors or list(run.glob('*.error.f')) else 'incomplete',reason='; '.join(errors[-3:]))
    rows.append(row)
# A compiler crash can stop before the physical directory exists. Retain it
# explicitly rather than making that attempted candidate disappear from the table.
for run in sorted(args.experiments.glob('*/[mr]*/Runs/syn_*')):
    board=run.parents[1].name
    if board not in ('media','render'):continue
    if any(run.parent.glob('phy_'+run.name[4:]+'*')):continue
    log=(run/'console.txt').read_text(errors='replace') if (run/'console.txt').exists() else ''
    errors=re.findall(r'(?m)^.*(?:ERROR|FATAL|Oops! coredump).*$',log)
    if errors or list(run.glob('*.error.f')):
        rows.append(dict(candidate=run.parents[2].name,board=board,run=run.name,
                         stage='synthesis',status='failed',reason='; '.join(errors[-3:])))
dest=args.experiments/'candidate-matrix.json'
# A fixed-gate PASS alone does not mean lower final area or promotion.
selected={}
for board in ('media','render'):
    promotion=args.experiments/f'promoted-{board}.json'
    if promotion.exists():
        selected[board]=Path(json.loads(promotion.read_text())['physical_run']).resolve()
for row in rows:
    row['retained']=bool(row.get('experiment_pass') and row.get('physical_path')
                         and Path(row['physical_path']).resolve()==selected.get(row['board']))
dest.write_text(json.dumps(rows,ensure_ascii=False,indent=2),encoding='utf-8')
lines=['`pass` means the fixed experimental gates passed; retention also requires lower final area and complete regression. See the experiment record for rejected or superseded candidates.','',
       '| Candidate | Board | Run | Slice | Setup WNS / TNS (ns) | Setup EP | Hold WNS / EP | BRAM9K / 32K | Status | Retained |',
       '|---|---|---|---:|---:|---:|---:|---:|---|---|']
for r in rows:
    metrics=(f"{r['slices']} | {r['swns']:.3f} / {r['stns']:.3f} | {r['setup_endpoints']} | {r['hwns']:.3f} / {r['hold_endpoints']} | {r['bram9k']+r['fifo9k']} / {r['bram32k']}" if 'slices' in r else '— | — | — | — | —')
    lines.append(f"| {r['candidate']} | {r['board']} | {r['run']} | {metrics} | {r['status']} | {'current' if r['retained'] else '—'} |")
(args.experiments/'candidate-matrix.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
print(f'{len(rows)} implementation attempts inventoried: {dest}')
