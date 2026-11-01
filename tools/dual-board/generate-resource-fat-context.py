"""Store full-precision mounted FAT/data LBAs in embedded context RAM.

The context's two-cycle native read settles in existing GEOM4/4B/4C stages,
before mount_ok/done can publish it. Native output registers provide async
reset/invalid masking without a bank of fabric flip-flops. Port B is disabled
during writes, so there is no read/write collision on the single used word.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
args=p.parse_args();snapshot(args.source,args.destination)
file=args.destination/'rtl/fat/fat32_ro.v'
s=file.read_text(encoding='utf-8-sig')
s=s.replace('partition_lba, partition_sectors, fat_lba, data_lba, root_cluster, max_cluster;',
            'partition_lba, partition_sectors, root_cluster, max_cluster;\nwire [31:0] fat_lba,data_lba;')
s=s.replace('fat_lba<=0; data_lba<=0;','')
s=s.replace("          fat_lba<=partition_lba+{16'd0,reserved_sectors};\n          data_lba<=partition_lba+data_start_offset;",'')
insert='''// Published geometry is a readonly context after successful mount. The RAM
// output reset stays asserted until the write has completed; existing mount
// preparation stages absorb both embedded read/output-register cycles.
wire mounted_context_write=!rst && state_encoded==S_MOUNT_GEOM3_CHECK && !geom3_bad;
wire [31:0] next_fat_lba=partition_lba+{16'd0,reserved_sectors};
wire [31:0] next_data_lba=partition_lba+data_start_offset;
reg mounted_context_ready;
always @(posedge clk or posedge rst) begin
    if(rst) mounted_context_ready<=0;
    else if(mounted_context_write) mounted_context_ready<=0;
    else if(state_encoded==S_MOUNT_GEOM4) mounted_context_ready<=1;
end
resource_fat_lba_context u_mounted_context(.clk(clk),.output_reset(rst || !mounted_context_ready),
    .write_en(mounted_context_write),.write_data({next_data_lba,next_fat_lba}),.q({data_lba,fat_lba}));
'''
s=s.replace('wire [31:0] lba_cluster_offset=',insert+'wire [31:0] lba_cluster_offset=')
assert 'fat_lba<=' not in s and 'data_lba<=' not in s
helper='''
module resource_fat_lba_context(input wire clk,output_reset,write_en,
    input wire [63:0] write_data,output wire [63:0] q);
`ifdef DB_BEHAVIORAL_RAM
reg [63:0] storage=0,read_latch=0,output_latch=0;
assign q=output_latch;
always @(posedge clk) if(write_en) storage<=write_data;
always @(posedge clk or posedge output_reset)
    if(output_reset) read_latch<=0;else if(!write_en) read_latch<=storage;
always @(posedge clk or posedge output_reset)
    if(output_reset) output_latch<=0;else output_latch<=read_latch;
`else
'''
for bank in range(4):
    low=16*bank;high=low+15
    helper+=f'''EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
 .REGMODE_A("NOREG"),.REGMODE_B("OUTREG"),.SRMODE("ASYNC"),.INIT_00(256'd0)) u{bank}(
 .clka(clk),.addra(11'd0),.doa(),.dia(write_data[{high}:{low}]),.bytea(1'b0),.bytewea(1'b0),
 .csa(1'b1),.wea(write_en),.rsta(1'b0),.ocea(1'b1),
 .clkb(clk),.addrb(11'd0),.dob(q[{high}:{low}]),.dib(16'd0),.byteb(1'b0),.byteweb(1'b0),
 .csb(!write_en),.web(1'b0),.rstb(output_reset),.oceb(1'b1));
'''
helper+='`endif\nendmodule\n'
file.write_text(s+helper,encoding='utf-8')
# Only update the implementation-encoding invariant in the old private oracle.
tb=args.destination/'sim/tb_fat32_ro.v';s=tb.read_text(encoding='utf-8-sig')
if 'dut.state_hot' in s:
    start=s.index('wire [63:0] observed_state_hot');end=s.index('reg mount_start=',start)
    s=s[:start]+'''wire [6:0] observed_state=dut.state_encoded;
wire [7:0] observed_diagnostic=dut.state;
wire [7:0] expected_diagnostic={1'b0,observed_state};
always @(negedge clk) if(!rst) begin
 if((observed_state ^ observed_state)!==7'd0 || observed_state>=72)
  $fatal(1,"FAT control state undefined/out of range");
 if(observed_diagnostic!==expected_diagnostic) $fatal(1,"FAT diagnostic state disagrees with control");
end
'''+s[end:]
tb.write_text(s,encoding='utf-8')
