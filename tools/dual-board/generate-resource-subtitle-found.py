"""Move the cold 64-bit matched TXT entry into native synchronous storage.

The exact match edge writes both complete words. Existing directory scan
completion consumes them later, with no added transaction stages. The found
count is reset as before and gates all reads; pending/manual and active-file
parameters remain separate and every public output keeps its original edge.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
p.add_argument('--manual-pending',action='store_true',help='Also move the independent pending manual pair into its own RAM')
p.add_argument('--current-context',action='store_true',help='Keep image metadata in its own RAM with an explicit post-reset validity flag')
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/ui/sd_subtitle_controller.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('reg [31:0] found_cluster,found_size;','wire [31:0] found_cluster,found_size;')
assert s.count('found_cluster<=file_cluster;found_size<=file_size;')==1
s=s.replace('found_cluster<=file_cluster;found_size<=file_size;','')
s=s.replace('found_cluster<=0;found_size<=0;','')
insert='''
 // A matching entry owns this pair until DIR2 completes. found==1 is the
 // original validity guard, so uninitialized/old RAM contents are never read
 // by a file request after power-up, cancellation or an asynchronous reset.
 wire found_write=!rst && state==DIR2 && ee && !entry_bad && entry_equal &&
   entry_len==name_len && suffix0==46 && suffix1==84 && suffix2==88 && suffix3==84;
 resource_subtitle_found_hold u_found(.clk(clk),.write(found_write),
   .din({file_cluster,file_size}),.q({found_cluster,found_size}));
'''
s=s.replace('\nendmodule',insert+'\nendmodule',1)
if a.manual_pending:
 old='reg [31:0] manual_cluster_q,manual_size_q,current_cluster,current_size,current_id;'
 assert s.count(old)==1
 s=s.replace(old,'reg [31:0] current_cluster,current_size,current_id;\n wire [31:0] manual_cluster_q,manual_size_q;')
 for old in ('manual_cluster_q<=0;manual_size_q<=0;',
             'manual_cluster_q<=load_cluster;manual_size_q<=load_size;'):
  assert s.count(old)==1;s=s.replace(old,'')
 insert='''
 // Pending manual input may update while an automatic directory lookup
 // owns the found bank. Keep its RAM and enable entirely independent.
 resource_subtitle_found_hold u_manual_pending(.clk(clk),.write(!rst && load_req),
   .din({load_cluster,load_size}),.q({manual_cluster_q,manual_size_q}));
'''
 s=s.replace('\nendmodule',insert+'\nendmodule',1)
if a.current_context:
 old='reg [31:0] current_cluster,current_size,current_id;'
 assert s.count(old)==1,'--current-context currently requires --manual-pending'
 s=s.replace(old,'wire [31:0] current_cluster,current_size,current_id;\n reg current_context_valid;')
 for old in ('current_cluster<=0;current_size<=0;current_id<=0;',
             'current_cluster<=image_cluster;current_size<=image_size;current_id<=image_id;'):
  assert s.count(old)==1;s=s.replace(old,'')
 assert s.count('current_cluster!=0')==2
 s=s.replace('current_cluster!=0','current_context_valid && current_cluster!=0')
 assert s.count('auto_id<=current_id;')==1
 s=s.replace('auto_id<=current_id;', "if(current_context_valid) auto_id<=current_id;else auto_id<=32'd0;")
 insert='''
 always @(posedge clk or posedge rst)begin
   if(rst)current_context_valid<=0;else if(image_presented)current_context_valid<=1;
 end
 resource_subtitle_found_hold #(.WIDTH(96)) u_current(.clk(clk),.write(!rst && image_presented),
   .din({image_cluster,image_size,image_id}),.q({current_cluster,current_size,current_id}));
'''
 s=s.replace('\nendmodule',insert+'\nendmodule',1)
s+='''
module resource_subtitle_found_hold #(parameter WIDTH=64)(input wire clk,write,
 input wire [WIDTH-1:0] din,output wire [WIDTH-1:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [WIDTH-1:0] held;
 always @(posedge clk)if(write)held<=din;
 assign q=held;
`else
 localparam BANKS=(WIDTH+31)/32;
 wire [BANKS*32-1:0] padded={{(BANKS*32-WIDTH){1'b0}},din};
 wire [BANKS*32-1:0] held;
 assign q=held[WIDTH-1:0];
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
f.write_text(s,encoding='utf-8')
