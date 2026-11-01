"""Compare the production audio input register with the previous PCM path."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
out = root / "build/timing-closure-20261022/audio-pipeline"
out.mkdir(parents=True, exist_ok=True)
core = (root / "render/rtl/render_core.v").read_text(encoding="utf-8")
block = core[core.index("    wire audio_volume_valid;"):core.index("    // Separate glyph coverage")]
bench = r"""
`timescale 1ns/1ps
module tb_timing_audio_pipeline;
 reg video_clk=0,rst_video=1,audio_valid=0,em_mute=0,em_audio_ok=0;
 reg [23:0] audio_left=0,audio_right=0;
 reg [4:0] volume_video=20;
 reg [1:0] em_voice_sync=0,em_active_sync=0;
 always #5 video_clk=~video_clk;
 __BLOCK__
 wire ref_valid;wire [23:0] ref_left,ref_right;
 audio_volume_gain reference(.clk(video_clk),.rst(rst_video),.level(volume_video),
   .unity(em_voice_sync[1] && em_active_sync[1] && em_audio_ok),
   .in_valid(audio_valid),.in_left(em_mute ? 24'd0:audio_left),.in_right(em_mute ? 24'd0:audio_right),
   .out_valid(ref_valid),.out_left(ref_left),.out_right(ref_right));
 reg expected_valid;reg [23:0] expected_left,expected_right;
 integer i,checks=0;
 always @(posedge video_clk)begin
  expected_valid=ref_valid;expected_left=ref_left;expected_right=ref_right;
  #1;
  if(!rst_video)begin
   if(audio_volume_valid!==expected_valid)$fatal(1,"PCM valid misalignment");
   if(expected_valid)begin
    if(audio_volume_left!==expected_left || audio_volume_right!==expected_right)
     $fatal(1,"PCM sample changed: %h/%h expected %h/%h",audio_volume_left,audio_volume_right,expected_left,expected_right);
    checks=checks+1;
   end
  end
 end
 initial begin
  repeat(4)@(negedge video_clk);rst_video=0;
  for(i=0;i<100000;i=i+1)begin
   @(negedge video_clk);
   audio_valid=$random;audio_left=$random;audio_right=$random;
   em_mute=$random;em_audio_ok=$random;em_voice_sync=$random;em_active_sync=$random;
   volume_video=i%21;
   if(i==50000)begin rst_video=1;@(negedge video_clk);rst_video=0;end
  end
  @(negedge video_clk);audio_valid=0;repeat(6)@(negedge video_clk);
  $display("*** PASS *** production audio pipeline: %0d exact stereo samples with mute/unity/level changes, stalls and reset",checks);
  $finish;
 end
endmodule
""".replace("__BLOCK__", block)
(out / "tb_timing_audio_pipeline.v").write_text(bench, encoding="utf-8")
ms = Path(os.environ.get("MODELSIM_BIN", "D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem"))
with tempfile.TemporaryDirectory(prefix="timing_audio_") as work:
    commands = [
        [str(ms / "vlib.exe"), "work"],
        [str(ms / "vlog.exe"), str(root / "render/rtl/audio/audio_volume_gain.v"), str(out / "tb_timing_audio_pipeline.v")],
        [str(ms / "vsim.exe"), "-c", "tb_timing_audio_pipeline", "-do", "run -all; quit -f"],
    ]
    for index, command in enumerate(commands):
        result = subprocess.run(command, cwd=work, capture_output=True, text=True)
        output = result.stdout + result.stderr
        (out / f"{index}.log").write_text(output, encoding="utf-8")
        if result.returncode or "** Error" in output or "** Fatal" in output:
            raise SystemExit(output)
    if "*** PASS ***" not in output:
        raise SystemExit(output)
    print(next(line for line in output.splitlines() if "*** PASS ***" in line))
