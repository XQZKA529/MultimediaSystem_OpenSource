"""Exhaust the ROM and all sector bytes with concurrent independent reads.

Same-address read/write collision data is deliberately not consumed, matching
the FAT's sector-capture/decode separation. Public FAT cycle oracles are separate.
"""
import argparse
from pathlib import Path
from resource_sim import simulate

p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--tag',default='sector-lfn-equivalence-v2')
a=p.parse_args();b=a.candidate.resolve();w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
function=(b.parent/'sector-lfn-generation/original_base.v').read_text()
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0;always #5 clk=~clk;reg write=0;reg [8:0] wa=0,ra=0;
reg [7:0] din=0;reg [4:0] ordinal=0;wire [7:0] q,product;
reg [7:0] memory[0:511],expected,expected_product,base;
integer n,checks=0,collisions=0;reg [31:0] rng=32'h519a7fe3;
resource_sector_lfn_ram dut(clk,write,wa,din,ra,q,ordinal,product);
'''+function+'''
initial begin
 for(n=0;n<512;n=n+1)begin
  @(negedge clk);write=1;wa=n;din=n^8'had;memory[n]=din;
  @(posedge clk);#1;
 end
 @(negedge clk);write=0;
 for(n=0;n<32;n=n+1)begin
  ordinal=n;@(posedge clk);#1;
  expected_product=n*13;
  base=n>=1 && n<=19 ? product-8'd13:8'd247;
  if(product!==expected_product || base!==lfn_ordinal_base(n))$fatal(1,"LFN ROM/default/overflow ordinal %d",n);
  @(negedge clk);
 end
 for(n=0;n<60000;n=n+1)begin
  rng=rng*32'd1664525+32'd1013904223;write=n%3==0;wa=rng[8:0];din=rng[31:24];
  ra=n%512;ordinal=rng[20:16];if(n%19==0)ra=wa;
  expected=memory[ra];expected_product=ordinal*13;
  @(posedge clk);#1;
  if(!(write && wa==ra))begin
   if(q!==expected)$fatal(1,"Sector RAM mismatch n=%d read=%d got=%h expected=%h write=%b addr=%d",n,ra,q,expected,write,wa);checks=checks+1;
  end else collisions=collisions+1;
  if(!write && product!==expected_product)$fatal(1,"ROM disturbed by sector refill");
  if(write)memory[wa]=din;
  @(negedge clk);
 end
 $display("PASS 32 LFN ordinal products/base/defaults/overflow; %d defined sector reads; %d nonconsumed read/write collisions; all 512 bytes and refills",checks,collisions);$finish;
end endmodule
''',encoding='utf-8')
for native in (False,True):
    simulate(w/('native' if native else 'behavioral'),'tb',[b/'rtl/fat/fat32_ro.v',tb],
             includes=[b/'rtl',b/'rtl/fat',b/'rtl/pkg'],native=native,
             defines=[] if native else ['DB_BEHAVIORAL_RAM'])
