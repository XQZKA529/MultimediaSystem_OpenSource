"""Recognize fixed RIFF/WAVE/fmt/data identifiers byte by byte.

Four cumulative match bits replace the wide shift and four wide compares.
Each first byte starts a new match; the fourth byte is included before the
original rejection edge. Full chunk/file sizes, padding and priority remain.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/audio/wav_header_parse.v';s=f.read_text(encoding='utf-8-sig')
s,n=re.subn(r'reg \[31:0\] fourcc;', 'reg riff_match,wave_match,fmt_match,data_match;',s);assert n==1
s,n=re.subn(r'wire \[31:0\] W_fourcc\s*=\s*\{fourcc\[23:0\], byte_data\};','''function [7:0] magic_byte;
        input [31:0] magic;input [1:0] index;
        begin magic_byte=magic[31-{index,3'b000} -:8];end
    endfunction
    wire riff_next=(byte_idx==0 || riff_match) && byte_data==magic_byte(FCC_RIFF,byte_idx);
    wire wave_next=(byte_idx==0 || wave_match) && byte_data==magic_byte(FCC_WAVE,byte_idx);
    wire fmt_next=(byte_idx==0 || fmt_match) && byte_data==magic_byte(FCC_FMT,byte_idx);
    wire data_next=(byte_idx==0 || data_match) && byte_data==magic_byte(FCC_DATA,byte_idx);''',s);assert n==1
s,n=re.subn(r'fourcc\s*<=\s*32\'d0;', 'riff_match<=0;wave_match<=0;fmt_match<=0;data_match<=0;',s);assert n==2
s,n=re.subn(r'fourcc\s*<=\s*W_fourcc;','',s);assert n==4
marker='            else if (byte_valid && state != S_IDLE) begin'
assert s.count(marker)==1
s=s.replace(marker,marker+'''
                if(state==S_RIFF || state==S_WAVE || state==S_CHUNK_ID)begin
                    riff_match<=riff_next;wave_match<=wave_next;
                    fmt_match<=fmt_next;data_match<=data_next;
                end''')
for old,new in [('W_fourcc != FCC_RIFF','!riff_next'),('W_fourcc != FCC_WAVE','!wave_next'),
                ('fourcc == FCC_FMT','fmt_match'),('fourcc == FCC_DATA','data_match')]:
 assert s.count(old)==1;s=s.replace(old,new)
assert not re.search(r'\b(?:fourcc|W_fourcc)\b',s)
f.write_text(s,encoding='utf-8')
