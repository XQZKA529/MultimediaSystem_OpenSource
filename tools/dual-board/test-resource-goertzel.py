from pathlib import Path
from resource_sim import simulate
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'build/resource-v1'
import argparse
parser=argparse.ArgumentParser();parser.add_argument('--candidate',type=Path,default=OUT/'render_goertzel/render');args=parser.parse_args()
cand=args.candidate.resolve();base=OUT/'base/render';work=OUT/(cand.parent.name+'-goertzel-equivalence');work.mkdir(parents=True,exist_ok=True)
ref=work/'reference.v';ref.write_text((base/'rtl/fft/audio_fft_osd.v').read_text(encoding='utf-8-sig').replace('module audio_goertzel_osd #(', 'module reference_goertzel #('),encoding='utf-8')
tb=work/'tb_goertzel_equivalence.v';tb.write_text('''module tb_goertzel_equivalence;
reg clk=0;always #5 clk=~clk;
reg rst=1,vs=0,pcm_valid=0,play_run=0,paused=0,restart=0;
reg [23:0] l=0,r=0;wire [59:0] actual,expected;
audio_goertzel_osd dut(.clk(clk),.rst(rst),.vs(vs),.pcm_valid(pcm_valid),.pcm_left(l),.pcm_right(r),.play_run(play_run),.paused(paused),.stream_restart(restart),.heights(actual));
reference_goertzel ref(.clk(clk),.rst(rst),.vs(vs),.pcm_valid(pcm_valid),.pcm_left(l),.pcm_right(r),.play_run(play_run),.paused(paused),.stream_restart(restart),.heights(expected));
integer n,checks=0;
always @(posedge clk) begin #1;if(!rst && actual!==expected) $fatal(1,"height mismatch %d %h %h",checks,actual,expected);checks=checks+1;end
initial begin
 repeat(12) @(negedge clk);rst=0;
 repeat(120) @(negedge clk);play_run=1;
 for(n=0;n<120000;n=n+1) begin
  @(negedge clk);pcm_valid=n%128==0;l=$random;r=$random;vs=n%20000==0;
  if(n==43000) paused=1;if(n==45000) paused=0;
  restart=n==65000;
  if(n==85000) play_run=0;if(n==86000) play_run=1;
  if(n==105000) rst=1;if(n==105012) begin rst=0;play_run=0;end
  if(n==105150) play_run=1;
 end
 $display("PASS %d native state-RAM height cycles; restart/pause/stop/reset/random stereo",checks);$finish;
end endmodule
''')
simulate(work/'native','tb_goertzel_equivalence',[ref,cand/'rtl/fft/audio_fft_osd.v',tb],includes=[base/'rtl/fft',base/'rtl',base/'rtl/clock'],native=True)
