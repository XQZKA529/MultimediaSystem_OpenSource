"""Two unsigned native multipliers compute the exact low 32 bits of FAT area."""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
old='fat_area_sectors<=fat_sectors*num_fats;';assert s.count(old)==1
s=s.replace(old,'fat_area_sectors<=fat_area_product;')
s=s.replace('reg [31:0] fat_area_sectors,data_start_offset,cluster_lba_offset;', 'reg [31:0] fat_area_sectors,data_start_offset,cluster_lba_offset;\nwire [31:0] fat_area_product;')
i=s.index('\nendmodule');s=s[:i]+'''\n
    resource_fat_area_mul u_area_product(.clk(clk),.a(fat_sectors),.b(num_fats),.q(fat_area_product));
'''+s[i:]
s+='''
module resource_fat_area_mul(input wire clk,input wire [31:0] a,input wire [7:0] b,output wire [31:0] q);
`ifdef DB_BEHAVIORAL_RAM
 assign q=a*b;
`else
 wire [35:0] low,high;
 wire [13:0] upper=low[31:18]+high[13:0];
 assign q={upper,low[17:0]};
 EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("DISABLE"),
  .SRMODE("ASYNC"),.MODE("MULT18X18C")) u_low(
  .clk(clk),.a(a[17:0]),.b({10'd0,b}),.acin(18'd0),.bcin(18'd0),
  .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
  .cea(1'b0),.ceb(1'b0),.cepd(1'b0),.rstan(1'b1),.rstbn(1'b1),.rstpdn(1'b1),.acout(),.bcout(),.p(low));
 EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("DISABLE"),
  .SRMODE("ASYNC"),.MODE("MULT18X18C")) u_high(
  .clk(clk),.a({4'd0,a[31:18]}),.b({10'd0,b}),.acin(18'd0),.bcin(18'd0),
  .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
  .cea(1'b0),.ceb(1'b0),.cepd(1'b0),.rstan(1'b1),.rstbn(1'b1),.rstpdn(1'b1),.acout(),.bcout(),.p(high));
`endif
endmodule
'''
f.write_text(s,encoding='utf-8')
