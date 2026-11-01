"""Pre-read exact LFN ordinal base/length tables using one dual-port BRAM9K.

entry_first is captured at directory byte zero and stays stable through the
remaining 31 byte reads. Both tables therefore settle before DIR_DECODE;
the original lfn_base/lfn_len capture edges and terminator updates are retained.
All 32 ordinal inputs preserve the original default and eight-bit truncation.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import byte_dual_rom9
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
fun=re.search(r'function \[7:0\] lfn_ordinal_base;.*?endfunction',s,re.S)[0]
words=[0]*1024
for n in range(32):
 words[n]=(n-1)*13 if 1<=n<=19 else 247
 words[32+n]=255 if n==20 else (n*13)&255
s=s.replace(fun,'')
marker='reg [31:0] entry_cluster,entry_size;';assert marker in s
s=s.replace(marker,marker+'\nwire [7:0] lfn_base_table,lfn_length_table;')
old="lfn_base<=lfn_ordinal_base(entry_first&8'h1f);";assert s.count(old)==1
s=s.replace(old,'lfn_base<=lfn_base_table;')
old="lfn_len<=((entry_first&8'h1f)==20)?8'd255:((entry_first&8'h1f)*13);";assert s.count(old)==1
s=s.replace(old,'lfn_len<=lfn_length_table;')
i=s.index('\nendmodule');s=s[:i]+'''
    // Metadata byte zero precedes DIR_DECODE by the complete entry scan.
    resource_fat_lfn_table u_lfn_table(.clk(clk),.a({5'd0,entry_first[4:0]}),
      .b({4'd0,1'b1,entry_first[4:0]}),.qa(lfn_base_table),.qb(lfn_length_table));
'''+s[i:]
f.write_text(s+byte_dual_rom9('resource_fat_lfn_table',words),encoding='utf-8')
e=a.destination.parent/'lfn-rom-generation';e.mkdir(parents=True,exist_ok=True)
(e/'original_base.v').write_text(fun,encoding='utf-8')
