"""Absorb the synchronous stream FIFO's existing two read stages into BRAM.

Copy the common controller unchanged into a media-local specialization. Native
BRAM32K read stage implements q, enabled OUTREG implements hold. Reset clears
hold asynchronously; clear only cancels pending/valid, preserving old hold.
Depth, pointers, credit, overflow, latency and output backpressure are unchanged.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);p.add_argument('--pcm',action='store_true')
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/seam/seam_media.v';s=f.read_text(encoding='utf-8-sig')
for aw,name in [(10,'u_image')]+([(9,'u_pcm')] if a.pcm else []):
    old=f'db_stream_fifo #(.AW({aw})) {name}'
    assert s.count(old)==1;s=s.replace(old,old.replace('db_stream_fifo','resource_media_stream_fifo'))
controller=(a.source/'rtl/seam/db_stream_fifo.v').read_text(encoding='utf-8-sig')
controller=controller.replace('module db_stream_fifo #(', 'module resource_media_stream_fifo #(')
controller=controller.replace('    reg [31:0] mem[0:(1<<AW)-1] /* fehdl force_ram=1, ram_style="bram" */;','')
controller=controller.replace('    reg [31:0] q,hold;', '    wire [31:0] hold;')
old='''    always @(posedge clk) begin
        if(push && free_words!=0 && !clear) mem[wp[AW-1:0]]<=din;
        q<=mem[rp[AW-1:0]];
    end'''
assert controller.count(old)==1
controller=controller.replace(old,'''    resource_stream_read_stages #(.AW(AW)) u_read_stages(
      .clk(clk),.rst(rst),.write(push && free_words!=0 && !clear),
      .write_addr(wp[AW-1:0]),.read_addr(rp[AW-1:0]),.din(din),
      .publish(pending && !clear && !rst),.q(hold));''')
assert controller.count('hold<=0;')==1 and controller.count('hold<=q;')==1
controller=controller.replace('hold<=0;','').replace('hold<=q;','')
helper='''
module resource_stream_read_stages #(parameter AW=10)(input wire clk,rst,write,publish,
 input wire [AW-1:0] write_addr,read_addr,input wire [31:0] din,output wire [31:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [31:0] mem[0:(1<<AW)-1],first,held;
 always @(posedge clk)begin if(write)mem[write_addr]<=din;first<=mem[read_addr];end
 always @(posedge clk or posedge rst)if(rst)held<=0;else if(publish)held<=first;
 assign q=held;
`else
 generate if(AW<=11)begin:native_read_pipeline
  genvar g;
  for(g=0;g<2;g=g+1)begin:bank
   EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
    .REGMODE_A("NOREG"),.REGMODE_B("OUTREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
    .SRMODE("ASYNC")) u_ram(
    .clka(clk),.addra({{(11-AW){1'b0}},write_addr}),.dia(din[g*16+:16]),.doa(),
    .bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(write),.rsta(1'b0),.ocea(1'b1),
    .clkb(clk),.addrb({{(11-AW){1'b0}},read_addr}),.dib(16'd0),.dob(q[g*16+:16]),
    .byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(1'b0),.rstb(rst),.oceb(publish));
  end
 end else begin:generic_read_pipeline
  reg [31:0] mem[0:(1<<AW)-1] /* fehdl force_ram=1, ram_style="bram" */;
  reg [31:0] first,held;
  always @(posedge clk)begin if(write)mem[write_addr]<=din;first<=mem[read_addr];end
  always @(posedge clk or posedge rst)if(rst)held<=0;else if(publish)held<=first;
  assign q=held;
 end endgenerate
`endif
endmodule
'''
f.write_text(s+'\n'+controller+helper,encoding='utf-8')
