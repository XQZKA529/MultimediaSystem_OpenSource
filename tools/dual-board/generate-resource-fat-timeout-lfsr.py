"""Replace a private elapsed counter with a proven exact-deadline encoding.

All original reset, grant and advancement edges remain in the main process.
The retained lookahead timeout flag asserts at the same N-1 count. No CRC,
clock, latency, public diagnostics, pending fields or timeout deadline changes.
Small/invalid parameters keep the original arithmetic branch.
"""
import argparse,json
from pathlib import Path
from resource_experiment import snapshot
from resource_lfsr import primitive

p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args()
proofs=[primitive(n) for n in range(2,33)]
snapshot(a.source,a.destination)
prefix='''localparam IO_BITS=$clog2(IO_TIMEOUT_CYCLES+1);
localparam IO_USE_LFSR=IO_TIMEOUT_CYCLES>=3 && IO_TIMEOUT_CYCLES<=32'h7fffffff;
function [31:0] io_polynomial;
 input integer bits;
 begin case(bits)
'''
prefix+=''.join(f"  {v['bits']}:io_polynomial=32'h{v['polynomial']:08x};\n" for v in proofs)
prefix+='''  default:io_polynomial=1;
 endcase end
endfunction
localparam [IO_BITS-1:0] IO_POLY=io_polynomial(IO_BITS);
function [IO_BITS-1:0] io_step;
 input [IO_BITS-1:0] value;
 begin io_step=(value<<1) ^ (value[IO_BITS-1] ? IO_POLY:0);end
endfunction
function [IO_BITS-1:0] io_multiply;
 input [IO_BITS-1:0] a,b;
 reg [IO_BITS-1:0] value,left;integer k;
 begin
  value=0;left=a;
  for(k=0;k<IO_BITS;k=k+1)begin
   if(b[k])value=value^left;
   left=io_step(left);
  end
  io_multiply=value;
 end
endfunction
function [IO_BITS-1:0] io_power;
 input [31:0] exponent;
 reg [IO_BITS-1:0] value,base;integer k;
 begin
  value=1;base=2;
  for(k=0;k<32;k=k+1)begin
   if(exponent[k])value=io_multiply(value,base);
   base=io_multiply(base,base);
  end
  io_power=value;
 end
endfunction
localparam [IO_BITS-1:0] IO_LAST=IO_USE_LFSR ? io_power(IO_TIMEOUT_CYCLES-2):0;
// State x^n encodes exactly n original enabled counter steps from reset.
reg [IO_BITS-1:0] io_timeout;
wire [IO_BITS-1:0] io_advance=IO_USE_LFSR ? io_step(io_timeout):io_timeout+28'd1;
wire io_predicate=IO_USE_LFSR ? io_timeout==IO_LAST:(io_timeout+28'd1>=IO_TIMEOUT_CYCLES-1);
'''
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
old='reg [$clog2(IO_TIMEOUT_CYCLES+1)-1:0] io_timeout;';assert s.count(old)==1
s=s.replace(old,prefix)
assert s.count('io_timeout<=0;')==3
s=s.replace('io_timeout<=0;',"io_timeout<=IO_USE_LFSR ? 1:0;")
assert s.count("io_timeout<=io_timeout+28'd1;")==2
s=s.replace("io_timeout<=io_timeout+28'd1;",'io_timeout<=io_advance;')
assert s.count("io_timeout_last<=(io_timeout+28'd1>=IO_TIMEOUT_CYCLES-1);")==2
s=s.replace("io_timeout_last<=(io_timeout+28'd1>=IO_TIMEOUT_CYCLES-1);",'io_timeout_last<=io_predicate;')
f.write_text(s,encoding='utf-8')
w=a.destination.parent/'timeout-lfsr-proof';w.mkdir()
(w/'period-certificates.json').write_text(json.dumps(proofs,indent=2),encoding='utf-8')
(w/'timer-logic.vh').write_text(prefix,encoding='utf-8')
