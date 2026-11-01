"""Independent masks for the full alarm frame, order, date/time and clock plate."""
import hashlib
import json
import re
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / 'build/emergency-time-v1'
FRAMES = WORK / 'frames'
PREVIEW = WORK / 'preview'
PREVIEW.mkdir(parents=True, exist_ok=True)
CODES = [0x001,0x002,0x003,0x004,0x005,0x006,0x007,0x00a,0x00c,0x00e,
         0x011,0x014,0x015,0x01c,0x021,0x022,0x023,0x02a,0x031,0x054,
         0x062,0x08c,0x0a1,0x10a,0x111]
LABELS = ['B0','B1','C ']
TIMES = ['2026-10-14 15:30:01','2000-02-29 23:59:59','2099-01-01 00:00:00']
GLYPHS = {
 'B':['11110','10001','10001','11110','10001','10001','11110'],
 'C':['01111','10000','10000','10000','10000','10000','01111'],
 '0':['01110','10001','10011','10101','11001','10001','01110'],
 '1':['00100','01100','00100','00100','00100','00100','01110'],
 '2':['01110','10001','00001','00010','00100','01000','11111'],
 '3':['11110','00001','00001','01110','00001','00001','11110'],
 '4':['00010','00110','01010','10010','11111','00010','00010'],
 '5':['11111','10000','10000','11110','00001','00001','11110'],
 '6':['01110','10000','10000','11110','10001','10001','01110'],
 '7':['11111','00001','00010','00100','01000','01000','01000'],
 '8':['01110','10001','10001','01110','10001','10001','01110'],
 '9':['01110','10001','10001','01111','00001','00001','01110'],
 '-':['00000','00000','00000','11111','00000','00000','00000'],
 ':':['00000','00100','00100','00000','00100','00100','00000'],
 '=':['00000','00000','11111','00000','11111','00000','00000'],
 '>':['00000','00100','00010','11111','00010','00100','00000']}

def text_mask(mask, text, left, top):
    for i,c in enumerate(text):
        for row,bits in enumerate(GLYPHS.get(c, [])):
            for col,bit in enumerate(bits):
                if bit == '1':
                    xx=left+i*16+2+col*2; yy=top+4+row*2
                    mask[yy:yy+2,xx:xx+2]=True

def records(code):
    groups=[(code>>(3*i))&7 for i in range(3)]
    rows=[s for g in groups for s in range(3) if g&(1<<s)]
    seq=' > '.join(' = '.join(LABELS[s].strip() for s in range(3) if g&(1<<s)) for g in groups if g)
    return groups,rows,seq

def whites(code,times):
    _,rows,seq=records(code)
    mask=np.zeros((720,1280),dtype=bool)
    text_mask(mask,seq,640-len(seq)*8,580)
    for i,s in enumerate(rows):text_mask(mask,LABELS[s]+' '+times[s],464,612+32*i)
    return mask

def picture(code):
    groups,_,_=records(code);m=groups[0]|groups[1]|groups[2]
    combined=bool(m&4 and m&3);cy=440 if combined else 360
    x,y=np.meshgrid(np.arange(1280),np.arange(720));dy=abs(y-cy)
    left=440 if combined else 480;right=840 if combined else 800
    slope=dy*2 if combined else dy+dy//2
    shaft=bool(m&3)&(x>=(left if m&1 else 240))&(x<(right if m&2 else 1040))&(dy<(40 if combined else 64))
    arrow=shaft|(bool(m&1)&(x>=240)&(x<left)&(dy<(100 if combined else 160))&(x-240>slope))
    arrow|=bool(m&2)&(x>=right)&(x<1040)&(dy<(100 if combined else 160))&(1040-x>slope)
    ty=y-(100 if combined else 160);dx=abs(x-640)
    width=ty+ty//4 if combined else ty+ty//8+ty//16
    triangle=(width>=2*dx)&((width-2*dx<12)|(ty>=(192 if combined else 332)))
    mark=(dx<(8 if combined else 12))&(((ty>=(45 if combined else 70))&(ty<(130 if combined else 230)))|((ty>=(154 if combined else 270))&(ty<(172 if combined else 292))))
    warning=bool(m&4)&(ty>=0)&(ty<(200 if combined else 340))&(triangle|mark)
    out=np.zeros((720,1280,3),dtype=np.uint8);out[arrow|warning]=[255,0,0];out[whites(code,TIMES)]=255
    return out

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

# Enumerate all nonempty, disjoint ordered groups independently of the RTL.
valid=set()
for a in range(1,8):
 for b in range(8):
  for c in range(8):
   if a&b or a&c or b&c or (not b and c):continue
   valid.add(a|(b<<3)|(c<<6))
