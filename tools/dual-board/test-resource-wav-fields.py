"""Exact WAV format validation oracle, including repeated chunks/reject priority."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
a=p.parse_args();b=a.candidate.resolve();root=Path(__file__).resolve().parents[2]
w=b.parent/'wav-field-equivalence';w.mkdir(parents=True,exist_ok=True)
ref=w/'reference.v';ref.write_text((root/'build/resource-v1/base/media/rtl/audio/wav_header_parse.v').read_text(encoding='utf-8-sig').replace(
 'module wav_header_parse (','module wav_header_reference ('),encoding='utf-8')
tb='''module tb;
reg clk=0,rst=1,start=0,valid=0;always #5 clk=~clk;
reg [7:0] byte_data=0,header[0:67];integer trial,i,j,checks=0;
'''
for role,module in [('ref','wav_header_reference'),('dut','wav_header_parse')]:
 tb+=f'''wire done_{role},ok_{role},payload_{role},channels_{role};wire [3:0] reject_{role};
wire [31:0] offset_{role},length_{role};
{module} {role}(.clk(clk),.rst(rst),.start_pulse(start),.byte_valid(valid),.byte_data(byte_data),
.parse_done(done_{role}),.parse_ok(ok_{role}),.payload_start(payload_{role}),.channels(channels_{role}),
.reject_code(reject_{role}),.data_byte_offset(offset_{role}),.data_byte_len(length_{role}));
'''
tb+='''always @(negedge clk) if(!rst) begin
 if({done_dut,ok_dut,payload_dut,channels_dut,reject_dut,offset_dut,length_dut}!==
 {done_ref,ok_ref,payload_ref,channels_ref,reject_ref,offset_ref,length_ref})
 $fatal(1,"WAV public cycle mismatch trial=%0d i=%0d",trial,i);
 checks=checks+1;
end
task put32;input integer at;input [31:0] v;begin
header[at]=v[7:0];header[at+1]=v[15:8];header[at+2]=v[23:16];header[at+3]=v[31:24];end endtask
task base;begin
for(j=0;j<68;j=j+1)header[j]=0;
header[0]="R";header[1]="I";header[2]="F";header[3]="F";put32(4,100);
header[8]="W";header[9]="A";header[10]="V";header[11]="E";
for(j=12;j<60;j=j+24) begin
 header[j]="f";header[j+1]="m";header[j+2]="t";header[j+3]=" ";put32(j+4,16);
 header[j+8]=1;header[j+10]=2;put32(j+12,48000);put32(j+16,192000);
 header[j+20]=4;header[j+22]=16;
end
header[60]="d";header[61]="a";header[62]="t";header[63]="a";put32(64,8);
end endtask
initial begin
repeat(4)@(negedge clk);rst=0;
for(trial=0;trial<24000;trial=trial+1) begin
 base;
 if(trial<17408) header[trial/256]=trial%256;
 else begin
  for(j=0;j<8;j=j+1)header[20+j]=$random;
  if(trial%3==0) begin header[20]=1;header[21]=0;put32(24,48000);end
  if(trial%5==0) begin header[22]=1;header[23]=0;end
  if(trial%7==0) begin header[34]=16;header[35]=0;end
 end
 @(negedge clk);valid=0;start=1;@(negedge clk);start=0;
 for(i=0;i<68;i=i+1) begin
  valid=1;byte_data=header[i];@(negedge clk);
  if(i%7==0) begin valid=0;@(negedge clk);end
 end
 valid=0;repeat(3)@(negedge clk);
 if(trial%71==0) begin rst=1;#2;rst=0;end
end
$display("PASS WAV exact public interface %0d cycles: 68x256 byte mutations, repeated fmt, random invalid fields, stalls/restart/reset/reject priorities",checks);$finish;
end endmodule
'''
(w/'tb.v').write_text(tb,encoding='utf-8')
simulate(w,'tb',[ref,b/'rtl/audio/wav_header_parse.v',w/'tb.v'])
simulate(w/'chunk-boundaries','tb_wav_header_parse',[b/'rtl/audio/wav_header_parse.v',b/'sim/tb_wav_header_parse.v'])
