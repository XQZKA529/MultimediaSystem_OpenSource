"""Exercise actual mount FSM arithmetic for all FAT counts and random 32-bit sizes."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
a=p.parse_args();b=a.candidate.resolve();w=b.parent/'fat-product-arithmetic';w.mkdir(parents=True,exist_ok=True)
tb='''module tb;
reg clk=0,rst=1;always #5 clk=~clk;
fat32_ro dut(.clk(clk),.rst(rst),.blk_grant(1'b0),.blk_data(8'd0),.blk_data_valid(1'b0),
.blk_end(1'b0),.blk_error(1'b0),.mount_start(1'b0),.dir_start(1'b0),.file_start(1'b0),
.file_first_cluster(32'd0),.file_size(32'd0),.file_read_limit(32'd0),.file_read_ready(1'b0),
.file_abort(1'b0),.map_start(1'b0),.map_first_cluster(32'd0),.map_size(32'd0),.map_abort(1'b0));
wire [6:0] state=dut.state_encoded;
wire [31:0] area=dut.fat_area_sectors,offset=dut.data_start_offset;
reg [31:0] sectors,expected_area,expected_offset;reg [15:0] reserved;
integer count,trial,cycles,checks=0;
initial begin
repeat(4)@(negedge clk);
for(count=0;count<256;count=count+1)for(trial=0;trial<128;trial=trial+1)begin
rst=1;@(negedge clk);rst=0;
case(trial)
0:sectors=0;1:sectors=1;2:sectors=32'hffffffff;
3:sectors=32'h80000000;4:sectors=32'h01010101;
5:sectors=32'h7fffffff;default:sectors=$random;
endcase
reserved=$random;expected_area=sectors*count;expected_offset=expected_area+reserved;
// Deposit valid registered operands immediately before the real GEOM1 state.
// This tests the actual RTL cases without a card model restricting FAT counts.
dut.fat_sectors=sectors;dut.num_fats=count;dut.reserved_sectors=reserved;dut.state_encoded=7'd5;
cycles=0;
while(state!=7)begin @(negedge clk);cycles=cycles+1;if(cycles>10)$fatal(1,"unbounded product preparation");end
if(area!==expected_area || offset!==expected_offset)$fatal(1,"mount arithmetic differs nfat=%0d sectors=%h got=%h/%h expected=%h/%h",count,sectors,area,offset,expected_area,expected_offset);
checks=checks+1;
end
$display("PASS actual FAT mount FSM %0d products/sums: all 256 FAT counts, boundaries/random/32-bit wrap, <=8 added preparation clocks",checks);$finish;
end endmodule
'''
(w/'tb.v').write_text(tb,encoding='utf-8')
simulate(w,'tb',[b/'rtl/fat/fat32_ro.v',w/'tb.v'],includes=[b/'rtl',b/'rtl/pkg'],native=True)
