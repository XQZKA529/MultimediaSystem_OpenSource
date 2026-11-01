"""Check every archived file hash and the explicit experimental status."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

p=argparse.ArgumentParser()
p.add_argument('archive',type=Path)
args=p.parse_args()
with zipfile.ZipFile(args.archive) as z:
    manifest=json.loads(z.read('manifest.json'))
    assert manifest['status']=='EXPERIMENTAL_CHECKPOINT'
    assert manifest['formal_qualification'] is False
    for name,digest in manifest['files'].items():
        assert hashlib.sha256(z.read(name)).hexdigest()==digest,name
    actual={i.filename for i in z.infolist() if not i.is_dir()}
    assert actual==set(manifest['files'])|{'manifest.json'}
    for board,report in manifest['boards'].items():
        assert report['experiment_pass'] and report['hold_endpoints']==0 and report['htns']==0
        bit=f'MultimediaSystem_{board}_RESOURCE_TRIAL.bit'
        assert hashlib.sha256(z.read(bit)).hexdigest()==report['bit_sha256']
        inputs=json.loads(z.read(f'evidence/{board}/inputs.json'))
        for name,digest in inputs.items():
            assert hashlib.sha256(z.read(f'source/{board}/{name}')).hexdigest()==digest,(board,name)
    for alt in manifest.get('alternatives',[]):
        assert alt['report']['experiment_pass'] and alt['report']['formal_timing_pass']
        assert hashlib.sha256(z.read(alt['file'])).hexdigest()==alt['report']['bit_sha256']
        prefix=alt.get('source_prefix','source/'+alt['board'])
        inputs=json.loads(z.read(str(Path(alt['file']).parent).replace('\\','/')+'/inputs.json'))
        for name,digest in inputs.items():
            assert hashlib.sha256(z.read(prefix+'/'+name)).hexdigest()==digest,(prefix,name)
    print(f'PASS: {len(manifest["files"])} archived files, exact measured source/bit hashes; target_complete={manifest["target_complete"]}')
