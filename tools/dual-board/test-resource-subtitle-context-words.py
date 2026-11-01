"""Check independent full64 capture banks under simultaneous pending/found writes."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--wide-current',action='store_true');a=p.parse_args()
b=a.candidate.resolve();w=b.parent/'subtitle-context-words';w.mkdir(parents=True,exist_ok=True)
tb=w/'tb.v';text='''module tb;
reg clk=0,rst=1,ea=0,eb=0;always #5 clk=~clk;
reg [63:0] da=0,db=0,expected_a,expected_b;reg va=0,vb=0;
wire [63:0] qa,qb;integer i,checks=0,collisions=0;
resource_subtitle_found_hold a(.clk(clk),.write(ea && !rst),.din(da),.q(qa));
resource_subtitle_found_hold b(.clk(clk),.write(eb && !rst),.din(db),.q(qb));
always @(posedge clk)begin
 if(!rst && ea)begin expected_a<=da;va<=1;end
 if(!rst && eb)begin expected_b<=db;vb<=1;end
 if(!rst && ea && eb)collisions=collisions+1;
end
always @(posedge clk or negedge clk)begin #1;
 if(va && qa!==expected_a)$fatal(1,"full64 found context changed outside its write");
 if(vb && qb!==expected_b)$fatal(1,"full64 pending context changed outside its write");
 checks=checks+1;
end
initial begin
repeat(5)@(negedge clk);#1;rst=0;
for(i=0;i<30000;i=i+1)begin
 @(negedge clk);#2;ea=$random;eb=$random;da={$random,$random};db={$random,$random};
 if(i%127==0)begin da=64'hffffffff00000000;db=64'h00000000ffffffff;end
 if(i%251==0)begin da=64'h8000000080000000;db=64'hffffffffffffffff;end
 if(i%71==13)begin rst=1;#1;rst=0;end
end
repeat(5)@(negedge clk);
if(collisions<1000)$fatal(1,"missing concurrent write coverage");
$display("PASS %0d full64 independent context edge/hold checks, %0d simultaneous found/pending captures and short reset/write collisions",checks,collisions);$finish;
end endmodule
'''
if a.wide_current:
 text=text.replace('integer i,checks=0,collisions=0;', '''integer i,checks=0,collisions=0;
reg ec=0,vc=0;reg [95:0] dc=0,expected_c;wire [95:0] qc;
resource_subtitle_found_hold #(.WIDTH(96)) c(.clk(clk),.write(ec && !rst),.din(dc),.q(qc));
always @(posedge clk)if(!rst && ec)begin expected_c<=dc;vc<=1;end
always @(posedge clk or negedge clk)begin #1;
 if(vc && qc!==expected_c)$fatal(1,"full96 current image context changed outside its write");
end''')
 text=text.replace('da={$random,$random};db={$random,$random};',
                   'da={$random,$random};db={$random,$random};dc={$random,$random,$random};ec=$random;')
 text=text.replace('full64 independent context edge/hold checks','full64/full96 independent context edge/hold checks')
tb.write_text(text,encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[b/'rtl/ui/sd_subtitle_controller.v',tb],
  includes=[b/'rtl',b/'rtl/ui',b/'rtl/pkg'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
