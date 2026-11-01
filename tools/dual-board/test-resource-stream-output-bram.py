"""Exact FIFO public interface including invalid dout, clear and short reset."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--tag',default='stream-output-bram-equivalence-v2')
a=p.parse_args();b=a.candidate.resolve();w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
tb='''module tb;reg clk=0,rst=1,clear=0,push=0,ready=0;reg [31:0] din=0;
always #5 clk=~clk;integer n,checks=0;reg [31:0] rng=32'hb91845ac;
'''
for i,aw in enumerate((3,9,10,12)):
    for role,mod in [('dut','resource_media_stream_fifo'),('golden','db_stream_fifo')]:
        tb+=f'''wire [{aw}:0] free_{role}{i};wire ov_{role}{i},v_{role}{i},empty_{role}{i};wire [31:0] q_{role}{i};
{mod} #(.AW({aw})) {role}{i}(clk,rst,clear,push,din,free_{role}{i},ov_{role}{i},v_{role}{i},q_{role}{i},ready,empty_{role}{i});
'''
    tb+=f'''always @(posedge clk)begin #1;
 if({{free_dut{i},ov_dut{i},v_dut{i},q_dut{i},empty_dut{i}}}!=={{free_golden{i},ov_golden{i},v_golden{i},q_golden{i},empty_golden{i}}})
 $fatal(1,"FIFO read-stage exact mismatch AW={aw} cycle=%d got=%h expected=%h",checks,q_dut{i},q_golden{i});
end
'''
tb+='''always @(posedge clk)checks=checks+1;
initial begin repeat(5)@(negedge clk);rst=0;
for(n=0;n<350000;n=n+1)begin
 rng=rng*32'd1664525+32'd1013904223;din=rng;
 case((n/8192)%4)
  0:begin push=1;ready=0;end
  1:begin push=0;ready=1;end
  2:begin push=rng[0];ready=rng[4];end
  3:begin push=1;ready=1;end
 endcase
 // First fill and drain even the 4096-word generic fallback completely.
 if(n<8192)begin push=1;ready=0;end
 else if(n<28192)begin push=0;ready=1;end
 clear=n>=28192 && (n%1777==0 || n%39999<3);
 if(n>=28192 && n%2017==13)begin rst=1;#2;rst=0;end
 @(negedge clk);
end
push=0;clear=0;ready=1;repeat(20000)@(negedge clk);
$display("PASS 1480020 exact FIFO parameterized public checks: 8/512/1024/4096 words, complete capacity/wraps/full overflow, simultaneous push/pop, pending clear, backpressure and short async resets; invalid dout also exact");$finish;
end endmodule
'''
f=w/'tb.v';f.write_text(tb,encoding='utf-8')
for native in (False,True):
    simulate(w/('native' if native else 'behavioral'),'tb',[b/'rtl/seam/db_stream_fifo.v',b/'rtl/seam/seam_media.v',f],
             includes=[b/'rtl',b/'rtl/link',b/'rtl/seam'],native=native,
             defines=[] if native else ['DB_BEHAVIORAL_RAM'])
