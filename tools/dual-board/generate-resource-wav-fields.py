"""Fold WAV format validation fields without changing rejection priority/cycles."""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/audio/wav_header_parse.v';s=f.read_text(encoding='utf-8-sig')
for field,width in [('tag',16),('channels',16),('rate',32),('bits',16)]:
 s,n=re.subn(r'reg \['+str(width-1)+r':0\] fmt_'+field+';',f'reg fmt_{field}_bad;',s);assert n==1
 s,n=re.subn(r'fmt_'+field+r'\s*<= '+str(width)+r"'d0;",f"fmt_{field}_bad <= 1'b1;",s);assert n==1
s=s.replace('    reg        fmt_seen;', '    reg fmt_stereo;\n    reg        fmt_seen;')
s=s.replace("fmt_channels_bad <= 1'b1;", "fmt_channels_bad <= 1'b1;fmt_stereo<=0;")
entries={0:('tag',1,False),1:('tag',0,True),2:('channels',None,False),3:('channels',0,True),
         4:('rate',128,False),5:('rate',187,True),6:('rate',0,True),7:('rate',0,True),
         14:('bits',16,False),15:('bits',0,True)}
for index,(field,expected,accumulate) in entries.items():
 pattern=r"5'd"+str(index)+r":\s+fmt_"+field+r"\[\d+:\d+\]\s*<= byte_data;"
 if field=='channels' and index==2:
  new="5'd2:begin fmt_channels_bad<=byte_data!=1 && byte_data!=2;fmt_stereo<=byte_data==2;end"
 elif index==15:new="5'd15: ; // The final high byte is tested directly below."
 else:new=f"5'd{index}:fmt_{field}_bad<="+(f'fmt_{field}_bad || ' if accumulate else '')+f"byte_data!=8'd{expected};"
 s,n=re.subn(pattern,new,s);assert n==1,(index,n)
s=s.replace("fmt_tag != 16'd1",'fmt_tag_bad').replace("fmt_rate != 32'd48000",'fmt_rate_bad')
s=s.replace("{byte_data, fmt_bits[7:0]} != 16'd16", "(byte_data!=0 || fmt_bits_bad)")
s=s.replace("fmt_channels != 16'd1 && fmt_channels != 16'd2",'fmt_channels_bad')
s=s.replace("(fmt_channels == 16'd2)",'fmt_stereo')
f.write_text(s,encoding='utf-8')
