"""Record actual top-level source dependency closures, separately for each board."""
from pathlib import Path
import re,json,argparse
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--board',choices=['media','render'])
p.add_argument('--modules-only',action='store_true',help='Refresh metadata without changing the measured source order')
a=p.parse_args()
for board in ([a.board] if a.board else ['media','render']):
    root=ROOT/board
    defs={};texts={}
    for p in list((root/'rtl').rglob('*.v'))+list((root/'al_ip').glob('*_gate.v')):
        s=p.read_text(encoding='utf-8',errors='replace')
        s=re.sub(r'/\*.*?\*/|//[^\n]*','',s,flags=re.S)
        texts[p]=s
        for name in re.findall(r'\bmodule\s+(\w+)',s):defs[name]=p
    visited=set();pending=[f'top_{board}'];files=set()
    while pending:
        name=pending.pop()
        if name in visited:continue
        visited.add(name)
        if name not in defs:raise RuntimeError('Missing module '+name)
        p=defs[name];files.add(p)
        for candidate in defs:
            if re.search(r'\b'+re.escape(candidate)+r'\b\s*(?:#\s*\([\s\S]*?\)\s*)?\w+\s*\(',texts[p]):
                pending.append(candidate)
    # The generated gate implementation and its IP configuration travel together.
    # Encrypted source dependencies are invisible to a text parser.
    if board=='render':
        files.update(root/'rtl/sdram'/name for name in ['sdr_init_ref.enc.v','sdr_wrrd.enc.v'])
    if root/'al_ip/TEMAC_CORE_gate.v' in files:
        files.remove(root/'al_ip/TEMAC_CORE_gate.v');files.add(root/'al_ip/TEMAC_CORE.ipc')
    sources=sorted(p.relative_to(root).as_posix() for p in files)
    sources+=[f'constr/{board}.adc',f'constr/{board}.sdc']
    if not a.modules_only:(root/'build/sources.txt').write_text('\n'.join(sources)+'\n',encoding='utf-8')
    (root/'build/modules.json').write_text(json.dumps(sorted(visited),indent=2),encoding='utf-8')
    if a.modules_only:print(board,len(visited),'modules; measured source list unchanged')
    else:print(board,len(sources),'sources,',len(visited),'modules')
