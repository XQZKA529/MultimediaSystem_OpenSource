"""Package a focused receiver timing trial without relabeling the failed parent."""
import argparse
import hashlib
import importlib.util
import json
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("clock_reports", Path(__file__).with_name("clock-build-report.py"))
reports = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reports)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--render", required=True)
    args = parser.parse_args()
    work = ROOT / "build/clock-rx-timing-fix"
    parent = ROOT / "build/clock-v1/release_clock_trial"
    out = work / "release_clock_rx_timing_trial"
    if out.exists():
        raise SystemExit("Release exists; preserve it and choose a new candidate directory")
    logs = [work / name for name in ("regression-fast.txt", "metadata-boundaries.txt", "regression-full-image.txt")]
    if sum(p.read_text(encoding="utf-8").count("*** PASS ***") for p in logs) != 8:
        raise SystemExit("Requires eight passing targeted executions")
    if "PASS targeted receive timing regression" not in logs[-1].read_text(encoding="utf-8"):
        raise SystemExit("Image/audio/subtitle regression and audit must complete")
    boards = {"media": reports.board_report("media", "clock_v1_medium3"),
              "render": reports.board_report("render", args.render)}
    for board, result in boards.items():
        if not result["trial_timing_eligible"] or any(result["hard_block_delta"].values()):
            raise SystemExit(board + ": requires legal resources, zero hold violations and no added hard blocks")
    old = json.loads((parent / "manifest.json").read_text(encoding="utf-8"))
    production_delta = []
    for board, result in boards.items():
        for name, value in result["inputs"].items():
            if old["boards"][board]["inputs"].get(name) != value:
                production_delta.append(board + "/" + name)
    if production_delta != ["render/rtl/seam/seam_render.v"]:
        raise SystemExit("Unexpected production delta: " + repr(production_delta))
    out.mkdir(parents=True)
    shutil.copytree(parent / "source", out / "source")
    for board, result in boards.items():
        run = ROOT / board / "Runs" / ("phy_" + result["run_tag"])
        project = "MultimediaSystem_" + board
        bit = run / (project + "_CLOCK_TRIAL.bit")
        if board == "media" and sha(bit) != old["boards"][board]["bit_sha256"]:
            raise SystemExit("Media must remain byte-identical to the paired clock trial")
        result["bit_sha256"] = sha(bit)
        copy(bit, out / (board + "_CLOCK_RX_TIMING_TRIAL.bit"))
        for name, value in result["inputs"].items():
            copy(ROOT / board / name, out / "source" / board / name)
            if sha(out / "source" / board / name) != value:
                raise SystemExit("Source copy fingerprint mismatch")
        for p in run.iterdir():
            if p.is_file() and (p.suffix in (".timing", ".ts", ".area", ".qor", ".cfg", ".json")
                               or p.name in ("console.txt", "clock-trial-bitgen.txt", "generate-clock-trial.tcl")):
                copy(p, out / "reports" / board / p.name)
    for name in ("README.md", "README-dual-board.md", "render/README.md", "media/README.md",
                 "render/sim/tb_ui_snapshot.v", "render/MultimediaSystem_render.al",
                 "doc/dual-board/calendar-clock-2026-10-14.md", "doc/dual-board/hardware-acceptance.md",
                 "doc/dual-board/clock-rx-timing-fix-2026-10-14.md", "tools/dual-board/package-clock-rx-fix.py"):
        copy(ROOT / name, out / "source" / name)
    for p in logs:
        copy(p, out / "evidence" / p.name)
    for p in (work / "evidence").glob("*.txt"):
        copy(p, out / "evidence/tests" / p.name)
    for name in ("emergency-system.txt", "text-osd-menu-system.txt", "system-691200_bmp_scale_720p.txt",
                 "audio-system-0-mono0_bmp_scale.txt", "sd-subtitle-system_no_frames.txt"):
        copy(ROOT / "doc/dual-board/evidence" / name, out / "evidence/tests" / name)
    copy(work / "seam_render.before.v", out / "evidence/seam_render.before.v")
    copy(work / "candidate-comparison.json", out / "evidence/candidate-comparison.json")
    copy(parent / "manifest.json", out / "evidence/failed-parent-manifest.json")
    copy(ROOT / "build/clock-v1/release_clock_trial.hardware-status.json", out / "evidence/failed-parent-hardware-status.json")
    manifest = {"artifact_type": "paired_clock_receive_timing_hardware_trial", "protocol": "1.9",
                "hardware_acceptance": "pending", "cause_confirmed": False,
                "full_regression_rerun": False, "targeted_test_count": 8,
                "parent_full_simulation_test_count": 124, "parent_hardware_image_acceptance": "failed",
                "production_delta": production_delta, "media_bit_reused": True, "boards": boards}
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "README.md").write_text(
        "# CLOCK 图片接收时序恢复试板\n\n"
        "仅修改 render 元数据预检查，提前寄存 UI/应急状态包的长度和偏移判定。\n"
        "原 CLOCK_TRIAL 两板已配套下载时，只需更新 render_CLOCK_RX_TIMING_TRIAL.bit。\n"
        "若目前使用原 GPIO 1.8 包，则两板一起下载本包；media bit 与此前 CLOCK_TRIAL 完全相同。\n\n"
        "本次是定位试板，根因及图片恢复尚未实板确认，正式签核状态见 manifest.json。"
        "Hold 零违例；Setup 实际违例保留，正式检查不放宽。\n"
        "基线曾通过 124 次仿真但实板图片失败；本次完成 8 次针对性检查，没有重复完整回归。\n"
        "冷启动观察首张图片，连续切图/设置/时钟/应急操作，再运行 30 分钟混合播放。\n"
        "详细修改和实际时序见 source/doc/dual-board/clock-rx-timing-fix-2026-10-14.md。\n", encoding="utf-8")
    sums = [sha(p) + "  " + p.relative_to(out).as_posix() for p in sorted(out.rglob("*")) if p.is_file()]
    (out / "SHA256SUMS.txt").write_text("\n".join(sums) + "\n", encoding="utf-8")
    archive = out.with_suffix(".zip")
    with zipfile.ZipFile(archive, "x", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(out.rglob("*")):
            if p.is_file():
                z.write(p, out.name + "/" + p.relative_to(out).as_posix())
    archive.with_suffix(".zip.sha256").write_text(sha(archive) + "  " + archive.name + "\n", encoding="utf-8")
    print("PACKAGED", archive, "SHA256", sha(archive))
