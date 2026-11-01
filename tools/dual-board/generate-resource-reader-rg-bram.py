"""Store the R/G planes of the existing two four-pixel reader banks in BRAM.

Three words still arrive over the original three-read/four-clock cadence.
The existing idle commit clock writes the fourth pixel's R/G pair. Blue stays
in 64 FFs; one shared 16-bit partial holds R1, then R2/G2, then R3/G3.
The synchronous RAM read absorbs the original RGB output register's R/G lanes.
Every public cycle, FIFO request, buffer capacity and frame-start hold remains.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);p.add_argument('--prefetch',action='store_true')
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/framebuffer/rgb888_word_reader.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('output reg  [23:0] pixel_rgb,','output wire [23:0] pixel_rgb,')
for bank in (0,1):
 old=f'reg [31:0] bank{bank}_w0, bank{bank}_w1, bank{bank}_w2;'
 assert old in s;s=s.replace(old,f'reg [7:0] bank{bank}_b0,bank{bank}_b1,bank{bank}_b2,bank{bank}_b3;')
 old=f'bank{bank}_w0 <= 0; bank{bank}_w1 <= 0; bank{bank}_w2 <= 0;'
 assert old in s;s=s.replace(old,f'bank{bank}_b0<=0;bank{bank}_b1<=0;bank{bank}_b2<=0;bank{bank}_b3<=0;')
 for index,part in [(0,'15:8'),(1,'23:16')]:
  old=f"2'd{index}: bank{bank}_w{index} <= fifo_read_data;"
  assert old in s;s=s.replace(old,f"2'd{index}: bank{bank}_b{index}<=fifo_read_data[{part}];")
 old=f'default: begin bank{bank}_w2 <= fifo_read_data; bank{bank}_valid <= 1\'b1; end'
 assert old in s;s=s.replace(old,f'default: begin bank{bank}_b2<=fifo_read_data[31:24];bank{bank}_b3<=fifo_read_data[7:0];bank{bank}_valid<=1\'b1;end')
 expressions=[f'bank{bank}_w0[31:8]',f'{{bank{bank}_w0[7:0],bank{bank}_w1[31:16]}}',
              f'{{bank{bank}_w1[15:0],bank{bank}_w2[31:24]}}',f'bank{bank}_w2[23:0]']
 for index,expression in enumerate(expressions):
  old='pixel_rgb <= '+expression+';';assert old in s
  s=s.replace(old,f'blue_pixel<=bank{bank}_b{index};')
s=s.replace("pixel_rgb <= 24'd0;", "blue_pixel<=8'd0;rg_visible<=0;")
needle='''                if ((!active_bank && bank0_valid) || (active_bank && bank1_valid)) begin
                    if (!active_bank) begin'''
assert needle in s;s=s.replace(needle,needle.replace('                    if (!active_bank)', '                    rg_visible<=1;\n                    if (!active_bank)'))
logic='''
    reg [7:0] blue_pixel;
    reg rg_visible;
    wire [15:0] rg_pixel;
    assign pixel_rgb={rg_visible ? rg_pixel:16'd0,blue_pixel};
    reg [15:0] partial_rg;
    reg tail_valid,tail_bank;
    wire rg_write=read_pending || tail_valid;
    wire [2:0] rg_write_addr=read_pending ?
      {pending_bank,(pending_index<2 ? pending_index:2'd2)}:{tail_bank,2'd3};
    wire [15:0] rg_write_data=!read_pending ? partial_rg:
      pending_index==0 ? fifo_read_data[31:16]:
      pending_index==1 ? {partial_rg[7:0],fifo_read_data[31:24]}:partial_rg;
    wire rg_read=!frame_start && de_in && (active_bank ? bank1_valid:bank0_valid);
    resource_reader_rg_ram u_rg(.clk(clk),.rst(rst),.we(rg_write),.waddr(rg_write_addr),.din(rg_write_data),
      .re(rg_read),.raddr({active_bank,pixel_phase}),.q(rg_pixel));
    always @(posedge clk or posedge rst)begin
      if(rst)begin partial_rg<=0;tail_valid<=0;tail_bank<=0;end
      else begin
        // The old issue_index=3 gap guarantees a free commit after word 2.
        tail_valid<=read_pending && pending_index>=2;
        if(read_pending)begin
          case(pending_index)
            0:partial_rg<={8'd0,fifo_read_data[7:0]};
            1:partial_rg<=fifo_read_data[15:0];
            default:begin partial_rg<=fifo_read_data[23:8];tail_bank<=pending_bank;end
          endcase
        end
      end
    end
'''
i=s.index('    always @(posedge clk or posedge rst)');s=s[:i]+logic+s[i:]
assert 'bank0_w' not in s and 'bank1_w' not in s and 'pixel_rgb <=' not in s
s+='''
module resource_reader_rg_ram(input wire clk,rst,we,re,input wire [2:0] waddr,raddr,
 input wire [15:0] din,output wire [15:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [15:0] mem[0:7],data;integer i;
 initial for(i=0;i<8;i=i+1)mem[i]=0;
 always @(posedge clk)begin
   if(!rst && we)mem[waddr]<=din;
   if(!rst && re)data<=mem[raddr];
 end
 assign q=data;
`else
 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
  .SRMODE("ASYNC"),.INIT_00(256'd0)) u_ram(
  .clka(clk),.addra({8'd0,waddr}),.dia(din),.doa(),.bytea(1'b0),.bytewea(1'b0),
  .csa(we && !rst),.wea(1'b1),.rsta(1'b0),.ocea(1'b1),
  .clkb(clk),.addrb({8'd0,raddr}),.dib(16'd0),.dob(q),.byteb(1'b0),.byteweb(1'b0),
  .csb(re && !rst),.web(1'b0),.rstb(1'b0),.oceb(1'b1));
`endif
endmodule
'''
if a.prefetch:
 marker='    resource_reader_rg_ram u_rg('
 logic='''    // The counter's next state is known at this edge. Read that pixel
    // now, then publish the hard output register at the following edge.
    wire [2:0] rg_after=frame_start ? 3'd0:
      (de_in && (active_bank ? bank1_valid:bank0_valid)) ?
        (pixel_phase==3 ? {~active_bank,2'd0}:{active_bank,pixel_phase+2'd1}):{active_bank,pixel_phase};
    // Refill can only collide with a not-yet-valid next bank. Read a reserved
    // zero word instead; its result is masked until the bank is published.
    wire rg_prefetch_dummy=rg_write && rg_write_addr==rg_after;
    wire [3:0] rg_prefetch_addr=rg_prefetch_dummy ? 4'd8:{1'b0,rg_after};
'''
 assert marker in s;s=s.replace(marker,logic+marker)
 s=s.replace('.re(rg_read),.raddr({active_bank,pixel_phase})', '.re(1\'b1),.oe(!frame_start),.raddr(rg_prefetch_addr)')
 s=s.replace('input wire clk,rst,we,re,input wire [2:0] waddr,raddr,',
  'input wire clk,rst,we,re,oe,input wire [2:0] waddr,input wire [3:0] raddr,')
 s=s.replace('reg [15:0] mem[0:7],data;integer i;', 'reg [15:0] mem[0:8],data,result;integer i;')
 s=s.replace('i<8;i=i+1', 'i<9;i=i+1')
 s=s.replace(' assign q=data;', ''' always @(posedge clk or posedge rst)if(rst)result<=0;else if(oe)result<=data;
 assign q=result;''')
 s=s.replace('.REGMODE_A("NOREG"),.REGMODE_B("NOREG")', '.REGMODE_A("NOREG"),.REGMODE_B("OUTREG")')
 s=s.replace('.addrb({8\'d0,raddr})', '.addrb({7\'d0,raddr})')
 s=s.replace('.csb(re && !rst),.web(1\'b0),.rstb(1\'b0),.oceb(1\'b1)', '.csb(re && !rst),.web(1\'b0),.rstb(rst),.oceb(oe)')
f.write_text(s,encoding='utf-8')
