"""Move independent storage-service pending payloads to synchronous BRAM banks.

Each client retains its own full-width bank and same capture edge. Reset-valid
bits preserve the original zero values even before the first capture; pending,
owner, arbitration, cancellation and start pulses remain unchanged.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
p.add_argument('--bmp-only',action='store_true')
p.add_argument('--owner-qualified',action='store_true',help='Private payloads are consumed only after original pending capture; avoid unused reset-zero data muxes')
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/storage/storage_service.v'
s=f.read_text(encoding='utf-8-sig')
groups=[('bmp','file_start',['bmp_cluster_q','bmp_size_q','bmp_limit_q'],['file_first_cluster','file_size','file_read_limit'])]
if not a.bmp_only:
    groups += [('txt','txt_file_start',['txt_cluster_q','txt_size_q'],['txt_file_cluster','txt_file_size']),
               ('map','map_start',['map_cluster_q','map_size_q'],['map_first_cluster','map_size'])]
old='reg [31:0] bmp_cluster_q,bmp_size_q,bmp_limit_q,txt_cluster_q,txt_size_q,map_cluster_q,map_size_q;'
assert s.count(old)==1
replaced={name for _,_,names,_ in groups for name in names}
all_names=['bmp_cluster_q','bmp_size_q','bmp_limit_q','txt_cluster_q','txt_size_q','map_cluster_q','map_size_q']
keep=[name for name in all_names if name not in replaced]
declarations=('reg [31:0] '+','.join(keep)+';\n') if keep else ''
declarations+='wire [31:0] '+','.join(name for name in all_names if name in replaced)+';'
s=s.replace(old,declarations)
instances='\n'
for bank,enable,names,inputs in groups:
    for name,data in zip(names,inputs):
        for expression in (name+'<=0;',name+'<='+data+';'):
            assert s.count(expression)==1,expression
            s=s.replace(expression,'')
    instances+=f''' resource_storage_context_hold #(.WIDTH({32*len(names)})) u_{bank}_pending_payload(
  .clk(clk),.rst(rst),.capture({enable}),.din({{{','.join(inputs)}}}),.q({{{','.join(names)}}}));
'''
s=s.replace('\nendmodule',instances+'\nendmodule',1)
s+='''
module resource_storage_context_hold #(parameter WIDTH=64)(
 input wire clk,rst,capture,input wire [WIDTH-1:0] din,output wire [WIDTH-1:0] q);
 reg initialized;
 always @(posedge clk or posedge rst)
  if(rst) initialized<=0;else if(capture) initialized<=1;
 wire write=capture && !rst;
 localparam BANKS=(WIDTH+31)/32;
 wire [BANKS*32-1:0] padded={{(BANKS*32-WIDTH){1'b0}},din};
 wire [BANKS*32-1:0] held;
 assign q=initialized ? held[WIDTH-1:0]:{WIDTH{1'b0}};
`ifdef DB_BEHAVIORAL_RAM
 reg [WIDTH-1:0] model;
 always @(posedge clk)if(write)model<=din;
 assign held={{(BANKS*32-WIDTH){1'b0}},model};
`else
 genvar g;
 generate for(g=0;g<BANKS;g=g+1)begin:bank
  EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
   .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
   .WRITEMODE_A("WRITETHROUGH"),.WRITEMODE_B("WRITETHROUGH")) u_ram(
   .clka(clk),.addra(11'd0),.doa(held[g*32+:16]),.dia(padded[g*32+:16]),
   .bytea(1'b0),.bytewea(1'b0),.csa(write),.wea(1'b1),.rsta(1'b0),.ocea(1'b1),
   .clkb(clk),.addrb(11'd1024),.dob(held[g*32+16+:16]),.dib(padded[g*32+16+:16]),
   .byteb(1'b0),.byteweb(1'b0),.csb(write),.web(1'b1),.rstb(1'b0),.oceb(1'b1));
 end endgenerate
`endif
endmodule
'''
if a.owner_qualified:
    s=s.replace(''' reg initialized;
 always @(posedge clk or posedge rst)
  if(rst) initialized<=0;else if(capture) initialized<=1;
''',''' // Reset clears owner/pending/start in the original controller. A new
 // launch requires a pending request from an earlier payload capture edge.
''')
    s=s.replace("assign q=initialized ? held[WIDTH-1:0]:{WIDTH{1'b0}};", 'assign q=held[WIDTH-1:0];')
    assert 'initialized' not in s
f.write_text(s,encoding='utf-8')
