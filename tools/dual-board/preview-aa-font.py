"""720p pixel-for-pixel comparison of baseline and generated coverage fonts."""
from pathlib import Path
import importlib.util
import re
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('aa',Path(__file__).with_name('generate-aa-font.py'))
aa=importlib.util.module_from_spec(spec)
spec.loader.exec_module(aa)
old=dict((int(c),bits.replace('_','')) for c,bits in re.findall(
    r"7'd(\d+)\s*:\s*glyph_lookup\s*=\s*35'b([01_]+)",
    (ROOT/'rtl/ui/font_rom.v').read_text(encoding='utf-8')))
OUT=ROOT/'doc/dual-board/evidence/aa-font'
OUT.mkdir(parents=True,exist_ok=True)
BG=(16,16,24)


def text(im,label,x,y,fg=(224,224,224),scale=2,new=True,bg=BG):
    for c in label:
        if new:
            w,h=(10,14) if scale==2 else (15,21)
            pixels=aa.raster(ord(c)) if scale==2 else aa.raster(ord(c),15,21,24,19)
        else:
            w,h=5*scale,7*scale
            bits=old.get(ord(c),'0'*35)
            pixels=[int(bits[(py//scale)*5+px//scale])*3 for py in range(h) for px in range(w)]
        for py in range(h):
            for px in range(w):
                a=pixels[py*w+px]
                im.putpixel((x+px,y+py),tuple((f*a+b*(3-a)+1)//3 for f,b in zip(fg,bg)))
        x+=6*scale


def panel(im,x,y,new):
    d=ImageDraw.Draw(im)
    d.rectangle((x,y,x+387,y+147),fill=(128,132,144))
    d.rectangle((x+2,y+2,x+385,y+145),fill=BG)
    d.rectangle((x+2,y+34,x+385,y+49),fill=(48,80,144))
    lines=['SETTINGS  -  FILE BROWSER','[DIR] MUSIC', ' Holiday_2026.bmp',
           ' Mountains_720p.BMP',' abcdefghijklmnopqrstuvwxyz',
           ' ABCDEFGHIJKLMNOPQRSTUVWXYZ',' 0123456789 !?@#$%&()[]{}',
           ' BRIGHTNESS 100%  CONTRAST 100%', ' TEXT OSD     106/106']
    for r,line in enumerate(lines):
        text(im,line,x+2,y+2+r*16,fg=(255,200,64) if r in (0,8) else (224,224,224),
             new=new,bg=(48,80,144) if r==2 else BG)


im=Image.new('RGB',(1280,720),(27,32,45))
d=ImageDraw.Draw(im)
font=ImageFont.truetype(str(aa.FONT),20)
d.text((48,24),'BEFORE: 5x7 enlarged blocks',font=font,fill=(255,255,255))
d.text((48,374),'AFTER: native pixels + 4 coverage levels',font=font,fill=(255,255,255))
for new,y in [(False,80),(True,430)]:
    panel(im,64,y,new)
    d.rectangle((514,y,1190,y+31),fill=BG)
    text(im,'TEXT OSD: HELLO WORLD 720P',526,y+8,new=new)
    d.rectangle((514,y+60,710,y+91),fill=BG)
    text(im,'01:23 / 04:56',526,y+68,new=new)
    d.rectangle((770,y+60,968,y+92),fill=(16,16,16))
    text(im,'LINK DOWN',782,y+66,fg=(255,48,48),scale=3,new=new,bg=(16,16,16))
im.save(OUT/'comparison-720p.png')
# Magnified pixels only for inspection; the delivered 720p image is native 1:1.
im.crop((64,430,452,578)).resize((1164,444),Image.Resampling.NEAREST).save(OUT/'detail-3x.png')
print(OUT/'comparison-720p.png')
