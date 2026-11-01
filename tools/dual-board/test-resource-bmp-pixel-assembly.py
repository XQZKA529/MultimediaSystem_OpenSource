"""Ready/valid equivalence, including an entire 720p RGB888 source frame."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True)
p.add_argument('--tag',default='bmp-pixel-assembly-equivalence-v2');a=p.parse_args();b=a.candidate.resolve()
w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
ref=w/'reference.v';ref.write_text((a.reference/'rtl/image/bmp_pixel_unpack.v').read_text(encoding='utf-8-sig').replace('module bmp_pixel_unpack(', 'module reference_unpack('),encoding='utf-8')
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0,rst=1,start=0,cancel=0;always #5 clk=~clk;
reg [12:0] width=0,height=0;reg [31:0] offset=0,stride=0;
reg bv=0,ready=0;reg [7:0] data=0;wire br,er,pv,ev,done,edone;wire [23:0] rgb,expected;
bmp_pixel_unpack dut(clk,rst,start,cancel,width,height,offset,stride,bv,data,br,pv,rgb,ready,done);
reference_unpack golden(clk,rst,start,cancel,width,height,offset,stride,bv,data,er,ev,expected,ready,edone);
integer n,sent,pixels=0,checks=0,stalls=0;reg [31:0] rng=32'h7c5a2109;
reg old_stall;reg [23:0] old_rgb;
always @(posedge clk)begin
 old_stall=pv && !ready && !start && !cancel && !rst;old_rgb=rgb;
 #1;
 if({br,pv,done}!=={er,ev,edone})$fatal(1,"BMP unpack handshake/done mismatch %d",checks);
 if(pv && rgb!==expected)$fatal(1,"BMP valid RGB888 mismatch %d",checks);
 if(old_stall && (!pv || rgb!==old_rgb))$fatal(1,"Valid pixel changed under backpressure");
 if(old_stall)stalls=stalls+1;checks=checks+1;
end
initial begin repeat(5)@(negedge clk);rst=0;
for(n=0;n<250000;n=n+1)begin
 rng=rng*32'd1664525+32'd1013904223;
 width=rng[12:0];height=rng[25:13];offset=n%13==0 ? rng:0;
 stride=rng;data=rng[23:16];bv=rng[0];ready=rng[3];
 start=n%41==0 || n%503<3;cancel=n%173==0;
 if(n%997==17)begin rst=1;#2;rst=0;end
 @(negedge clk);
end
start=1;cancel=0;bv=0;ready=1;width=1280;height=720;offset=54;stride=3840;
@(negedge clk);start=0;sent=0;
while(!done)begin
 rng=rng*32'd1664525+32'd1013904223;ready=rng[3:0]!=0;bv=sent<2764854 && rng[7:4]!=0;data=rng[23:16];
 @(posedge clk);
 if(bv && br)sent=sent+1;
 if(pv && ready)pixels=pixels+1;
 @(negedge clk);
 if(sent>2764900)$fatal(1,"720p source did not complete");
end
if(pixels!=921600 || sent!=2764854)$fatal(1,"720p full source extent differs pixels=%d bytes=%d",pixels,sent);
$display("PASS %d exact BMP handshake/done cycles; 921600 valid RGB888 pixels; %d stable stalled cycles; arbitrary 13/32-bit geometry/offsets, start/cancel and short resets; invalid RGB bus unqualified",checks,stalls);$finish;
end endmodule
''',encoding='utf-8')
simulate(w/'simulation','tb',[ref,b/'rtl/image/bmp_pixel_unpack.v',tb])
