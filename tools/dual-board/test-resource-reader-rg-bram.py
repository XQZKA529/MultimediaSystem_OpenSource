"""Exact all-public-cycle reader oracle, random flushes and three full 720p frames."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);a=p.parse_args();b=a.candidate.resolve()
w=b.parent/'reader-rg-equivalence';w.mkdir(parents=True,exist_ok=True)
ref=w/'reference.v';ref.write_text((a.reference/'rtl/framebuffer/rgb888_word_reader.v').read_text(encoding='utf-8-sig').replace('module rgb888_word_reader (','module reference_reader ('),encoding='utf-8')
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0,rst=1,frame_start=0,hs=0,vs=0,de=0,empty=1;always #5 clk=~clk;
reg [31:0] data=0,rng=32'h1783ab42;
wire ar,er,ah,eh,av,ev,ad,ed,au,eu,ap,ep;wire [23:0] a,e;
rgb888_word_reader dut(.clk(clk),.rst(rst),.frame_start(frame_start),.hs_in(hs),.vs_in(vs),.de_in(de),.fifo_empty(empty),
 .fifo_read_en(ar),.fifo_read_data(data),.hs_out(ah),.vs_out(av),.de_out(ad),.pixel_rgb(a),.underflow_sticky(au),.pixel_valid(ap));
reference_reader ref(.clk(clk),.rst(rst),.frame_start(frame_start),.hs_in(hs),.vs_in(vs),.de_in(de),.fifo_empty(empty),
 .fifo_read_en(er),.fifo_read_data(data),.hs_out(eh),.vs_out(ev),.de_out(ed),.pixel_rgb(e),.underflow_sticky(eu),.pixel_valid(ep));
wire overlap=dut.read_pending && dut.tail_valid;
wire conflict=dut.rg_write && dut.rg_read && dut.rg_write_addr=={dut.active_bank,dut.pixel_phase};
integer checks=0,hits=0,full_hits=0,n,x,y,f;reg full=0;
always @(posedge clk or negedge clk)begin #1;if(!rst)begin
 if({ar,ah,av,ad,a,au,ap}!=={er,eh,ev,ed,e,eu,ep})$fatal(1,"reader public cycle %d RGB=%h/%h",checks,a,e);
 if(overlap || conflict)$fatal(1,"reader bank ownership/commit invariant");
 checks=checks+1;if(ap)hits=hits+1;if(full && ap && clk)full_hits=full_hits+1;
end end
initial begin
repeat(10)@(negedge clk);rst=0;
for(n=0;n<500000;n=n+1)begin
 @(negedge clk);rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
 data={$random};empty=rng[0]&&rng[5];de=rng[7]||rng[15];hs=rng[12];vs=rng[8];
 frame_start=(n%37<3) || (n%211==105);
 if(n%1009==504)begin rst=1;#2;rst=0;end
end
for(f=0;f<3;f=f+1)begin
 @(negedge clk);frame_start=1;vs=1;de=0;empty=0;repeat(3)@(negedge clk);
 frame_start=0;vs=0;repeat(16)@(negedge clk);full=1;
 for(y=0;y<720;y=y+1)begin
  de=1;for(x=0;x<1280;x=x+1)begin data={$random};@(negedge clk);end
  de=0;hs=1;@(negedge clk);hs=0;@(negedge clk);
 end
 full=0;de=0;repeat(8)@(negedge clk);
end
if(full_hits!=2764800)$fatal(1,"full pixel throughput differs %d",full_hits);
$display("PASS %d exact edge/public cycles, %d valid samples, three full 720p frames (2764800 pixels), random empty/flush/frame collisions/reset and unchanged FIFO cadence",checks,hits);$finish;
end endmodule
''',encoding='utf-8')
source=(b/'rtl/framebuffer/rgb888_word_reader.v').read_text(encoding='utf-8-sig')
if 'wire rg_prefetch_dummy=' in source:
 text=tb.read_text(encoding='utf-8')
 text=text.replace('dut.rg_write && dut.rg_read && dut.rg_write_addr=={dut.active_bank,dut.pixel_phase}',
                   "dut.rg_write && {1'b0,dut.rg_write_addr}==dut.rg_prefetch_addr")
 marker='integer checks=0'
 extra='''wire dummy_read=dut.rg_prefetch_dummy;
reg previous_dummy=0,sampled_dummy=0;
always @(posedge clk)begin
 sampled_dummy=previous_dummy;previous_dummy=dummy_read;
 #1;if(!rst && !frame_start && ap && sampled_dummy)$fatal(1,"visible pixel used dummy prefetch");
end
'''
 text=text.replace(marker,extra+marker);tb.write_text(text,encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[ref,b/'rtl/framebuffer/rgb888_word_reader.v',tb],
  defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
