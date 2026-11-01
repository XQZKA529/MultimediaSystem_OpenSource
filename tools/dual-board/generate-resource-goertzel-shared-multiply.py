"""Expose the mutually exclusive window and recurrence multiplier as one node.

The two original publication edges and full STW+16-bit product register stay
unchanged. Extend both operands as signed values before selection; do not
truncate the state/window operand for generic STW values below 16.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/fft/audio_fft_osd.v';s=f.read_text(encoding='utf-8-sig')
marker='    // 阶段编码'
decl='''    // Window preparation and recurrence are mutually exclusive phases.
    localparam SHARED_BW=(STW<16) ? 16:STW;
    wire signed [15:0] shared_mul_a=(ph==P_IDLE) ? mono16:coef_r;
    wire signed [SHARED_BW-1:0] shared_mul_b=(ph==P_IDLE) ?
      {{(SHARED_BW-16){w_tri[15]}},w_tri}:{{(SHARED_BW-STW){s1q[STW-1]}},s1q};
    wire signed [STW+15:0] shared_product=shared_mul_a*shared_mul_b;

'''
assert s.count(marker)==1
# Declare after ph and localparams so old Verilog tools never create implicit nets.
marker='    reg  [3:0]     ph;'
assert s.count(marker)==1
s=s.replace(marker,marker+'\n'+decl)
for expression in ('mono16 * w_tri','coef_r * s1q'):
 assert s.count('prod_r <= '+expression+';')==1
 s=s.replace('prod_r <= '+expression+';','prod_r <= shared_product;')
f.write_text(s,encoding='utf-8')
