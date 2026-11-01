"""Align composed visual scoreboards for the optional extra Text AA stage."""
import re

def align_composed_tests(board):
    for file,array,last,pipes,var,old_word,new_word in [
        ('tb_image_contrast.v','oracle',6,('oh','ov','od'),'k','seven-clock','eight-clock'),
        ('tb_volume_text_pipeline.v','expected',5,('eh','ev','ed'),'j','six-clock','seven-clock')]:
        path=board/'sim'/file;s=path.read_text(encoding='utf-8-sig')
        if f'{array}[0:{last+1}]' in s:continue
        assert f'{array}[0:{last}]' in s
        s=s.replace(f'{array}[0:{last}]',f'{array}[0:{last+1}]')
        s=s.replace(f'reg [{last}:0] {pipes[0]}=',f'reg [{last+1}:0] {pipes[0]}=')
        s=s.replace(f'{var}<{last+1};',f'{var}<{last+2};')
        s=re.sub(r'\b'+array+r'\['+str(last)+r'\]',f'{array}[{last+1}]',s)
        for name in pipes:
            s=s.replace(f'{name}[{last-1}:0]',f'{name}[{last}:0]')
            s=re.sub(r'\b'+name+r'\['+str(last)+r'\]',f'{name}[{last+1}]',s)
        s=s.replace(old_word,new_word)
        path.write_text(s,encoding='utf-8')

if __name__=='__main__':
    import argparse
    from pathlib import Path
    p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
    align_composed_tests(p.parse_args().candidate)
