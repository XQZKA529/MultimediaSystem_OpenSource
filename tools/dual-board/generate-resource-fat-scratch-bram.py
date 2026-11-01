"""Map unreset FAT scratch registers to exact one-stage native BRAM holds.

Only whole-word, unreset scratch captures move. Values remain undefined until
their first capture and hold through warm reset, matching the original RTL.
No cycle, bit width, pending storage, arithmetic or timeout changes are needed.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);p.add_argument('--limit',type=int,default=13)
p.add_argument('--registered-prefetch',action='store_true')
p.add_argument('--fields',help='Comma-separated selection instead of the first --limit fields')
p.add_argument('--bram9',action='store_true',help='Native DP8K paired nine-bit holding ports; legacy addresses reproduce the old failed probe')
p.add_argument('--native-write-address',action='store_true',help='Use verified 9-bit write-enable address suffix and READBACK=ON')
p.add_argument('--bram9-readback',choices=['ON','OFF'],default='ON',help='Native readback setting; both values passed corrected full-width hold probes')
a=p.parse_args();snapshot(a.source,a.destination)
assert not a.native_write_address or a.bram9
if a.bram9 and not a.native_write_address:
 print('LEGACY FAILED PROBE: address write masks are zero; failure reproduction only, do not synthesize or promote')
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
assert 'wire context_case_enable=' in s
mb='state_encoded==S_RD_WAIT && blk_data_valid_i && rd_kind==RD_MOUNT && blk_lba==0 && rd_index>=446 && rd_index<510 && rd_index[3:0]==13 && !mbr_found && is_fat32_type(mbr_work_type) && mbr_work_lba!=0'
capture_file='state_encoded==S_IDLE && !mount_start && !dir_start_i && file_start'
fields=[
 ('captured_file_size',32,capture_file,'file_size',['file_size']),
 ('captured_read_limit',32,capture_file,'file_read_limit',['file_read_limit']),
 ('mbr_sel_lba',32,mb,'mbr_work_lba',['mbr_work_lba']),
 ('mbr_sel_size',32,mb,'{blk_data_i,mbr_work_size}',['{blk_data_i,mbr_work_size}']),
 ('fat_cache_lba',32,'(state_encoded==S_FAT_REQ_READY || state_encoded==S_MAP_FAT_REQ) && !(fat_cache_valid && fat_cache_lba==fat_req_lba)',
  'fat_req_lba',['fat_req_lba','fat_req_lba']),
 ('fat_req_lba',32,'state_encoded==S_FAT_REQ || state_encoded==S_MAP_FAT',
  'fat_lba+((state_encoded==S_MAP_FAT ? map_cluster:fat_query_cluster)>>7)',
  ['fat_lba+(fat_query_cluster>>7)','fat_lba+(map_cluster>>7)']),
 ('fat_area_sectors',32,'state_encoded==S_MOUNT_GEOM1','fat_sectors*num_fats',['fat_sectors*num_fats']),
 ('data_start_offset',32,'state_encoded==S_MOUNT_GEOM2',"{16'd0,reserved_sectors}+fat_area_sectors",["{16'd0,reserved_sectors}+fat_area_sectors"]),
 ('cluster_lba_offset',32,'state_encoded==S_DIR_LBA || state_encoded==S_FILE_LBA || state_encoded==S_MAP_LBA','lba_cluster_offset',['lba_cluster_offset']*3),
 ('data_sectors',32,'state_encoded==S_FILE_PREP2 || (state_encoded==S_MOUNT_GEOM3_CHECK && !geom3_bad)',
  "state_encoded==S_FILE_PREP2 ? {8'd0,file_hop_rounded}:total_sectors-data_start_offset",["{8'd0,file_hop_rounded}",'total_sectors-data_start_offset']),
 ('fat_next_cluster',32,'(state_encoded==S_FAT_EVAL && fat_cache_valid) || state_encoded==S_MAP_FAT_GET',
  "{4'd0,fat_q[27:0]}",["{4'd0,fat_q[27:0]}"]*2),
 ('file_sector_count',24,'state_encoded==S_FILE_PREP1',"({1'b0,file_remaining}+33'd511)>>9",["({1'b0,file_remaining}+33'd511)>>9"]),
 ('file_hop_limit',24,'state_encoded==S_FILE_PREP3','geometry_clusters[23:0]',['geometry_clusters[23:0]'])]
assert 1<=a.limit<=len(fields)
if a.fields:
 requested=set(a.fields.split(','));assert requested <= {x[0] for x in fields}
 fields=[x for x in fields if x[0] in requested]
else:fields=fields[:a.limit]
selected={x[0] for x in fields}
if re.search(r'reg\s*\[6:0\]\s*control_state\b',s):
 fields=[(name,width,ce.replace('state_encoded','control_state'),
          data.replace('state_encoded','control_state'),expected)
         for name,width,ce,data,expected in fields]
assert not(a.bram9 and a.registered_prefetch),'BRAM9 variant is exactly one-stage only'
prefetch={}
if a.registered_prefetch:
 # These operands become stable before the original publication edge. The
 # RAM's internal read stage may refresh independently of its output register.
 prefetch={
  'mbr_sel_lba':'mbr_work_lba',
  'mbr_sel_size':"{blk_data,((state_encoded==S_RD_WAIT && blk_data_valid_i && rd_kind==RD_MOUNT && blk_lba==0 && rd_index>=446 && rd_index<510 && rd_index[3:0]==12 && !rst) ? {blk_data_i,mbr_work_size[15:0]}:mbr_work_size)}",
  'fat_cache_lba':'fat_lba+(walk_cluster>>7)',
  'fat_req_lba':'fat_lba+(walk_cluster>>7)',
  'fat_area_sectors':'fat_sectors*num_fats',
  'file_sector_count':"{1'b0,file_remaining[31:9]}+(|file_remaining[8:0])",
  'file_hop_limit':'scratch_hop_prefetch'}
 names=set(prefetch)|{'data_start_offset','cluster_lba_offset'}
 fields=[x for x in fields if x[0] in names];selected={x[0] for x in fields}
for name,width,ce,data,expected in fields:
 actual=re.findall(r'\b'+name+r'\s*<=\s*([^;]+);',s)
 assert sorted(v.replace(' ','') for v in actual)==sorted(expected),(name,actual)
 # This check also rules out introducing reset for a previously unreset word.
 assert '0' not in expected
 s=re.sub(r'\b'+name+r'\s*<=\s*[^;]+;','',s)
def declaration(match):
 width,names=match[1],match[2];names=[n.strip() for n in names.split(',')]
 keep=[n for n in names if n not in selected];moved=[n for n in names if n in selected]
 return (f'reg [{width}] '+','.join(keep)+';' if keep else '')+(f'wire [{width}] '+','.join(moved)+';' if moved else '')
s=re.sub(r'reg\s*\[(31:0|23:0)\]\s*([A-Za-z_][A-Za-z0-9_, ]*);',declaration,s)
logic='\n    // Unreset whole-word captures retain their original write edge.\n'
if a.registered_prefetch:
 logic+='''    wire [8:0] scratch_hop_bias={1'b0,sectors_per_cluster}-{8'd0,!(|file_remaining[8:0])};
    wire [23:0] scratch_hop_rounded={1'b0,file_remaining[31:9]}+{{15{scratch_hop_bias[8]}},scratch_hop_bias};
    wire [23:0] scratch_hop_prefetch=scratch_hop_rounded>>cluster_shift;
'''
for name,width,ce,data,expected in fields:
 helper='resource_fat_prefetch_hold' if name in prefetch else 'resource_fat_scratch_hold'
 data=prefetch.get(name,data)
 logic+=f'''    {helper} #(.WIDTH({width})) u_scratch_{name}(
      .clk(clk),.rst(rst),.enable(context_case_enable && ({ce})),.din({data}),.q({name}));
'''
i=s.index('\nendmodule');s=s[:i]+logic+s[i:]
s+='''
module resource_fat_scratch_hold #(parameter WIDTH=32)(
 input wire clk,rst,enable,input wire [WIDTH-1:0] din,output wire [WIDTH-1:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [WIDTH-1:0] held;
 always @(posedge clk)if(!rst && enable)held<=din;
 assign q=held;
`else
 wire [31:0] padded={{(32-WIDTH){1'b0}},din};
 wire [31:0] held;
 assign q=held[WIDTH-1:0];
 // Both addresses are constant, disjoint words. NOREG is one capture;
 // rsta/b stay low because these original scratch registers do not reset.
 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("WRITETHROUGH"),.WRITEMODE_B("WRITETHROUGH"),
  .SRMODE("ASYNC"),.INIT_00(256'd0)) u_hold(
  .clka(clk),.addra(11'd0),.dia(padded[15:0]),.doa(held[15:0]),.bytea(1'b0),.bytewea(1'b0),
  .csa(enable && !rst),.wea(1'b1),.rsta(1'b0),.ocea(1'b1),
  .clkb(clk),.addrb(11'd1024),.dib(padded[31:16]),.dob(held[31:16]),.byteb(1'b0),.byteweb(1'b0),
  .csb(enable && !rst),.web(1'b1),.rstb(1'b0),.oceb(1'b1));
`endif
endmodule
'''
f.write_text(s,encoding='utf-8')
if a.bram9:
 start=s.index('\nmodule resource_fat_scratch_hold #(')
 s=s[:start]+'''
module resource_fat_scratch_hold #(parameter WIDTH=32)(
 input wire clk,rst,enable,input wire [WIDTH-1:0] din,output wire [WIDTH-1:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [WIDTH-1:0] held;
 always @(posedge clk)if(!rst && enable)held<=din;
 assign q=held;
`else
 localparam LANES=(WIDTH+17)/18;
 wire [LANES*18-1:0] padded={{(LANES*18-WIDTH){1'b0}},din};
 wire [LANES*18-1:0] held;
 assign q=held[WIDTH-1:0];
 genvar g;
 generate for(g=0;g<LANES;g=g+1)begin:lane
  // Two disjoint nine-bit words, not an unsupported DP8K 18-bit port.
  EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),
   .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.GSR("DISABLE"),
   .WRITEMODE_A("WRITETHROUGH"),.WRITEMODE_B("WRITETHROUGH")) u_hold(
   .clka(clk),.cea(1'b1),.csa({3{enable && !rst}}),.wea(1'b1),.ocea(1'b1),.rsta(1'b0),
   .addra(13'd0),.dia(padded[g*18+:9]),.doa(held[g*18+:9]),
   .clkb(clk),.ceb(1'b1),.csb({3{enable && !rst}}),.web(1'b1),.oceb(1'b1),.rstb(1'b0),
   .addrb(13'd4096),.dib(padded[g*18+9+:9]),.dob(held[g*18+9+:9]));
 end endgenerate
`endif
endmodule
'''
 if a.native_write_address:
  assert s.count(".addra(13'd0)")==1 and s.count(".addrb(13'd4096)")==1
  s=s.replace(".addra(13'd0)",".addra(13'd7)").replace(".addrb(13'd4096)",".addrb(13'd4103)")
  s=s.replace('.GSR("DISABLE"),',f'.GSR("DISABLE"),.READBACK("{a.bram9_readback}"),')
 f.write_text(s,encoding='utf-8')
if a.registered_prefetch:
 helper='''
// Continuous first-stage calculation; output publishes only at the original CE.
module resource_fat_prefetch_hold #(parameter WIDTH=32)(
 input wire clk,rst,enable,input wire [WIDTH-1:0] din,output wire [WIDTH-1:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [WIDTH-1:0] pending,held;
 always @(posedge clk)begin
  if(!rst)pending<=din;
  if(!rst && enable)held<=pending;
 end
 assign q=held;
`else
 wire [31:0] padded={{(32-WIDTH){1'b0}},din};
 wire [31:0] held;assign q=held[WIDTH-1:0];
 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
  .REGMODE_A("OUTREG"),.REGMODE_B("OUTREG"),.WRITEMODE_A("WRITETHROUGH"),.WRITEMODE_B("WRITETHROUGH"),
  .SRMODE("ASYNC"),.INIT_00(256'd0)) u_hold(
  .clka(clk),.addra(11'd0),.dia(padded[15:0]),.doa(held[15:0]),.bytea(1'b0),.bytewea(1'b0),
  .csa(!rst),.wea(1'b1),.rsta(1'b0),.ocea(enable && !rst),
  .clkb(clk),.addrb(11'd1024),.dib(padded[31:16]),.dob(held[31:16]),.byteb(1'b0),.byteweb(1'b0),
  .csb(!rst),.web(1'b1),.rstb(1'b0),.oceb(enable && !rst));
`endif
endmodule
'''
 f.write_text(s+helper,encoding='utf-8')
