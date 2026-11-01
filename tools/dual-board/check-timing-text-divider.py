"""Check all text-coordinate divisions after TD synthesis with vendor RAM models."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-root", type=Path, default=ROOT / "render")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
source = args.source_root / "rtl/ui/text_osd_overlay.v"
text = source.read_text(encoding="utf-8")
start = text.index("    reg [10:0] div12_rom")
end = text.index("    wire [3:0] row=", start)
probe = ("module probe(input clk,rst,input [11:0] dx,output [8:0] col,output [3:0] gx);\n"
         + text[start:end]
         + "assign col=div12_q[10:2];assign gx={div12_q[1:0],dx_low_a};\nendmodule\n")
(out / "probe.v").write_text(probe, encoding="utf-8")
td = Path("D:/AnLu_FPGA_environment")
ms = Path("D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem")


def run(command, name):
    process = subprocess.run([str(x) for x in command], cwd=out,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
    log = process.stdout.decode("utf-8", errors="replace")
    (out / (name + ".log")).write_text(log, encoding="utf-8")
    if process.returncode or re.search(r"\*\* (Error|Fatal)|^[A-Z]+-\d+\s+(ERROR|FATAL)\b", log, re.M):
        raise SystemExit(f"{name} failed: {out / (name + '.log')}")
    return log


if not (out / "probe.al").exists():
    (out / "create.tcl").write_text(
        "create_project -family EG4 -device EG4S20BG256 probe .\n"
        "add_files probe.v\nopen_project probe.al\ntop_module probe\nexit\n", encoding="utf-8")
    run([td / "bin/td_commands_prompt.exe", "create.tcl"], "create")
(out / "synth.tcl").write_text(
    "open_project probe.al\nimport_device eagle_s20.db -package EG4S20BG256\n"
    "elaborate -top probe\noptimize_rtl\noptimize_gate -packarea probe.area\n"
    "write_verilog probe_gate.v\nexit\n", encoding="utf-8")
run([td / "bin/td_commands_prompt.exe", "synth.tcl"], "synthesis")
(out / "tb.v").write_text(r"""
`timescale 1ns/1ps
module tb;
reg clk=0,rst=1;reg [11:0] dx=0;wire [8:0] col;wire [3:0] gx;
integer i;
always #5 clk=~clk;
probe dut(.clk(clk),.rst(rst),.dx(dx),.col(col),.gx(gx));
initial begin
  repeat(30) @(negedge clk);rst=0;
  for(i=0;i<4096;i=i+1) begin
    @(negedge clk);dx=i;
    @(posedge clk);#1;
    if(col!==i/12 || gx!==i%12)
      $fatal(1,"synthesized divider dx=%0d got col=%0d gx=%0d",i,col,gx);
  end
  $display("*** PASS *** synthesized text divider: all 4096 coordinates, quotient/remainder and one-clock alignment");
  $finish;
end
endmodule
""", encoding="utf-8")
run([ms / "vlib.exe", "work"], "library")
vendor = sorted((td / "sim_release/eg4").glob("*.v"))
run([ms / "vlog.exe", *vendor, "probe_gate.v", "tb.v"], "compile")
log = run([ms / "vsim.exe", "-c", "tb", "glbl", "-do", "run -all; quit -f"], "simulation")
if "*** PASS ***" not in log:
    raise SystemExit("No simulation PASS marker")
result = dict(source=str(source.resolve()), source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
              coordinates=4096, synthesized=True, passed=True)
(out / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
print(next(line for line in log.splitlines() if "*** PASS ***" in line))
