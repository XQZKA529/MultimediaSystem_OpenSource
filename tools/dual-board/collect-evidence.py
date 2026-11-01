"""Collect verified reports and pair fingerprints; never publish a stale bit."""
from pathlib import Path
import argparse, hashlib, json, shutil
ROOT=Path(__file__).resolve().parents[2]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def collect(board, run, kind):
    root=ROOT/board
    run=ROOT/run
    result=json.loads((run/'qualification.json').read_text(encoding='utf-8-sig'))
    if (result['setup_wns_ns']<.100 or result['setup_tns_ns']!=0 or
        result['hold_wns_ns']<0 or result['hold_tns_ns']!=0 or
        result['slice_percent']>80 or result['bram9k']>56):
        raise ValueError('Unqualified report: '+str(run))
    inputs=json.loads((run/'inputs.json').read_text(encoding='utf-8-sig'))
    for name, expected in inputs.items():
        p=(root/name).resolve()
        if not p.is_relative_to(root.resolve()) or not p.is_file() or sha(p)!=expected:
            raise ValueError('Stale input: '+str(p))
    project='MultimediaSystem_'+board+('_linktest' if kind=='prbs' else '')
    bit=run/(project+'.bit')
    if sha(bit)!=result['bit_sha256']: raise ValueError('Bit fingerprint mismatch: '+str(bit))
    dest=root/'doc/evidence'/kind
    dest.mkdir(parents=True,exist_ok=True)
    for name in ['qualification.json','inputs.json','final.qor',project+'_phy.ts',project+'_pr.timing','settings.cfg']:
        shutil.copyfile(run/name,dest/name)
    result.update(kind=kind,run=str(run.relative_to(ROOT)).replace('\\','/'),
        bit=str(bit.relative_to(ROOT)).replace('\\','/'),
        inputs_sha256=sha(run/'inputs.json'),settings_sha256=sha(run/'settings.cfg'))
    return result
parser=argparse.ArgumentParser()
parser.add_argument('--media',required=True)
parser.add_argument('--render',required=True)
parser.add_argument('--media-prbs',required=True)
parser.add_argument('--render-prbs',required=True)
args=parser.parse_args()
records=[]
# Verify every candidate before copying any release manifest.
for board, run, kind in [('media',args.media,'production'),('render',args.render,'production'),
                         ('media',args.media_prbs,'prbs'),('render',args.render_prbs,'prbs')]:
    records.append(collect(board,run,kind))
manifest=dict(protocol='1.0',tool='Tang Dynasty 6.2.168116',device='EG4S20BG256',
              status='tool-qualified; hardware acceptance pending',boards=records)
(ROOT/'doc/dual-board/release-pair.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
for board in ['media','render']:
    (ROOT/board/'doc/release-pair.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('PASS: report/input/bit fingerprints verified; paired production + PRBS evidence collected')