assert set(CODES)==valid and len(valid)==25
# Independently check all fixed font rows, including digits 7/8 not present
# in the intentionally varied full-frame calendar fixtures.
rtl=(ROOT/'render/rtl/emergency/emergency_overlay.v').read_text(encoding='utf-8')
font=dict((int(k,16),int(v,2)) for k,v in re.findall(r"12'h([0-9a-f]+):glyph_row=5'b([01]{5})",rtl))
for ch,rows in GLYPHS.items():
    code=127 if ch=='>' else ord(ch)
    for row in range(16):
        want=int(rows[row-2],2) if 2<=row<=8 else 0
        assert font.get((code<<4)|row,0)==want,(ch,row)
report={'pass':True,'font_rows_checked':len(GLYPHS)*16,'alarm_frames':[],'clock_frames':[],'pixels_checked':0,'hardware_acceptance':'pending'}
for i,code in enumerate(CODES,1):
    p=FRAMES/f'emergency_{i}.ppm';actual=np.asarray(Image.open(p).convert('RGB'));expected=picture(code)
    if not np.array_equal(actual,expected):
        mismatch=np.argwhere(np.any(actual!=expected,axis=2));y,x=mismatch[0]
        raise AssertionError((i,hex(code),int(x),int(y),actual[y,x].tolist(),expected[y,x].tolist(),len(mismatch)))
    Image.fromarray(actual).save(p.with_suffix('.png'))
    _,rows,seq=records(code)
    report['alarm_frames'].append({'case':i,'groups':code,'sequence':seq,'rows':[LABELS[s]+' '+TIMES[s] for s in rows],'sha256':sha(p)})
    report['pixels_checked']+=1280*720
atlas=[int(v,16) for v in (ROOT/'render/sim/aa-font/atlas.hex').read_text().split()]
for case in range(11):
    p=FRAMES/f'clock_case_{case}.ppm';img=Image.open(p).convert('RGB');assert img.size==(1280,720)
    for y in range(8,60):
     for x in range(8,144):
      bg=(0,0,0) if 1<=case<=7 else (x&255,y&255,165)
      color=tuple(v//2 for v in bg)
      if x in (8,143) or y in (8,59):color=(148,148,148)
      else:
       text='';dx=dy=0
       if 16<=x<136 and 16<=y<32:text='2026-10-14';dx=x-16;dy=y-16
       elif 16<=x<112 and 36<=y<52:text='12:34:56';dx=x-16;dy=y-36
       if text:
        gx,gy=dx%12,dy;cov=atlas[(ord(text[dx//12])-32)*140+gy*10+gx] if gx<10 and gy<14 else 0
        weight=(0,1,3,4)[cov];color=tuple((255*weight+(v//2)*(4-weight))//4 for v in bg)
      assert img.getpixel((x,y))==color,(case,x,y,img.getpixel((x,y)),color)
    if 1<=case<=7:
        a=np.asarray(img);mask=np.all(a==255,axis=2)
        assert np.array_equal(mask[580:],whites(case,['2026-10-14 12:34:56']*3)[580:]),case
    img.save(p.with_suffix('.png'));report['clock_frames'].append({'case':case,'sha256':sha(p)});report['pixels_checked']+=136*52
Image.open(FRAMES/'clock_case_7.png').save(PREVIEW/'emergency-clock.png')
Image.open(FRAMES/'emergency_7.png').crop((440,572,840,710)).resize((800,276)).save(PREVIEW/'timestamp-crop.png')
sheet=Image.new('RGB',(1280,4*390),(24,24,24));draw=ImageDraw.Draw(sheet)
for i in range(7):
    x=(i%2)*640;y=(i//2)*390
    sheet.paste(Image.open(FRAMES/f'emergency_{i+1}.png').resize((640,360)),(x,y))
    draw.text((x+8,y+364),records(CODES[i])[2],fill='white')
sheet.save(PREVIEW/'emergency-combinations.png')
report['inputs']={p.relative_to(ROOT).as_posix():sha(p) for p in [ROOT/'render/rtl/emergency/emergency_overlay.v',ROOT/'render/sim/tb_emergency_overlay.v',ROOT/'render/sim/tb_clock_overlay.v',Path(__file__).resolve()]}
report['evidence']={p.relative_to(WORK).as_posix():sha(p) for p in sorted(FRAMES.glob('*.ppm'))}
(WORK/'visual-check.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('PASS 25 complete alarm frames, 11 clock frames, all timestamp/sequence glyphs:',report['pixels_checked'],'pixels')
