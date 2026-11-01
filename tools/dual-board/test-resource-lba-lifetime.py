"""Compare every LBA-stream public output cycle, including retries/illegal inputs."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--watch-skip',action='store_true')
a=p.parse_args();b=a.candidate.resolve();root=Path(__file__).resolve().parents[2]
w=b.parent/'lba-lifetime-equivalence';w.mkdir(parents=True,exist_ok=True)
ref=w/'reference.v';ref.write_text((root/'build/resource-v1/base/media/rtl/storage/lba_stream.v').read_text(encoding='utf-8-sig').replace(
 'module lba_stream #','module lba_reference #'),encoding='utf-8')
tb='''module tb;
reg clk=0,rst=1,start=0,abort=0,ready=0,grant=0,dvalid=0,ending=0,error=0;
always #5 clk=~clk;
reg [31:0] lba=0,nsec=0,offset=0,length=0;reg [8:0] count=0;reg [7:0] data=0;
integer cycle,checks=0,advances=0,completions=0;
'''
for n,limit in enumerate([0,1,64,65535,-1]):
 for role,module in [('ref','lba_reference'),('dut','lba_stream')]:
  tb+=f'''wire [7:0] addr_{role}{n},data_{role}{n};wire valid_{role}{n},done_{role}{n},ok_{role}{n},error_{role}{n},abort_{role}{n},busy_{role}{n},req_{role}{n};
wire [1:0] retry_{role}{n};wire [31:0] lba_{role}{n};wire [15:0] count_{role}{n};
{module} #(.MAX_BURST({limit}),.RETRY_WAIT(2)) {role}{n}(
.clk(clk),.rst(rst),.map_rd_addr(addr_{role}{n}),.map_rd_lba(lba),.map_rd_nsec(nsec),.map_count(count),
.str_start(start),.str_file_off(offset),.str_len(length),.str_abort(abort),.str_ready(ready),
.str_data(data_{role}{n}),.str_data_valid(valid_{role}{n}),.str_done(done_{role}{n}),.str_ok(ok_{role}{n}),
.str_error(error_{role}{n}),.str_aborted(abort_{role}{n}),.str_busy(busy_{role}{n}),.str_retry_used(retry_{role}{n}),
.blk_req(req_{role}{n}),.blk_lba(lba_{role}{n}),.blk_count(count_{role}{n}),.blk_grant(grant),
.blk_data(data),.blk_data_valid(dvalid),.blk_end(ending),.blk_error(error));
'''
 if a.watch_skip:
  tb+=f'always @(negedge clk)if(!rst && dut{n}.skip_bytes!==ref{n}.skip_bytes)$fatal(1,"full32 skip/borrow mismatch case {n}");\n'
 tb+=f'''always @(negedge clk) if(!rst) begin
 if({{addr_ref{n},data_ref{n},valid_ref{n},done_ref{n},ok_ref{n},error_ref{n},abort_ref{n},busy_ref{n},retry_ref{n},req_ref{n},lba_ref{n},count_ref{n}}}!==
 {{addr_dut{n},data_dut{n},valid_dut{n},done_dut{n},ok_dut{n},error_dut{n},abort_dut{n},busy_dut{n},retry_dut{n},req_dut{n},lba_dut{n},count_dut{n}}})
 $fatal(1,"LBA public outputs differ case={n} cycle=%0d",cycle);
 if(ref{n}.state==8)begin
  if(ref{n}.cur_nsec!==ref{n}.burst_base_nsec)$fatal(1,"cursor lifetime proof failed");
  advances=advances+1;
 end
 if(done_dut{n})completions=completions+1;
 checks=checks+1;
end
'''
tb+='''initial begin
repeat(4)@(negedge clk);rst=0;
for(cycle=0;cycle<1000000;cycle=cycle+1)begin
 @(negedge clk);start=($random&15)==0;abort=($random&511)==0;ready=$random;grant=($random&3)==0;
 dvalid=$random;ending=($random&63)==0;error=($random&127)==0;data=$random;
 lba=$random;nsec=($random&255);offset=($random&65535);length=($random&65535);count=($random&7);
 if(cycle%17==0)begin nsec=$random;offset=$random;length=$random;end
 if(cycle%1031==1000)begin rst=1;#2;rst=0;end
end
if(advances<100 || completions<100)$fatal(1,"insufficient state coverage");
$display("PASS LBA exact public outputs %0d checks, %0d burst advances/lifetime proofs, %0d completions, random wrap/abort/retry/reset/backpressure",checks,advances,completions);$finish;
end endmodule
'''
(w/'tb.v').write_text(tb,encoding='utf-8')
simulate(w,'tb',[ref,b/'rtl/storage/lba_stream.v',w/'tb.v'])
