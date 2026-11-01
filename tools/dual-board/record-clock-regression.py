"""Archive successful regression evidence before restoring historical log files."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def inputs(board):
    directory = ROOT / board
    files = []
    for folder in ("rtl", "al_ip", "constr"):
        files.extend(p for p in (directory / folder).rglob("*") if p.is_file())
    files.extend(p for p in (directory / "build").iterdir() if p.is_file()
                 and (p.suffix in (".tcl", ".ps1") or p.name == "sources.txt"))
    return {p.relative_to(directory).as_posix(): sha(p) for p in sorted(files)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--full-log", type=Path, default=ROOT / "build/clock-v1/full-regression.txt")
    parser.add_argument("--resume-log", type=Path)
    parser.add_argument("--completion-log", type=Path)
    args = parser.parse_args()
    args.full_log = args.full_log.resolve()
    if args.resume_log:
        args.resume_log = args.resume_log.resolve()
    if args.completion_log:
        args.completion_log = args.completion_log.resolve()
    log = args.full_log.read_text(encoding="utf-8")
    resumed_log = args.resume_log.read_text(encoding="utf-8") if args.resume_log else ""
    completion_log = args.completion_log.read_text(encoding="utf-8") if args.completion_log else ""
    if "PASS dual-board regression/package audit" not in log and "PASS resumed dual-board regression/package audit" not in resumed_log + completion_log:
        raise SystemExit("The full regression has not completed successfully")
    # 26 emergency + 36 media + 40 render/clock + 15 system/scale runs.
    count = log.count("*** PASS ***") + resumed_log.count("*** PASS ***") + completion_log.count("*** PASS ***")
    if count != 117:
        raise SystemExit(f"Expected 117 complete regression runs, found {count}")
    folder = ROOT / "build/clock-v1"
    report = folder / "regression.json"
    if report.exists():
        raise SystemExit("Regression report already exists")
    checks = [folder / "evidence" / name for name in (
        "tb_clock_overlay_case0.txt", "tb_clock_overlay_case8.txt", "tb_clock_overlay_case9.txt",
        "tb_clock_overlay_case10.txt", "tb_ui_frame_ppm_case1.txt", "tb_ui_frame_ppm_case7.txt")]
    for p in checks:
        if not p.is_file() or "*** PASS ***" not in p.read_text():
            raise SystemExit("Missing final/extra check: " + str(p))
    final_frames_log = folder / "final-clock-frames.txt"
    if not final_frames_log.is_file() or "*** PASS ***" not in final_frames_log.read_text():
        raise SystemExit("Final frozen-RTL clock frame suite is required")
    checks.append(folder / "evidence/tb_clock_overlay.txt")
    started = args.full_log.stat().st_ctime
    evidence = []
    for directory in (ROOT / "media/build/evidence", ROOT / "render/build/evidence",
                      ROOT / "doc/dual-board/evidence", ROOT / "media/doc/evidence",
                      ROOT / "render/doc/evidence", folder / "evidence"):
        for p in directory.glob("*.txt"):
            if p.stat().st_mtime >= started - 5 and "*** PASS ***" in p.read_text(encoding="utf-8", errors="replace"):
                evidence.append(p)
    evidence = sorted(set(evidence + checks + [args.full_log, final_frames_log] + ([args.resume_log] if args.resume_log else []) + ([args.completion_log] if args.completion_log else [])))
    archived = {}
    for p in evidence:
        target = folder / "evidence/verified" / p.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, target)
        archived[target.relative_to(ROOT).as_posix()] = sha(target)
    test_inputs = {}
    for directory in (ROOT / "media/sim", ROOT / "render/sim", ROOT / "tools/dual-board"):
        for p in directory.rglob("*"):
            if p.is_file() and p.suffix in (".v", ".vh", ".ps1", ".py", ".hex", ".json"):
                test_inputs[p.relative_to(ROOT).as_posix()] = sha(p)
    result = {"full_regression": True, "full_regression_test_count": count, "extra_test_count": 7,
              "test_count": count + 7, "hardware_acceptance": "pending", "source_revision": "calendar_clock_v4",
              "recorded_utc": datetime.now(timezone.utc).isoformat(),
              "resumed_after_legacy_page_oracle_update": bool(args.resume_log),
              "resumed_after_compiler_process_exit": bool(args.completion_log),
              "inputs": {board: inputs(board) for board in ("media", "render")},
              "test_inputs": test_inputs, "evidence": archived,
              "final_delta_validation": "Full suite plus frozen final RTL frame suite (11 scenes), final editor highlight, shared-font request collision, diagnostic/link-down and UI frame checks."}
    report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("RECORDED", result["test_count"], "tests;", len(archived), "archived evidence files")
