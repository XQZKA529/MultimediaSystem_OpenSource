"""Read-only baseline, local dependency and package audit."""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[2]
fail=[]
baseline=json.loads((ROOT/'doc/dual-board/baseline.sha256.json').read_text())
for name,want in baseline.items():
    p=ROOT/name
    if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=want:fail.append('Baseline changed: '+name)
for board in ['media','render']:
    root=ROOT/board
    manifest=(root/'build/sources.txt').read_text().splitlines()
    for name in manifest:
        p=(root/name).resolve()
        if not p.is_relative_to(root.resolve()) or not p.is_file():fail.append('Source escapes/missing: '+str(p))
    for project in root.glob('*.al'):
        # Native TD writes literal '&' in UsedInP&R attributes, so .al is
        # accepted by TD but is not strict XML. Inspect only source paths.
        source_section=project.read_text(encoding='utf-8').split('<Source_Files>')[1].split('</Source_Files>')[0]
        for name in re.findall(r'<File\s+Path="([^"]+)"',source_section):
            p=(root/name).resolve()
            if Path(name).is_absolute() or not p.is_relative_to(root.resolve()) or not p.is_file():
                fail.append('Native project dependency escapes/missing: '+str(project)+' => '+name)
    if (root/'rtl/pkg/board_link.vh').read_bytes()!=(ROOT/'media/rtl/pkg/board_link.vh').read_bytes():
        fail.append('Protocol definitions differ: '+board)
    if (root/'doc/protocol-v1.md').read_bytes()!=(ROOT/'doc/dual-board/protocol-v1.md').read_bytes():
        fail.append('Protocol document differs: '+board)
    for p in list((root/'rtl').rglob('*'))+list((root/'diag').glob('*.v')):
        if p.suffix not in ['.v','.vh']:continue
        s=p.read_text(encoding='utf-8',errors='replace')
        s=re.sub(r'/\*.*?\*/|//[^\n]*','',s,flags=re.S)
        for inc in re.findall(r'`include\s+"([^"]+)"',s):
            target=(p.parent/inc).resolve()
            if not target.is_relative_to(root.resolve()) or not target.is_file():fail.append('Include escapes/missing: '+str(p)+' => '+inc)
    for p in list((root/'build').glob('*.ps1'))+list((root/'build').glob('*.tcl')):
        s=p.read_text(encoding='utf-8')
        if re.search(r'(\.\.[/\\])+(?:rtl|media|render)[/\\]',s):fail.append('External build dependency: '+str(p))
    print(board,':',len(manifest),'local source/IP/constraint entries')
if fail:raise SystemExit('\n'.join(fail))
print('PASS: baseline hashes unchanged; both boards have only local design dependencies')
