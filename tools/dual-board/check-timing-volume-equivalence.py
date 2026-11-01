"""Compare pipelined volume gain against a Git reference, sample for sample."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-root", type=Path, default=ROOT / "render")
parser.add_argument("--reference-revision", default="HEAD")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
source = args.source_root.resolve() / "rtl/audio/audio_volume_gain.v"
reference = subprocess.check_output(
    ["git", "show", f"{args.reference_revision}:render/rtl/audio/audio_volume_gain.v"], cwd=ROOT)
(out / "reference.v").write_bytes(reference.replace(b"module audio_volume_gain(", b"module audio_volume_gain_reference("))
(out / "tb.v").write_text(r"""
`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,v=0,u=0;reg [23:0] l=0,r=0;reg [4:0] level=20;
wire cv,rv;wire [23:0] cl,cr,rl,rr;
reg ev;reg [23:0] el,er;
integer i,checks=0;
always #5 clk=~clk;
audio_volume_gain candidate(.clk(clk),.rst(rst),.level(level),.unity(u),.in_valid(v),
 .in_left(l),.in_right(r),.out_valid(cv),.out_left(cl),.out_right(cr));
audio_volume_gain_reference reference(.clk(clk),.rst(rst),.level(level),.unity(u),.in_valid(v),
 .in_left(l),.in_right(r),.out_valid(rv),.out_left(rl),.out_right(rr));
always @(posedge clk) begin
 ev=rv;el=rl;er=rr;
 #1;
 if(!rst) begin
  if(cv!==ev) $fatal(1,"volume valid misaligned");
  if(cv) begin
   if(cl!==el || cr!==er) $fatal(1,"volume sample changed %h/%h expected %h/%h",cl,cr,el,er);
   checks=checks+1;
  end
 end
end
initial begin
 repeat(4) @(negedge clk);rst=0;
 for(i=0;i<200000;i=i+1) begin
  @(negedge clk);v=$random;u=$random;l=$random;r=$random;level=i%26;
  if(i%10000==9999) begin rst=1;repeat(2) @(negedge clk);rst=0;end
 end
 @(negedge clk);v=0;repeat(8) @(negedge clk);
 $display("*** PASS *** exact volume equivalence: %0d stereo samples, level/unity changes every clock, stalls, invalid levels, reset",checks);
 $finish;
end
endmodule
""", encoding="utf-8")
ms = Path("D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem")
with tempfile.TemporaryDirectory(prefix="timing_volume_equivalence_") as work:
    commands = [[ms / "vlib.exe", "work"],
                [ms / "vlog.exe", source, out / "reference.v", out / "tb.v"],
                [ms / "vsim.exe", "-c", "tb", "-do", "run -all; quit -f"]]
    for index, command in enumerate(commands):
        result = subprocess.run([str(x) for x in command], cwd=work, capture_output=True, timeout=180)
        log = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        (out / f"{index}.log").write_text(log, encoding="utf-8")
        if result.returncode or "** Error" in log or "** Fatal" in log:
            raise SystemExit(log)
    if "*** PASS ***" not in log:
        raise SystemExit(log)
(out / "result.json").write_text(json.dumps(dict(
    source=str(source), source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
    reference_sha256=hashlib.sha256(reference).hexdigest(), passed=True,
    cycles=200000, added_latency_cycles=1), indent=2), encoding="utf-8")
print(next(line for line in log.splitlines() if "*** PASS ***" in line))
