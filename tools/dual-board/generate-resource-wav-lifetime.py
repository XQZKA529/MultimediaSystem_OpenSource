"""Share WAV chunk-size/skip storage after its last format consumer.

The assembled chunk size is live in CHUNK_SZ/FMT. SKIP begins only after the
rounded skip count has replaced it; a new chunk shifts in all four size bytes
before inspecting the field again. File offsets and output lengths stay 32 bit.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/audio/wav_header_parse.v';s=f.read_text(encoding='utf-8-sig')
assert '    reg [31:0] skip_left;' in s
s=s.replace('    reg [31:0] skip_left;', '    wire [31:0] skip_left=chunk_size;')
s,n=re.subn(r'\bskip_left(\s*<=)',r'chunk_size\1',s);assert n==6,n
# Reset was identical for both old registers; retain one assignment.
s=s.replace("            chunk_size        <= 32'd0;\n",'')
f.write_text(s,encoding='utf-8')
