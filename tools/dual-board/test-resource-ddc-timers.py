"""Cycle-equivalent DDC pad/transaction outputs with arbitrary asynchronous pads."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--extended',action='store_true')
a=p.parse_args();b=a.candidate.resolve();root=Path(__file__).resolve().parents[2]
w=b.parent/'ddc-counter-equivalence';w.mkdir(parents=True,exist_ok=True)
if a.extended:w=w/'extended';w.mkdir(parents=True,exist_ok=True)
ref=w/'reference.v';ref.write_text((root/'build/resource-v1/base/render/rtl/driver/ddc_i2c_master.v').read_text().replace(
 'module ddc_i2c_master #','module ddc_i2c_master_reference #'),encoding='utf-8')
tb='''module tb;
reg clk=0,rst=1,start=0,reading=0,scl=1,sda=1;always #5 clk=~clk;
reg [3:0] count=0;reg [55:0] data=0;integer i,checks=0;
'''
for n,(freq,speed,timeout) in enumerate([(1000,50000,0),(2000,500,1),(8000,1000,2),(75000000,50000,20)]):
 for role,module in [('ref','ddc_i2c_master_reference'),('dut','ddc_i2c_master')]:
  tb+=f'''wire busy_{role}{n},done_{role}{n},error_{role}{n},scl_{role}{n},sda_{role}{n};wire [87:0] q_{role}{n};
{module} #(.CLK_HZ({freq}),.I2C_HZ({speed}),.TIMEOUT_MS({timeout})) {role}{n}(
.clk(clk),.rst(rst),.start(start),.read_transaction(reading),.write_count(count),.tx_bytes(data),
.busy(busy_{role}{n}),.done(done_{role}{n}),.error(error_{role}{n}),.rx_bytes(q_{role}{n}),
.scl_in(scl),.sda_in(sda),.scl_low(scl_{role}{n}),.sda_low(sda_{role}{n}));
'''
 tb+=f'''always @(negedge clk) if(!rst) begin
if({{busy_dut{n},done_dut{n},error_dut{n},q_dut{n},scl_dut{n},sda_dut{n}}}!==
{{busy_ref{n},done_ref{n},error_ref{n},q_ref{n},scl_ref{n},sda_ref{n}}})$fatal(1,"DDC counter mismatch case={n} cycle=%0d",i);
checks=checks+1;end
'''
tb+='''initial begin
repeat(4)@(negedge clk);rst=0;
for(i=0;i<1600000;i=i+1)begin
 @(negedge clk);
 if(i<100000)begin
  start=($random&31)==0;reading=$random;count=$random;data={$random,$random};scl=$random;sda=$random;
  if(i%103==70)begin rst=1;#2;rst=0;end
 end else begin start=(i==100000);scl=0;sda=0;end
end
$display("PASS DDC exact pads/outputs %0d checks: parameter boundaries, stretches, NACK, abort/reset, full 20ms timeout",checks);$finish;
end endmodule
'''
(w/'tb.v').write_text(tb,encoding='utf-8')
if a.extended:
 tb=tb.replace('i<1600000','i<1600020').replace('$display("PASS DDC',
     'if(!error_dut3 || busy_dut3)$fatal(1,"20ms timeout not observed");\n$display("PASS DDC')
 (w/'tb.v').write_text(tb,encoding='utf-8')
simulate(w,'tb',[ref,b/'rtl/driver/ddc_i2c_master.v',w/'tb.v'])
simulate(w/'monitor','tb_ddcci_brightness',[b/'rtl/driver/ddc_i2c_master.v',
 b/'rtl/driver/ddcci_brightness.v',b/'sim/tb_ddcci_brightness.v'])
