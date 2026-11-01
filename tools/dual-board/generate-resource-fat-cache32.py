"""Pack the 128x32 FAT cache into one native BRAM32K using both 16-bit ports.

Cache refill and lookup are mutually exclusive phases. Both ports write the
two halves on each fourth byte, otherwise read the same indexed word. The
existing FAT_WAIT/EVAL and MAP_FAT_WAIT/GET stages retain the read latency.
The complete 512-byte capacity and all 32 stored bits are preserved.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace('reg [31:0] fat_mem [0:127] /* fehdl force_ram=1, ram_style="bram" */;','')
s=s.replace('reg [31:0] fat_q;','wire [31:0] fat_q;')
s=s.replace('    fat_q    <= fat_mem[fat_addr];','')
old="2'd3: fat_mem[rd_index[8:2]]<={blk_data_i,fat_assemble};"
assert s.count(old)==1;s=s.replace(old,"2'd3: begin end // Native cache captures the assembled word on this edge.")
insert='''
    wire cache_refill_write=!rst && context_case_enable && control_state==S_RD_WAIT &&
      blk_data_valid_i && rd_kind==RD_FAT && rd_index<512 && rd_index[1:0]==2'd3;
    resource_fat_cache32 u_fat_cache(.clk(clk),.write(cache_refill_write),
      .write_address(rd_index[8:2]),.read_address(fat_addr),
      .din({blk_data_i,fat_assemble}),.q(fat_q));
'''
s=s.replace('    wire geometry_capture=',insert+'    wire geometry_capture=',1)
s+='''
module resource_fat_cache32(input wire clk,write,input wire [6:0] write_address,read_address,
 input wire [31:0] din,output wire [31:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [31:0] mem[0:127],qr;
 assign q=qr;
 always @(posedge clk)if(write)mem[write_address]<=din;else qr<=mem[read_address];
`else
 wire [6:0] address=write ? write_address:read_address;
 // Each half uses a disjoint 1024-word physical bank, as in the proven
 // 25-bit Goertzel history. No simultaneous read/write of a physical word.
 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG")) u_cache(
  .clka(clk),.addra({4'd0,address}),.doa(q[15:0]),.dia(din[15:0]),
  .bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(write),.rsta(1'b0),.ocea(1'b1),
  .clkb(clk),.addrb({4'b1000,address}),.dob(q[31:16]),.dib(din[31:16]),
  .byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(write),.rstb(1'b0),.oceb(1'b1));
`endif
endmodule
'''
assert 'fat_mem' not in s
f.write_text(s,encoding='utf-8')
