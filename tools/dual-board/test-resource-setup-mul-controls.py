"""Every public prep output remains exact under arbitrary start/reset priority."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);a=p.parse_args();b=a.candidate.resolve();r=a.reference.resolve()
w=b.parent/'setup-mul-control-equivalence';w.mkdir(parents=True,exist_ok=True)
refs=[]
for name,old,new in [('image_scale_geometry.v','module image_scale_geometry(','module reference_geometry('),('bmp_header_parser.v','module bmp_header_parser #','module reference_header #')]:
 f=w/('reference_'+name);f.write_text((r/'rtl/image'/name).read_text(encoding='utf-8-sig').replace(old,new),encoding='utf-8');refs.append(f)
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0,rst=1,start=0,hstart=0,bv=0,finish=0;always #5 clk=~clk;
reg [12:0] sw=0,sh=0;reg [15:0] dw=0,dh=0;reg [1:0] mode=0;
reg [7:0] data=0;reg [31:0] actual_size=0;
wire [65:0] ag,eg;wire [123:0] ah,eh;
image_scale_geometry g(clk,rst,start,sw,sh,dw,dh,mode,ag[65],ag[64],ag[63:48],ag[47:32],ag[31:16],ag[15:0]);
reference_geometry rg(clk,rst,start,sw,sh,dw,dh,mode,eg[65],eg[64],eg[63:48],eg[47:32],eg[31:16],eg[15:0]);
bmp_header_parser h(clk,rst,hstart,bv,data,finish,actual_size,ah[123],ah[122],ah[121:109],ah[108:96],ah[95:64],ah[63:32],ah[31:0]);
reference_header rh(clk,rst,hstart,bv,data,finish,actual_size,eh[123],eh[122],eh[121:109],eh[108:96],eh[95:64],eh[63:32],eh[31:0]);
integer n,checks=0;reg [31:0] rng=32'h83af0741;
always @(posedge clk)begin #1;
 if(ag!==eg)$fatal(1,"geometry public prep/start/reset priority mismatch cycle %d got=%h expected=%h",checks,ag,eg);
 if(ah!==eh)$fatal(1,"BMP public prep/start/finish/reset priority mismatch cycle %d got=%h expected=%h",checks,ah,eh);
 checks=checks+1;
end
initial begin
repeat(5)@(negedge clk);rst=0;
for(n=0;n<200000;n=n+1)begin
 rng=rng*32'd1664525+32'd1013904223;
 sw=rng[12:0];sh=rng[25:13];dw=rng[31:16];dh=rng[15:0];mode=rng[6:5];
 start=n%47==0 || n%127<3;
 hstart=n%131==0 || n%101<2;bv=rng[1];data=rng[23:16];finish=n%103==61;actual_size=rng;
 if(n%1973==0)begin rst=1;#2;rst=0;end
 @(negedge clk);
end
start=0;hstart=0;finish=0;repeat(50)@(negedge clk);
$display("PASS %d exact complete geometry/BMP public cycles, changing operands while busy, multi-cycle/interrupted starts, finish/start collisions, illegal inputs and short warm resets",checks);$finish;
end endmodule
''',encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',refs+[b/'rtl/image/image_scale_geometry.v',b/'rtl/image/bmp_header_parser.v',tb],includes=[b/'rtl',b/'rtl/image'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
