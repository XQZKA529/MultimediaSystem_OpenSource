"""Absorb setup arithmetic capture registers into existing native multipliers.

Geometry retains one shared multiplier and every original preparation state.
Its first result moves into cross_w on state 1; its second lives in the DSP
output register. Both are available at the original state-2 comparison edge.
BMP span uses the existing state-2 capture. All unsigned widths are preserved.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
def helper(name):
 return '''
module NAME(input wire clk,enable,input wire [17:0] a,b,output wire [35:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [35:0] held;
 always @(posedge clk)if(enable)held<=a*b;
 assign q=held;
`else
 // Original data words are unreset; CE cancels writes during reset/start.
 EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("ENABLE"),
  .SRMODE("ASYNC"),.MODE("MULT18X18C")) u_mul(
  .clk(clk),.a(a),.b(b),.acin(18'd0),.bcin(18'd0),
  .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
  .cea(1'b0),.ceb(1'b0),.cepd(enable),.rstan(1'b1),.rstbn(1'b1),.rstpdn(1'b1),
  .acout(),.bcout(),.p(q));
`endif
endmodule
'''.replace('NAME',name)
f=a.destination/'rtl/image/image_scale_geometry.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('wire [28:0] product=mul_src*mul_dst;', '''wire [35:0] product;
    wire [28:0] cross_h=product[28:0];
    resource_geometry_mul u_product(.clk(clk),.enable(!rst && (start || state==1)),
      .a({5'd0,mul_src}),.b({2'd0,mul_dst}),.q(product));''')
s=s.replace('reg [28:0] cross_w,cross_h,numerator,quotient;', 'reg [28:0] cross_w,numerator,quotient;')
assert s.count('cross_w<=product;')==1 and s.count('cross_h<=product;')==1
s=s.replace('cross_w<=product;', '').replace('cross_h<=product;', 'cross_w<=product[28:0];')
f.write_text(s+helper('resource_geometry_mul'),encoding='utf-8')
f=a.destination/'rtl/image/bmp_header_parser.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('reg [27:0] span;', '''wire [35:0] span_product;
    wire [27:0] span=span_product[27:0];
    resource_bmp_span_mul u_span(.clk(clk),.enable(!rst && !start && state==2),
      .a({3'd0,row_stride[14:0]}),.b({5'd0,height}),.q(span_product));''')
old="span<={13'd0,row_stride[14:0]}*{15'd0,height};";assert s.count(old)==1
s=s.replace(old,'')
old="({19'd0,w[12:0]}*3+3)&32'hfffffffc";assert s.count(old)==1
s=s.replace(old,"({19'd0,w[12:0]}+({19'd0,w[12:0]}<<1)+32'd3)&32'hfffffffc")
f.write_text(s+helper('resource_bmp_span_mul'),encoding='utf-8')
