"""Cycle-equivalence oracle for BMP byte validation folding, including invalids."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--native',action='store_true');p.add_argument('--tag',default='bmp-field-equivalence')
a=p.parse_args();b=a.candidate.resolve();root=Path(__file__).resolve().parents[2]
w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
ref=w/'reference.v'
ref.write_text((root/'build/resource-v1/base/media/rtl/image/bmp_header_parser.v').read_text(encoding='utf-8-sig').replace(
 'module bmp_header_parser #','module bmp_header_reference #'),encoding='utf-8')
tb='''module tb;
reg clk=0,rst=1,start=0,bv=0,finish=0;always #5 clk=~clk;
reg [7:0] byte_data=0,header[0:53];reg [31:0] actual_size;
integer trial,i,j,k,checks=0,bytes;reg active=0;
'''
for n,dim in enumerate([1,4096,8191,8192,65536]):
 for role,module in [('ref','bmp_header_reference'),('dut','bmp_header_parser')]:
    tb+=f'''wire done_{role}{n},ok_{role}{n};wire [12:0] w_{role}{n},h_{role}{n};
wire [31:0] offset_{role}{n},stride_{role}{n},last_{role}{n};
{module} #(.MAX_DIM({dim})) {role}{n}(.clk(clk),.rst(rst),.start(start),.byte_valid(bv),.byte_data(byte_data),
.finish(finish),.actual_size(actual_size),.done(done_{role}{n}),.ok(ok_{role}{n}),
.width(w_{role}{n}),.height(h_{role}{n}),.pixel_offset(offset_{role}{n}),.row_stride(stride_{role}{n}),.payload_end(last_{role}{n}));
'''
 tb+=f'''always @(negedge clk) if(active && !rst) begin
 if({{done_dut{n},ok_dut{n}}}!=={{done_ref{n},ok_ref{n}}}) $fatal(1,"control/validation mismatch trial=%0d dim={dim}",trial);
 if(done_ref{n} && {{w_dut{n},h_dut{n},offset_dut{n},stride_dut{n},last_dut{n}}}!==
 {{w_ref{n},h_ref{n},offset_ref{n},stride_ref{n},last_ref{n}}}) $fatal(1,"result mismatch trial=%0d dim={dim}",trial);
end
'''
tb+='''task put32;input integer at;input [31:0] v;begin
header[at]=v[7:0];header[at+1]=v[15:8];header[at+2]=v[23:16];header[at+3]=v[31:24];end endtask
task base;begin
for(j=0;j<54;j=j+1)header[j]=0;
header[0]="B";header[1]="M";put32(2,160);put32(10,54);put32(14,40);
put32(18,5);put32(22,5);header[26]=1;header[28]=24;actual_size=160;end endtask
initial begin
repeat(4)@(negedge clk);rst=0;
for(trial=0;trial<20000;trial=trial+1) begin
 base;bytes=54;
 if(trial<13824) header[trial/256]=trial%256;
 else begin
  put32(18,$random);put32(22,$random);put32(10,$random);put32(14,$random);
  put32(2,$random);actual_size=$random;
  if(trial%3==0) begin put32(18,trial%8193);put32(22,trial%8193);end
  if(trial%5==0) bytes=trial%54;
 end
 @(negedge clk);start=1;active=0;@(negedge clk);start=0;active=1;
 for(i=0;i<bytes;i=i+1) begin
  bv=1;byte_data=header[i];@(negedge clk);
  if(i%7==0) begin bv=0;@(negedge clk);end
 end
 bv=0;finish=1;@(negedge clk);finish=0;
 repeat(8)@(negedge clk);checks=checks+5;
 if(trial%71==0) begin rst=1;#2;rst=0;end
end
$display("PASS BMP exact cycles/results: %0d parameterized transactions, all 54x256 single-byte mutations, random/overflow/truncated/stall/reset",checks);$finish;
end endmodule
'''
(w/'tb.v').write_text(tb,encoding='utf-8')
simulate(w,'tb',[ref,b/'rtl/image/bmp_header_parser.v',w/'tb.v'],native=a.native,defines=[] if a.native else ['DB_BEHAVIORAL_RAM'])
simulate(w/'header-regression','tb_bmp_header',[b/'rtl/image/bmp_header_parser.v',
 b/'rtl/image/image_scale_geometry.v',b/'sim/tb_bmp_header.v'],native=a.native,defines=[] if a.native else ['DB_BEHAVIORAL_RAM'])
