"""Compare scaler handshakes and pixels every clock against a Git revision."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-revision", required=True)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--modelsim-bin", type=Path, default=Path(
        "D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem"))
    parser.add_argument("--evidence-dir", type=Path, default=Path("build/scale-equivalence"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    revision = subprocess.check_output(
        ["git", "rev-parse", "--verify", args.reference_revision + "^{commit}"],
        cwd=root, text=True).strip()
    candidate = (args.source_root or root / "media").resolve()
    evidence = args.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    name = "rtl/image/image_scale_nearest.v"
    old = subprocess.check_output(["git", "show", f"{revision}:media/{name}"], cwd=root)
    new = (candidate / name).read_bytes()
    with tempfile.TemporaryDirectory(prefix="scale_equivalence_") as temp:
        work = Path(temp)
        (work / "rtl/image").mkdir(parents=True)
        (work / "rtl/framebuffer").mkdir()
        (work / "rtl/pkg").mkdir()
        for name in ["rtl/image/image_row_store.v", "rtl/framebuffer/rgb888_word_packer.v",
                     "rtl/pkg/video_bmp_params.vh"]:
            (work / name).write_bytes((candidate / name).read_bytes())
        (work / "candidate.v").write_bytes(new)
        (work / "reference.v").write_bytes(old.replace(
            b"module image_scale_nearest #(", b"module image_scale_nearest_reference #("))
        (work / "bench.v").write_bytes((root / "media/sim/tb_scale_cycle_equivalence.v").read_bytes())
        commands = [
            ["python", str(root / "media/sim/bmp_scale_reference.py"), "--out", str(work)]
            + (["--full"] if args.full else []),
            [str(args.modelsim_bin / "vlib.exe"), "work"],
            [str(args.modelsim_bin / "vlog.exe"), "+incdir+rtl/pkg", "reference.v", "candidate.v",
             "rtl/image/image_row_store.v", "rtl/framebuffer/rgb888_word_packer.v", "bench.v"],
            [str(args.modelsim_bin / "vsim.exe"), "-c", "-do", "run -all; quit -f",
             *(["-gDST_W=1280", "-gDST_H=720"] if args.full else []),
             "tb_scale_cycle_equivalence"],
        ]
        for stage, command in zip(["fixtures", "vlib", "compile", "simulate"], commands):
            result = subprocess.run(command, cwd=work, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=1800)
            log = result.stdout.decode("utf-8", errors="replace")
            (evidence / f"{stage}.txt").write_text(log, encoding="utf-8")
            if result.returncode or (stage == "simulate" and "*** PASS ***" not in log):
                raise SystemExit(f"Scaler {stage} failed; inspect {evidence}")
    result = {"reference_revision": revision, "result": "PASS", "full": args.full,
              "reference_sha256": hashlib.sha256(old).hexdigest(),
              "candidate_sha256": hashlib.sha256(new).hexdigest()}
    (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print("PASS cycle-exact scaler handshakes, RGB and completion")


if __name__ == "__main__":
    main()
