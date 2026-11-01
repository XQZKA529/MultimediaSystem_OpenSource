"""Compare both MAC byte streams against a Git revision using the link regression.

Both simulations use identical clocks, stimulus and packet loss/corruption.
Byte timestamps must also match, so this checks wire contents and throughput.
Only temporary simulation files and the requested evidence directory are written.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--board", choices=["media", "render"], required=True)
    parser.add_argument("--reference-revision", required=True)
    parser.add_argument("--source-root", type=Path,
                        help="Candidate board directory; defaults to the workspace board")
    parser.add_argument("--modelsim-bin", type=Path, default=Path(
        "D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem"))
    parser.add_argument("--evidence-dir", type=Path,
                        default=Path("build/slice-wire-equivalence"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    revision = subprocess.check_output(
        ["git", "rev-parse", "--verify", args.reference_revision + "^{commit}"],
        cwd=root, text=True).strip()
    candidate = (args.source_root or root / args.board).resolve()
    evidence = args.evidence_dir.resolve() / args.board
    evidence.mkdir(parents=True, exist_ok=True)
    names = ["rtl/link/db_packet_ram.v", "rtl/link/db_async_fifo.v",
             "rtl/link/db_mac_rx.v", "rtl/link/db_link.v",
             "rtl/link/db_crc.vh", "rtl/pkg/board_link.vh"]
    bench = (root / args.board / "sim/tb_link.v").read_text(encoding="utf-8")
    monitor = """
module wire_equivalence_capture;
integer stream0,stream1;
initial begin stream0=$fopen("wire0.txt","w");stream1=$fopen("wire1.txt","w");end
always @(posedge tb_link.t0) if(tb_link.mv0)
    $fwrite(stream0,"%0t %02x\\n",$time,tb_link.md0);
always @(posedge tb_link.t1) if(tb_link.mv1)
    $fwrite(stream1,"%0t %02x\\n",$time,tb_link.md1);
endmodule
"""
    traces = {}
    fingerprints = {}
    with tempfile.TemporaryDirectory(prefix="slice_link_equivalence_") as temp:
        for version in ["reference", "candidate"]:
            work = Path(temp) / version
            work.mkdir()
            hashes = {}
            for name in names:
                data = (subprocess.check_output(
                    ["git", "show", f"{revision}:{args.board}/{name}"], cwd=root)
                    if version == "reference" else (candidate / name).read_bytes())
                target = work / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                hashes[name] = hashlib.sha256(data).hexdigest()
            fingerprints[version] = hashes
            (work / "bench.v").write_text(bench + monitor, encoding="utf-8")
            commands = [
                [str(args.modelsim_bin / "vlib.exe"), "work"],
                [str(args.modelsim_bin / "vlog.exe"), "+define+DB_BEHAVIORAL_RAM",
                 "+incdir+rtl", "+incdir+rtl/pkg", "+incdir+rtl/link",
                 *[name for name in names if name.endswith(".v")], "bench.v"],
                [str(args.modelsim_bin / "vsim.exe"), "-c", "-do", "run -all; quit -f",
                 "tb_link", "wire_equivalence_capture"],
            ]
            for stage, command in zip(["vlib", "compile", "simulate"], commands):
                result = subprocess.run(command, cwd=work, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, timeout=180)
                log = result.stdout.decode("utf-8", errors="replace")
                (evidence / f"{version}-{stage}.txt").write_text(log, encoding="utf-8")
                if result.returncode or (stage == "simulate" and "*** PASS ***" not in log):
                    raise SystemExit(f"{version} {stage} failed; inspect {evidence}")
            traces[version] = [(work / f"wire{n}.txt").read_bytes() for n in range(2)]
    for n, (old, new) in enumerate(zip(traces["reference"], traces["candidate"])):
        (evidence / f"reference-wire{n}.txt").write_bytes(old)
        (evidence / f"candidate-wire{n}.txt").write_bytes(new)
        if not old or old != new:
            raise SystemExit(f"MAC stream {n} differs from {revision}; inspect {evidence}")
    result = {"board": args.board, "reference_revision": revision,
              "result": "PASS", "source_sha256": fingerprints,
              "streams": [{"bytes": len(trace.splitlines()),
                           "sha256": hashlib.sha256(trace).hexdigest()}
                          for trace in traces["candidate"]]}
    (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result["streams"]), "PASS MAC bytes and timestamps")


if __name__ == "__main__":
    main()
