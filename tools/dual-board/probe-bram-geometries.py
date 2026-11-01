"""Measure TD BRAM geometry mapping in isolated projects; never edits board RTL."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--td-root", type=Path, default=Path("D:/AnLu_FPGA_environment"))
parser.add_argument("--output", type=Path, default=Path("build/bram-evaluation-2026-10-09"))
parser.add_argument("--read-b-only", action="store_true",
                    help="Leave port A read unused, matching simple dual-port FIFOs/tables")
parser.add_argument("--implementations", nargs="+", choices=["9K", "32K"],
                    default=["9K", "32K"])
args = parser.parse_args()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=True)
results = []
geometries = [(32, 11), (32, 10), (32, 9), (96, 3), (72, 3),
              (64, 6), (64, 8), (8, 7), (16, 11)]
for width, aw in geometries:
    for implementation in args.implementations:
        name = f"ram_w{width}_a{aw}_{implementation.lower()}"
        run = root / name
        run.mkdir(exist_ok=True)
        folds = [f"q[{min(i+15,width-1)}:{i}]" for i in range(0, width, 16)]
        fold_a = " ^ ".join(x.replace("q[", "qa[") for x in folds)
        fold_b = " ^ ".join(x.replace("q[", "qb[") for x in folds)
        source = f'''module probe(input aclk,bclk,we,input [{aw-1}:0] a,b,
input [{width-1}:0] d,output [15:0] oa,ob);
wire [{width-1}:0] qa,qb;
EG_LOGIC_BRAM #(.DATA_WIDTH_A({width}),.DATA_WIDTH_B({width}),
.ADDR_WIDTH_A({aw}),.ADDR_WIDTH_B({aw}),
.MODE("DP"),
.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
.IMPLEMENT("{implementation}")) ram(
.clka(aclk),.cea(1'b1),.ocea(1'b1),.rsta(1'b0),.wea(we),.bea(1'b1),
.addra(a),.dia(d),.doa(qa),
.clkb(bclk),.ceb(1'b1),.oceb(1'b1),.rstb(1'b0),.web(1'b0),.beb(1'b1),
.addrb(b),.dib({width}'d0),.dob(qb));
assign oa={fold_a}; assign ob={fold_b};
endmodule
'''
        if args.read_b_only:
            source = source.replace(f"assign oa={fold_a};", "assign oa=16'd0;")
        (run / "probe.v").write_text(source, encoding="utf-8")
        if not (run / "probe.al").exists():
            # Persist the native project, then start synthesis in a fresh TD
            # process, as in the board build flow (avoids TD 6.2 macro crashes).
            (run / "create.tcl").write_text('''create_project -family EG4 -device EG4S20BG256 probe .
add_files probe.v
open_project probe.al
top_module probe
exit
''', encoding="utf-8")
            with (run / "create-console.txt").open("w", encoding="utf-8") as log:
                subprocess.run([str(args.td_root / "bin/td_commands_prompt.exe"),
                                "create.tcl"], cwd=run, stdout=log, stderr=subprocess.STDOUT,
                               check=True)
        tcl = '''open_project probe.al -noanalyze
add_files probe.v
open_project probe.al
top_module probe
open_project probe.al
import_device eagle_s20.db -package EG4S20BG256
elaborate -top probe
optimize_rtl
optimize_gate -packarea probe.area
write_verilog probe_gate.v
exit
'''
        (run / "probe.tcl").write_text(tcl, encoding="utf-8")
        with (run / "console.txt").open("w", encoding="utf-8") as log:
            proc = subprocess.run([str(args.td_root / "bin/td_commands_prompt.exe"),
                                   "probe.tcl"], cwd=run, stdout=log, stderr=subprocess.STDOUT)
        console = (run / "console.txt").read_text(encoding="utf-8", errors="replace")
        failed = bool(proc.returncode or re.search(
            r"(?m)^[A-Z]+-\d+\s+(ERROR|FATAL)\b|Oops! coredump", console))
        area_path = run / "probe.area"
        counts = {}
        if not failed:
            area = area_path.read_text(encoding="utf-8", errors="replace")
            counts = {key: int(re.search(rf"(?m)^\s*#{key}\s+(\d+)", area)[1])
                      for key in ("lut", "reg", "bram9k", "bram32k")}
        row = dict(name=name, width=width, depth=1 << aw, mode="DP",
                   topology="write-A/read-B" if args.read_b_only else "read-write-A/read-B",
                   implementation=implementation, status="failed" if failed else "mapped",
                   exit_code=proc.returncode, **counts,
                   source_sha256=hashlib.sha256((run / "probe.v").read_bytes()).hexdigest(),
                   console_sha256=hashlib.sha256((run / "console.txt").read_bytes()).hexdigest())
        if not failed:
            row["area_sha256"] = hashlib.sha256(area_path.read_bytes()).hexdigest()
        results.append(row)
        (root / "results.json").write_text(json.dumps(dict(
            scope="isolated synthesis mapping only; no timing/functional signoff",
            results=results), indent=2) + "\n", encoding="utf-8")
        print(json.dumps(row), flush=True)
if any(row["status"] != "mapped" for row in results):
    raise SystemExit("Some geometries failed; inspect results.json and per-case console.txt")
