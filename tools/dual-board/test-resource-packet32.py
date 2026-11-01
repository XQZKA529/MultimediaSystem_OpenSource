"""Compare native 9K/32K logical packet memories with independent clocks."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--fast-clock',action='store_true',help='100/125 MHz ports, with read addresses driven in their own clock domain')
p.add_argument('--native-only',action='store_true',help='Compare native 9K/32K implementations without repeating the identical behavioral implementations')
p.add_argument('--evidence',type=Path,help='Directory for reproducible test sources, hashes and logs')
a=p.parse_args();b=a.candidate.resolve();w=a.evidence.resolve() if a.evidence else b.parent/('packet32-fast-clock-v2' if a.fast_clock else 'packet32-equivalence');w.mkdir(parents=True,exist_ok=True)
assert 'defparam u_link.u_packet_ram.u_ram.IMPLEMENT="32K";' in (b/'rtl/top_media.v').read_text(encoding='utf-8-sig')
s='''module tb;
reg aclk=0,bclk=0;always #5 aclk=~aclk;always #7 bclk=~bclk;
reg we=0;reg [10:0] a=0,b=0;reg [31:0] din=0;
wire [31:0] qa,qb,ea,eb;reg checking=0;integer n,ac=0,bc=0;
reg [31:0] rng=32'h57a39b1c;
db_packet_ram #(.AW(11),.DW(32)) dut(aclk,we,a,din,qa,bclk,b,qb);
db_packet_ram #(.AW(11),.DW(32)) golden(aclk,we,a,din,ea,bclk,b,eb);
`ifndef DB_BEHAVIORAL_RAM
defparam dut.u_ram.IMPLEMENT="32K";
`endif
always @(posedge aclk)begin #1;if(checking)begin
 if(qa!==ea)$fatal(1,"Packet A read/hold differs a=%d got=%h expected=%h we=%b",a,qa,ea,we);ac=ac+1;
end end
always @(posedge bclk)begin #1;if(checking)begin
 if(qb!==eb)$fatal(1,"Packet B read differs b=%d got=%h expected=%h",b,qb,eb);bc=bc+1;
end end
initial begin
 repeat(20)@(negedge aclk);
 for(n=0;n<2048;n=n+1)begin
  @(negedge aclk);we=1;a=n;rng=rng*32'd1664525+32'd1013904223;din=rng;
 end
 @(negedge aclk);we=0;a=0;
 repeat(3)@(negedge aclk);checking=1;
 for(n=0;n<4096;n=n+1)begin
  @(negedge aclk);a=n%2048;b=(n*73+157)%2048;
 end
 // Different halves avoid undefined cross-clock same-address write/read.
 for(n=0;n<30000;n=n+1)begin
  @(negedge aclk);rng=rng*32'd1664525+32'd1013904223;
  a={1'b0,rng[9:0]};b={1'b1,rng[25:16]};we=n%3!=0;din=rng;
 end
 @(negedge aclk);we=0;repeat(3)@(negedge aclk);
 for(n=0;n<2048;n=n+1)begin @(negedge aclk);a=n;b=n;end
 $display("PASS packet RAM all 2048 full-width words, independent 100/71MHz clocks, %d A read/hold and %d B read cycles, concurrent noncolliding writes, full capacity and upper bits",ac,bc);$finish;
end endmodule
'''
if a.fast_clock:
    s=s.replace('always #7 bclk=~bclk;', 'always #4 bclk=~bclk;')
    s=s.replace('wire [31:0] qa,qb,ea,eb;', 'reg [10:0] requested_b=0;always @(negedge bclk)b<=requested_b;\nwire [31:0] qa,qb,ea,eb;')
    s=s.replace('b=(n*73+157)%2048;', 'requested_b=(n*73+157)%2048;')
    s=s.replace("b={1'b1,rng[25:16]};", "requested_b={1'b1,rng[25:16]};")
    s=s.replace('a=n;b=n;', 'a=n;requested_b=n;')
    s=s.replace('100/71MHz', '100/125MHz')
tb=w/'tb.v';tb.write_text(s,encoding='utf-8')
for native in ((True,) if a.native_only else (False,True)):
    simulate(w/('native' if native else 'behavioral'),'tb',[b/'rtl/link/db_packet_ram.v',tb],native=native,
             defines=[] if native else ['DB_BEHAVIORAL_RAM'])
