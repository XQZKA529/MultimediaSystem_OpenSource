"""Certify reuse only when every compiled/source/fixture/model byte is identical.

This is a component certificate, never a whole-board or fresh simulation PASS.
Changed components still require their own new simulation and physical checks.
"""
import argparse,hashlib,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--evidence',type=Path,required=True)
p.add_argument('--old-root',type=Path,required=True);p.add_argument('--new-root',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args()
e=a.evidence.resolve();old=a.old_root.resolve();new=a.new_root.resolve();dest=a.destination.resolve()
if dest.exists():raise RuntimeError('Reuse certificate must be new')
result=json.loads((e/'result.json').read_text());inputs=json.loads((e/'inputs.json').read_text())
def sha(f):return hashlib.sha256(f.read_bytes()).hexdigest()
assert result['status']=='PASS' and result['inputs_stable']
assert sha(e/'simulate.log')==result['log_sha256']
mapped={}
for name,digest in inputs.items():
 source=Path(name);target=new/source.relative_to(old) if source.is_relative_to(old) else source
 if not source.is_file() or sha(source)!=digest or not target.is_file() or sha(target)!=digest:
  raise RuntimeError(f'Component dependency changed: {source} -> {target}')
 mapped[str(target)]=digest
dest.parent.mkdir(parents=True,exist_ok=True)
dest.write_text(json.dumps(dict(status='IDENTICAL_COMPONENT_INPUTS',original_evidence=str(e),
 original_result_sha256=sha(e/'result.json'),original_inputs_sha256=sha(e/'inputs.json'),
 original_invocation=json.loads((e/'invocation.json').read_text()),original_log_sha256=result['log_sha256'],
 candidate_inputs=mapped),indent=2),encoding='utf-8')
print(f'PASS byte-identical component reuse: {len(mapped)} dependencies; original simulation {e}; certificate {dest}')
