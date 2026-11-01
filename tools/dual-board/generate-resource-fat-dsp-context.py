"""Retain cold FAT geometry and the independent pending request in DSP registers.

Unsigned multiply-by-one uses only the native output register (one clock).
Capture edges, precision, reset, operation order and all request storage stay
unchanged. No preparation clocks or new timeout allowances are introduced.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args()
snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
selected=['fat_lba','data_lba','max_cluster','map_pend_cluster','map_pend_size']
def declarations(match):
 names=[v.strip() for v in match[1].split(',')]
 keep=[v for v in names if v not in selected];moved=[v for v in names if v in selected]
 return ('reg [31:0] '+','.join(keep)+';' if keep else '')+('wire [31:0] '+','.join(moved)+';' if moved else '')
s=re.sub(r'reg\s*\[31:0\]\s*([a-zA-Z_][a-zA-Z0-9_, ]*);',declarations,s)
assignments={
 'fat_lba':['0',"partition_lba+{16'd0,reserved_sectors}"],
 'data_lba':['0','partition_lba+data_start_offset'],
 'max_cluster':['0',"geometry_clusters+32'd1"],
 'map_pend_cluster':['0','map_first_cluster'],
 'map_pend_size':['0','map_size']}
for name,values in assignments.items():
 matches=re.findall(r'\b'+name+r'\s*<=\s*([^;]+);',s)
 assert sorted(v.replace(' ','') for v in matches)==sorted(values),(name,matches)
 s=re.sub(r'\b'+name+r'\s*<=\s*[^;]+;','',s)
logic='''
    // Mirror the existing main-FSM guard exactly, including cooperative abort.
    wire context_case_enable=!(file_abort_i && active_op==OP_FILE &&
      state_encoded!=S_IDLE && state_encoded!=S_FAIL);
    wire geometry_capture=context_case_enable && state_encoded==S_MOUNT_GEOM3_CHECK && !geom3_bad;
    wire maximum_capture=context_case_enable && state_encoded==S_MOUNT_GEOM4;
    wire pending_capture=map_start && state_encoded!=S_IDLE && !map_pending &&
      !(active_op==OP_MAP && state_encoded!=S_IDLE);
    resource_fat_dsp_hold #(.WIDTH(64)) u_geometry(.clk(clk),.rst(rst),.enable(geometry_capture),
      .din({partition_lba+{16'd0,reserved_sectors},partition_lba+data_start_offset}),.q({fat_lba,data_lba}));
    resource_fat_dsp_hold #(.WIDTH(32)) u_maximum(.clk(clk),.rst(rst),.enable(maximum_capture),
      .din(geometry_clusters+32'd1),.q(max_cluster));
    // This bank remains separate from active operation state; no lifecycle merge.
    resource_fat_dsp_hold #(.WIDTH(64)) u_pending(.clk(clk),.rst(rst),.enable(pending_capture),
      .din({map_first_cluster,map_size}),.q({map_pend_cluster,map_pend_size}));
'''
i=s.rindex('endmodule');s=s[:i]+logic+s[i:]
s+='''
module resource_fat_dsp_hold #(parameter WIDTH=64)(
 input wire clk,rst,enable,input wire [WIDTH-1:0] din,output wire [WIDTH-1:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [WIDTH-1:0] held;
 always @(posedge clk or posedge rst) if(rst) held<=0;else if(enable) held<=din;
 assign q=held;
`else
 localparam LANES=(WIDTH+17)/18;
 wire [LANES*18-1:0] padded={{(LANES*18-WIDTH){1'b0}},din};
 wire [LANES*18-1:0] held;
 assign q=held[WIDTH-1:0];
 genvar i;
 generate for(i=0;i<LANES;i=i+1)begin:lane
  wire [35:0] product;
  assign held[i*18+:18]=product[17:0];
  EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("ENABLE"),
   .SRMODE("ASYNC"),.MODE("MULT18X18C")) u_hold(
   .clk(clk),.a(padded[i*18+:18]),.b(18'd1),.acin(18'd0),.bcin(18'd0),
   .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
   .cea(1'b0),.ceb(1'b0),.cepd(enable),.rstan(1'b1),.rstbn(1'b1),.rstpdn(!rst),
   .acout(),.bcout(),.p(product));
 end endgenerate
`endif
endmodule
'''
f.write_text(s,encoding='utf-8')
