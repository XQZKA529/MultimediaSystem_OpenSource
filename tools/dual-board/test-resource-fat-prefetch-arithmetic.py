"""Check the actual new FAT prep expressions against full-width old arithmetic."""
import argparse,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True);a=p.parse_args()
b=a.candidate.resolve();w=b.parent/'scratch-prefetch-arithmetic';w.mkdir(parents=True,exist_ok=True)
s=(b/'rtl/fat/fat32_ro.v').read_text(encoding='utf-8-sig')
logic=re.search(r'    wire \[8:0\] scratch_hop_bias=.*?wire \[23:0\] scratch_hop_prefetch=[^;]+;',s,re.S)[0]
count=re.search(r'u_scratch_file_sector_count\(.*?\.din\((.*?)\),\.q',s,re.S)[1]
tb=w/'tb.v';tb.write_text('''module tb;
reg [31:0] file_remaining=0;reg [7:0] sectors_per_cluster=0;reg [2:0] cluster_shift=0;
wire [23:0] old_count=({1'b0,file_remaining}+33'd511)>>9;
wire [23:0] old_rounded=old_count+{16'd0,sectors_per_cluster}-24'd1;
wire [23:0] old_hop=old_rounded>>cluster_shift;
'''+logic+'\nwire [23:0] new_count='+count+''';
integer hi,lo,sp,sh,n,checks=0;
task check;begin #1;
 if(new_count!==old_count || scratch_hop_rounded!==old_rounded || scratch_hop_prefetch!==old_hop)
  $fatal(1,"prep arithmetic overflow/illegal-input mismatch size=%h spc=%d shift=%d",file_remaining,sectors_per_cluster,cluster_shift);
 checks=checks+1;
end endtask
initial begin
for(hi=0;hi<4;hi=hi+1)for(lo=0;lo<512;lo=lo+1)for(sp=0;sp<256;sp=sp+1)for(sh=0;sh<8;sh=sh+1)begin
 file_remaining={(hi==0 ? 23'd0:hi==1 ? 23'd1:hi==2 ? 23'h7ffffe:23'h7fffff),lo[8:0]};
 sectors_per_cluster=sp;cluster_shift=sh;check;
end
for(n=0;n<500000;n=n+1)begin file_remaining=$random;sectors_per_cluster=$random;cluster_shift=$random;check;end
$display("PASS %d exact unsigned prep expressions: all remainders, every legal/illegal SPC byte, all shifts, zero and 32-bit overflow boundaries plus random inputs",checks);$finish;
end endmodule
''',encoding='utf-8')
simulate(w/'behavioral','tb',[tb])
