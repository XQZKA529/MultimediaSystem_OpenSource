"""Native multiplier modulo arithmetic, including all FAT-count byte values."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True);a=p.parse_args();b=a.candidate.resolve()
w=b.parent/'fat-product-split-arithmetic';w.mkdir(parents=True,exist_ok=True)
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0;always #5 clk=~clk;reg [31:0] a=0;reg [7:0] b=0;
wire [31:0] q;wire [39:0] exact={8'd0,a}*{32'd0,b};
resource_fat_area_mul dut(clk,a,b,q);
integer n,j,checks=0;
task check;begin #2;if(q!==exact[31:0])$fatal(1,"native FAT product mismatch %h * %h =%h expected %h",a,b,q,exact[31:0]);checks=checks+1;end endtask
initial begin #100;
for(j=0;j<256;j=j+1)begin b=j;
 a=0;check;a=1;check;a=32'hffffffff;check;a=32'h80000000;check;
 a=32'h0003ffff;check;a=32'h00040000;check;a=32'hffff0000;check;
 for(n=0;n<2000;n=n+1)begin a=$random;check;end
end
$display("PASS %d exact native unsigned 32x8 modulo-32 products, every count byte, split/carry/overflow boundaries and random sectors",checks);$finish;
end endmodule
''',encoding='utf-8')
simulate(w/'native','tb',[b/'rtl/fat/fat32_ro.v',tb],includes=[b/'rtl'],native=True)
