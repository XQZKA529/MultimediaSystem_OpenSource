"""Check exported full frames and all fixed alarm sequence layouts."""
import json, re, hashlib
from pathlib import Path
from PIL import Image, ImageDraw
import numpy as np
ROOT = Path(__file__).resolve().parents[2]
FRAMES = ROOT / 'build/emergency-gpio/frames'
GLYPHS = {
 'B': ['11110','10001','10001','11110','10001','10001','11110'],
 '0': ['01110','10001','10011','10101','11001','10001','01110'],
 '1': ['00100','01100','00100','00100','00100','00100','01110'],
 'C': ['01111','10000','10000','10000','10000','10000','01111'],
 '→': ['00000','00100','00010','11111','00010','00100','00000'],
 '=': ['00000','00000','11111','00000','11111','00000','00000'],
}
LABELS = ['B0','B1','C']
CODES = {' ':0,'B':1,'0':2,'1':3,'C':4,'→':5,'=':6}
def sequence(groups):
    return ' → '.join(' = '.join(LABELS[s] for s in range(3) if g & (1<<s)) for g in groups if g)
def white_reference(text):
    mask = np.zeros((720,1280), dtype=bool)
    left = 640 - len(text)*8
    for i, c in enumerate(text):
        for row, bits in enumerate(GLYPHS.get(c, [])):
            for col, bit in enumerate(bits):
                if bit == '1': mask[584+row*2:586+row*2,left+i*16+2+col*2:left+i*16+4+col*2] = True
    return mask
rtl = (ROOT/'render/rtl/emergency/emergency_overlay.v').read_text(encoding='utf-8')
layouts = re.findall(r"9'h([0-9a-f]+): layout=48'h([0-9a-f]+)",rtl)
assert len(layouts) == 25, len(layouts)
for encoded, value in layouts:
    code = int(encoded,16); groups = [(code>>(3*i))&7 for i in range(3)]
    seen = 0
    for g in groups:
        assert not seen & g
        seen |= g
    text = sequence(groups)
    expected = (len(text)<<44) | sum(CODES[c]<<(4*i) for i,c in enumerate(text))
    assert int(value,16) == expected, (groups,text)
records = []
sheet = Image.new('RGB',(1280,4*390),(24,24,24)); draw=ImageDraw.Draw(sheet)
for mask in range(1,8):
    img=Image.open(FRAMES/f'emergency_{mask}.ppm').convert('RGB'); a=np.asarray(img)
    assert img.size == (1280,720)
    black=np.all(a==0,axis=2);red=np.all(a==[255,0,0],axis=2);white=np.all(a==255,axis=2)
    assert np.all(black|red|white)
    text=sequence([mask])
    assert np.array_equal(white,white_reference(text)), (mask,'sequence glyph pixels')
    # Direction tips and warning/shaft are separated spatially.
    cy=440 if mask>=5 else 360
    assert bool(red[cy+(60 if mask>=5 else 80),400]) == bool(mask&1)
    assert bool(red[cy+(60 if mask>=5 else 80),880]) == bool(mask&2)
    top=100 if mask>=5 else 160
    assert bool(red[top+80,640]) == bool(mask&4)
    img.save(FRAMES/f'emergency_{mask}.png')
    cell=((mask-1)%2)*640,((mask-1)//2)*390
    sheet.paste(img.resize((640,360)),cell)
    draw.text((cell[0]+12,cell[1]+364),f'Sources: {text}',fill='white')
    records.append({'sources':mask,'sequence':text,'red_pixels':int(red.sum()),'white_pixels':int(white.sum())})
sheet.save(FRAMES/'emergency-combinations.png')
report={'full_frames':7,'pixels_checked':7*1280*720,'sequence_layouts_checked':len(layouts),'frames':records}
(FRAMES/'validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('PASS 7 full frames / 6,451,200 pixels, exact sequence glyphs, direction probes and 25 chronological layouts')

# Reuse is valid only for the exact drawing source, testbench and PASS evidence.
log=ROOT/'render/build/evidence/tb_emergency_overlay.txt'
assert '*** PASS ***' in log.read_text(encoding='utf-8')
inputs=['render/rtl/emergency/emergency_overlay.v','render/sim/tb_emergency_overlay.v']
evidence=['render/build/evidence/tb_emergency_overlay.txt']+[str(p.relative_to(ROOT)).replace('\\','/') for p in sorted(FRAMES.glob('emergency_[1-7].ppm'))]
digest=lambda name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
stamp={'inputs':{name:digest(name) for name in inputs},'evidence':{name:digest(name) for name in evidence}}
(FRAMES/'overlay-evidence.json').write_text(json.dumps(stamp,indent=2)+'\n',encoding='utf-8')
