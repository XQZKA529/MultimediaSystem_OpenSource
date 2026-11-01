"""Exercise the actual render_core grid/mixer bundle at one pixel per clock.

Extracting the inline production block keeps the test attached to the design;
the reference independently evaluates the former integer geometry/blend math.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/timing-closure-20261022/pixel-pipeline"
OUT.mkdir(parents=True, exist_ok=True)
core = (ROOT / "render/rtl/render_core.v").read_text(encoding="utf-8")
delay = core[core.index("    function [3:0] grid_delay;"):core.index("    wire [5:0] pixel_cell_id=")]
block = core[core.index("    wire [5:0] pixel_cell_id="):core.index("    wire [1:0] trans_disp_idx;")]
bench = r"""
`timescale 1ns/1ps
module tb_timing_pixel_pipeline;
 reg video_clk=0,rst_video=1;
 always #5 video_clk=~video_clk;
 reg [2:0] pixel_y_cell=0,pixel_x_cell=0;
 reg [7:0] pixel_x_local=0;
 reg [6:0] pixel_y_local=0;
 reg [4:0] mix_step=0;
 reg [8:0] mix_alpha=0;
 reg [1:0] active_transition_mode=0;
 reg [23:0] rgb_raw=0,rgb_raw1=0;
 reg display_valid=0,old_pixel_valid=0,new_pixel_valid=0,mix_lane1_en=0;
 reg hs_pix=0,vs_pix=0,de_pix=0;
 wire [23:0] rgb_mixed;
 wire mix_pair_ok,mix_fail;
 __DELAY__
 wire [3:0] pixel_delay_precomputed=grid_delay({pixel_y_cell,pixel_x_cell});
 __BLOCK__
 integer expected_rgb[0:4];
 reg [4:0] expected_valid=0,expected_hs=0,expected_vs=0,expected_de=0,expected_mix=0;
 integer i,j,cycles=0,checks=0,cc,step,xp,yp,xx,yy,el,lo,hi,yl,yh,aa,mode;
 integer xs[0:9],ys[0:9];
 function [7:0] blend_ref;
  input integer o,n,a;
  integer v;
  begin v=(o*256+a*(n-o)+128)>>>8;
   blend_ref=v<0 ? 0:v>255 ? 255:v;
  end
 endfunction
 always @(posedge video_clk) begin
  if(rst_video) begin
   cycles=0;expected_valid=0;expected_hs=0;expected_vs=0;expected_de=0;expected_mix=0;
   for(i=0;i<5;i=i+1) expected_rgb[i]=0;
  end else begin
   for(i=4;i>0;i=i-1) expected_rgb[i]=expected_rgb[i-1];
   el=mix_step-grid_delay({pixel_y_cell,pixel_x_cell});
   if(el<0)el=0;if(el>16)el=16;
   lo=5*el;hi=160-5*el;yl=(15*el+2)/4;yh=120-yl;
   aa=active_transition_mode==1 ? 0 : active_transition_mode==2 ?
     ((pixel_x_local>=lo && pixel_x_local<hi && pixel_y_local>=yl && pixel_y_local<yh) ? el*16:256):mix_alpha;
   if(!mix_lane1_en)aa=0;
   expected_rgb[0]={blend_ref(display_valid ? rgb_raw[23:16]:0,rgb_raw1[23:16],aa),
                    blend_ref(display_valid ? rgb_raw[15:8]:0,rgb_raw1[15:8],aa),
                    blend_ref(display_valid ? rgb_raw[7:0]:0,rgb_raw1[7:0],aa)};
   expected_valid={expected_valid[3:0],(!display_valid || old_pixel_valid) && (!mix_lane1_en || new_pixel_valid)};
   expected_hs={expected_hs[3:0],hs_pix};expected_vs={expected_vs[3:0],vs_pix};
   expected_de={expected_de[3:0],de_pix};expected_mix={expected_mix[3:0],mix_lane1_en};
   cycles=cycles+1;
   #1;
   if(cycles>=5) begin
    if(rgb_mixed!==expected_rgb[4][23:0] || mix_pair_ok!==expected_valid[4] ||
       hs_mix!==expected_hs[4] || vs_mix!==expected_vs[4] || de_mix!==expected_de[4] ||
       mix_fail!==(expected_mix[4] && !expected_valid[4] && expected_de[4]))
      $fatal(1,"pipeline mismatch cycle=%0d rgb=%h expected=%h",cycles,rgb_mixed,expected_rgb[4]);
    checks=checks+1;
   end
  end
 end
 task drive;
 begin
  @(negedge video_clk);
  rgb_raw=$random;rgb_raw1=$random;display_valid=$random;old_pixel_valid=$random;new_pixel_valid=$random;
  mix_lane1_en=$random;hs_pix=$random;vs_pix=$random;de_pix=$random;
 end
 endtask
 initial begin
  repeat(3) @(negedge video_clk);rst_video=0;
  // Sweep every cell, frame step, and both sides of each shrinking boundary.
  for(step=0;step<=30;step=step+1) for(cc=0;cc<48;cc=cc+1) begin
   el=step-grid_delay(cc);if(el<0)el=0;if(el>16)el=16;
   xs[0]=0;xs[1]=1;xs[2]=79;xs[3]=80;xs[4]=158;xs[5]=159;
   xs[6]=5*el-1;xs[7]=5*el;xs[8]=159-5*el;xs[9]=160-5*el;
   ys[0]=0;ys[1]=1;ys[2]=59;ys[3]=60;ys[4]=118;ys[5]=119;
   ys[6]=(15*el+2)/4-1;ys[7]=(15*el+2)/4;ys[8]=119-(15*el+2)/4;ys[9]=120-(15*el+2)/4;
   for(xp=0;xp<10;xp=xp+1) for(yp=0;yp<10;yp=yp+1) begin
    drive;pixel_y_cell=cc/8;pixel_x_cell=cc%8;mix_step=step;active_transition_mode=2;
    pixel_x_local=xs[xp];pixel_y_local=ys[yp];
   end
  end
  for(j=0;j<30000;j=j+1) begin
   drive;active_transition_mode=$random;mix_alpha=j%257;mix_step=j%31;
   pixel_x_local=$random;pixel_y_local=$random;pixel_y_cell=j%6;pixel_x_cell=j%8;
   if(j==15000)begin rst_video=1;@(negedge video_clk);rst_video=0;end
  end
  repeat(6)drive;
  $display("*** PASS *** production grid/mixer streaming: %0d RGB/valid/HS/VS/DE/fault checks",checks);
  $finish;
 end
endmodule
""".replace("__DELAY__", delay).replace("__BLOCK__", block)
(OUT / "tb_timing_pixel_pipeline.v").write_text(bench, encoding="utf-8")
ms = Path(os.environ.get("MODELSIM_BIN", "D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem"))
with tempfile.TemporaryDirectory(prefix="timing_pixel_") as work:
    commands = [
        [str(ms / "vlib.exe"), "work"],
        [str(ms / "vlog.exe"), "-sv", str(ROOT / "render/rtl/video/pixel_mixer.v"), str(OUT / "tb_timing_pixel_pipeline.v")],
        [str(ms / "vsim.exe"), "-c", "tb_timing_pixel_pipeline", "-do", "run -all; quit -f"],
    ]
    for index, command in enumerate(commands):
        run = subprocess.run(command, cwd=work, capture_output=True, text=True)
        output = run.stdout + run.stderr
        (OUT / f"{index}.log").write_text(output, encoding="utf-8")
        if run.returncode or "** Error" in output or "** Fatal" in output:
            raise SystemExit(output)
    if "*** PASS ***" not in output:
        raise SystemExit(output)
    print(next(line for line in output.splitlines() if "*** PASS ***" in line))
