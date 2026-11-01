"""Independent integer contain/centre-sampling oracle for ModelSim fixtures."""
from __future__ import annotations
import argparse
from fractions import Fraction
from pathlib import Path

SIZES = [(1280,720),(640,480),(1920,1080),(3840,2160),(1000,1000),
         (720,1280),(1365,767),(4096,4096),(4096,1),(1,4096),(1,1),
         (3,5),(4,5),(5,5),(6,5),(40,17),(17,40)]

def geometry(w: int, h: int, dw: int, dh: int) -> tuple[int,int,int,int]:
    if w * dh >= h * dw:
        rw, rh = dw, max(1, round(Fraction(h * dw, w)))
    else:
        rw, rh = max(1, round(Fraction(w * dh, h))), dh
    return rw, rh, (dw-rw)//2, (dh-rh)//2

def color(x: int, y: int) -> int:
    return (((x*17+y*3)&255)<<16) | (((x*5+y*29)&255)<<8) | ((x*11+y*7)&255)

def pixels(w: int, h: int, dw: int, dh: int):
    rw,rh,left,top = geometry(w,h,dw,dh)
    for y in reversed(range(dh)):  # Wire/file order, not screen order.
        for x in range(dw):
            if left <= x < left+rw and top <= y < top+rh:
                sx = (2*(x-left)+1)*w//(2*rw)
                sy = (2*(y-top)+1)*h//(2*rh)
                yield color(sx,sy)
            else:
                yield 0

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--full',action='store_true')
    ap.add_argument('--network-only',action='store_true')
    args=ap.parse_args()
    dw,dh=(1280,720) if args.full else (32,18)
    args.out.mkdir(parents=True,exist_ok=True)
    values=list(pixels(7,13,dw,dh))
    with (args.out/'network_expected.hex').open('w') as f:
        for j in range(0,len(values),4):
            block=b''.join(v.to_bytes(3,'big') for v in values[j:j+4])
            f.writelines(f'{int.from_bytes(block[k:k+4],"big"):08x}\n' for k in (0,4,8))
    if args.network_only:
        print(f'Generated independent packed BMP oracle, target {dw}x{dh}')
        return
    rows=[]
    for i,(w,h) in enumerate(SIZES):
        rw,rh,left,top=geometry(w,h,dw,dh)
        offset=70 if i%2 else 54
        rows.append(f'{w} {h} {rw} {rh} {left} {dh-rh-top} {offset}\n')
        with (args.out/f'expected_{i}.hex').open('w') as f:
            f.writelines(f'{p:06x}\n' for p in pixels(w,h,dw,dh))
    (args.out/'cases.txt').write_text(''.join(rows))
    print(f'Generated {len(rows)} independent RGB fixtures, target {dw}x{dh}')

if __name__=='__main__': main()
