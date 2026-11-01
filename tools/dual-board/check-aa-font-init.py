"""Check TD-mapped BRAM32K initialization against independent AA pixel atlases."""
from pathlib import Path
import argparse
import hashlib
import json
import re

ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--netlist',type=Path,required=True)
parser.add_argument('--output',type=Path,default=ROOT/'doc/dual-board/evidence/aa-font/bram-init-check.json')
args=parser.parse_args()
source=args.netlist.read_text(encoding='utf-8')
atlas_file=ROOT/'render/sim/aa-font/atlas.hex'
diag_file=ROOT/'render/sim/aa-font/diagnostic.hex'
pixels=[int(v,16) for v in atlas_file.read_text().splitlines()]
diagnostic=[int(v,16) for v in diag_file.read_text().splitlines()]

ascii_words=[sum(v << (2*i) for i,v in enumerate(pixels[start:start+8]))
             for start in range(0,len(pixels),8)]
ascii_words += [0]*(2048-len(ascii_words))
diag_words=[0]*2048
codes=sorted(set(map(ord,'0123456789EROWAITDLNK')))
for glyph,code in enumerate(codes,1):
    for y in range(21):
        for x in range(15):
            diag_words[glyph*64+y*2+x//8] |= diagnostic[(code-32)*315+y*15+x] << ((x%8)*2)
expected={'u_shared_font/u_ascii_bram32':ascii_words,
          'u_error_overlay/u_diag_bram32':diag_words}
pattern=r'EG_PHY_BRAM32K\s*#\((.*?)\)\s*\\?u_render/(u_shared_font/u_ascii_bram32|u_error_overlay/u_diag_bram32)\s*\('
banks=re.findall(pattern,source,re.S)
assert len(banks)==2, f'Expected two dedicated font BRAM32K instances, found {len(banks)}'
for parameters,name in banks:
    pages=re.findall(r"\.INIT_([0-9A-F]{2})\(256'([bh])([0-9A-Fa-f]+)\)",parameters)
    assert len(pages)==128, f'Expected 128 INIT pages for {name}, found {len(pages)}'
    assert len({p for p,base,v in pages})==len(pages), f'Duplicate INIT page for {name}'
    # Unspecified INIT pages default to zero in the vendor primitive.
    packed=sum(int(v,2 if base=='b' else 16) << (int(p,16)*256) for p,base,v in pages)
    for address,value in enumerate(expected[name]):
        got=(packed>>(address*16)) & 65535
        assert got==value, f'BRAM32K mismatch {name} word {address}: {got:04x} != {value:04x}'
result={'status':'PASS','bram32k':len(banks),'checked_initialization_bits':65536,
        'ascii_glyphs':95,'diagnostic_glyphs':len(codes),
        'mapped_gate_netlist_sha256':hashlib.sha256(args.netlist.read_bytes()).hexdigest(),
        'atlas_sha256':hashlib.sha256(atlas_file.read_bytes()).hexdigest(),
        'diagnostic_atlas_sha256':hashlib.sha256(diag_file.read_bytes()).hexdigest(),
        'font_rom_sha256':hashlib.sha256((ROOT/'render/rtl/ui/font_rom.v').read_bytes()).hexdigest()}
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print('PASS: 65536 mapped font BRAM32K INIT bits match independent ASCII/diagnostic pixel atlases.')
