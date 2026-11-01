"""Package paired CLOCK_TRIAL bits, source snapshots and verifiable evidence."""
import argparse
import hashlib
import importlib.util
import json
import re
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("clock_reports", Path(__file__).with_name("clock-build-report.py"))
reports = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reports)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--media", required=True)
    parser.add_argument("--render", required=True)
    parser.add_argument("--release", default="release_clock_trial")
    args = parser.parse_args()
    for tag in (args.media, args.render, args.release):
        if not re.fullmatch(r"[a-z0-9_]+", tag):
            raise SystemExit("Invalid run/release tag")
    output = ROOT / "build/clock-v1" / args.release
    if output.exists():
        raise SystemExit("Release directory exists; choose another release tag")
    regression_path = ROOT / "build/clock-v1/regression.json"
    regression = json.loads(regression_path.read_text(encoding="utf-8"))
    if not regression["full_regression"]:
        raise SystemExit("Full regression completion is required")
    for name, wanted in regression["evidence"].items():
        if digest(ROOT / name) != wanted:
            raise SystemExit("Evidence changed: " + name)
    data = {board: reports.board_report(board, getattr(args, board)) for board in ("media", "render")}
    for board, result in data.items():
        if not result["trial_timing_eligible"] or any(result["hard_block_delta"].values()):
            raise SystemExit(board + ": requires legal resources, zero hold violations and unchanged hard block counts")
        if regression["inputs"][board] != result["inputs"]:
            raise SystemExit(board + ": regression input fingerprint differs")
    output.mkdir(parents=True)
    for board, result in data.items():
        project = "MultimediaSystem_" + board
        run = ROOT / board / "Runs" / ("phy_" + result["run_tag"])
        bit = run / (project + "_CLOCK_TRIAL.bit")
        copy(bit, output / (board + "_CLOCK_TRIAL.bit"))
        result["bit_sha256"] = digest(bit)
        for name in result["inputs"]:
            copy(ROOT / board / name, output / "source" / board / name)
        for name in ("README.md", project + ".al", "build/modules.json"):
            copy(ROOT / board / name, output / "source" / board / name)
        for folder in ("sim", "doc", "diag"):
            shutil.copytree(ROOT / board / folder, output / "source" / board / folder, ignore=shutil.ignore_patterns("__pycache__"))
        for name in ("inputs.json", "settings.cfg", "final.qor", "route.qor", "console.txt",
                     project + "_phy.area", project + "_phy.ts", project + "_pr.timing",
                     "generate-clock-trial.tcl", "clock-trial-bitgen.txt"):
            copy(run / name, output / "reports" / board / name)
        if (run / "qualification.json").exists():
            copy(run / "qualification.json", output / "reports" / board / "qualification.json")
    shutil.copytree(ROOT / "tools", output / "source/tools", ignore=shutil.ignore_patterns("__pycache__"))
    # Standard audit checks the unchanged original single-board inputs too.
    baseline_path = ROOT / "doc/dual-board/baseline.sha256.json"
    baseline = json.loads(baseline_path.read_text())
    for name, wanted in baseline.items():
        if digest(ROOT / name) != wanted:
            raise SystemExit("Original single-board baseline changed: " + name)
        copy(ROOT / name, output / "source" / name)
    copy(baseline_path, output / "source/doc/dual-board/baseline.sha256.json")
    for name in ("README.md", "README-dual-board.md", "doc/dual-board/protocol-v1.md",
                 "doc/dual-board/calendar-clock-2026-10-14.md"):
        copy(ROOT / name, output / "source" / name)
    copy(regression_path, output / "evidence/regression.json")
    for name in regression["evidence"]:
        copy(ROOT / name, output / "evidence" / name)
    shutil.copytree(ROOT / "build/clock-v1/frames", output / "frames")
    shutil.copytree(ROOT / "build/clock-v1/preview", output / "preview")
    manifest = {"artifact_type": "paired_calendar_clock_hardware_trial", "protocol": "1.9",
                "hardware_acceptance": "pending", "full_regression": True,
                "test_count": regression["test_count"], "boards": data,
                "source_revision": "calendar_clock_v4",
                "scope": "2000-2099, powered-only, all-screen clock, local matrix editor"}
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output / "README.md").write_text(
        "# 日期时钟双板试板包\n\n"
        "配套下载 media_CLOCK_TRIAL.bit 和 render_CLOCK_TRIAL.bit，协议 1.9。\n\n"
        "上电 2000-01-01 00:00:00；设置第七项 CLOCK，2/8 选字段，4/6 调整，APPLY 上按 5 生效；# 返回，KEY3 关闭。\n"
        "支持 2000–2099 年，通电计时；所有画面左上角显示。断电或 render 系统复位后重新设置。\n\n"
        "本包不是正式时序签核版本。两板最终资源、Setup/Hold 结果和输入指纹见 manifest.json 与 reports/。"
        "要求 Hold 零违例；Setup 的实际违例明确保留。实板仍待 20 次进入/退出及 30 分钟混合播放验收。\n\n"
        "完整说明见 source/doc/dual-board/calendar-clock-2026-10-14.md；构建参数见 reports/*/settings.cfg。"
        "既有 GPIO 应急包可整体回退，不要混用 1.8/1.9 两板 bit。\n", encoding="utf-8")
    sums = [digest(p) + "  " + p.relative_to(output).as_posix() for p in sorted(output.rglob("*")) if p.is_file()]
    (output / "SHA256SUMS.txt").write_text("\n".join(sums) + "\n", encoding="utf-8")
    archive = output.with_suffix(".zip")
    with zipfile.ZipFile(archive, "x", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(output.rglob("*")):
            if p.is_file():
                z.write(p, output.name + "/" + p.relative_to(output).as_posix())
    archive.with_suffix(".zip.sha256").write_text(digest(archive) + "  " + archive.name + "\n", encoding="utf-8")
    print("PACKAGED", archive, "SHA256", digest(archive))
