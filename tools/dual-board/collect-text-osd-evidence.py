"""Verify current paired builds, compare keypad_release, and package Text OSD bits."""
from pathlib import Path
import argparse
from datetime import date
import hashlib
import json
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def metric(text, pattern):
    match = re.search(pattern, text)
    if not match:
        raise ValueError(f"Missing report metric: {pattern}")
    return int(match.group(1))


def resources(board, tag):
    folder = ROOT / board / "Runs"
    project = "MultimediaSystem_" + board
    gate = (folder / f"syn_{tag}" / (project + "_gate.area")).read_text()
    area = (folder / f"phy_{tag}" / (project + "_phy.area")).read_text()
    qor = (folder / f"phy_{tag}" / "final.qor").read_text()
    return {
        "slices": metric(qor, r"#slices\s*\|\s*(\d+)"),
        "physical_luts": metric(area, r"#lut\s+(\d+)"),
        "physical_regs": metric(area, r"#reg\s+(\d+)"),
        "gate_luts": metric(gate, r"#lut\s+(\d+)"),
        "gate_regs": metric(gate, r"#reg\s+(\d+)"),
        "bram9k": metric(qor, r"#RAMs\s*\|\s*(\d+)"),
        "dsp": metric(qor, r"#DSPs\s*\|\s*(\d+)"),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--render-tag", default="text_osd_centered")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9_]+", args.render_tag):
        raise ValueError("Invalid render run tag")
    report = {"date": date.today().isoformat(), "protocol_minor": 4, "hardware_verified": False,
              "text_max_bytes": 106, "text_alignment": "center", "snapshot_bytes": 292, "tool": "TD 6.2.168116", "boards": []}
    release = ROOT / "build/text-osd-release"
    release.mkdir(parents=True, exist_ok=True)
    for board in ("media", "render"):
        tag = "text_osd" if board == "media" else args.render_tag
        folder = ROOT / board / ("Runs/phy_" + tag)
        configuration = (folder / "settings.cfg").read_text()
        seed = metric(configuration, r"place seed (\d+)")
        input_time = (folder / "inputs.json").stat().st_mtime
        for name in ("qualification.json", "final.qor", f"MultimediaSystem_{board}.bit",
                     f"MultimediaSystem_{board}_phy.area", f"MultimediaSystem_{board}_phy.ts"):
            if (folder / name).stat().st_mtime < input_time:
                raise ValueError(f"Stale/incomplete build artifact: {board}/{name}")
        qualified = json.loads((folder / "qualification.json").read_text())
        if (qualified["setup_wns_ns"] < .100 or qualified["setup_tns_ns"] != 0 or
                qualified["hold_wns_ns"] < 0 or qualified["hold_tns_ns"] != 0 or
                qualified["bram9k"] > 56):
            raise ValueError(f"Unqualified {board}")
        current = json.loads(subprocess.check_output([
            "pwsh", "-NoProfile", "-File", str(ROOT / board / "build/input-fingerprint.ps1")
        ], text=True, encoding="utf-8-sig"))
        expected = json.loads((folder / "inputs.json").read_text())
        synthesis = json.loads((ROOT / board / ("Runs/syn_" + tag) / "inputs.json").read_text())
        if current != expected or synthesis != expected:
            raise ValueError(f"Build input mismatch: {board}")
        bit = folder / f"MultimediaSystem_{board}.bit"
        digest = hashlib.sha256(bit.read_bytes()).hexdigest()
        if digest != qualified["bit_sha256"]:
            raise ValueError(f"Bit fingerprint mismatch: {board}")
        before, after = resources(board, "keypad_release"), resources(board, tag)
        qualified.update({"place_seed": seed, "run_tag": tag,
                          "physical_effort": "high" if "place effort high" in configuration else "medium",
                          "baseline": before, "current": after,
                          "delta": {key: after[key] - before[key] for key in after},
                          "input_fingerprint_verified": True,
                          "bit_path": bit.relative_to(ROOT).as_posix(),
                          "release_bit_path": (release / bit.name).relative_to(ROOT).as_posix(),
                          "inputs_sha256": hashlib.sha256((folder / "inputs.json").read_bytes()).hexdigest()})
        report["boards"].append(qualified)
        shutil.copy2(bit, release / bit.name)
        shutil.copy2(folder / "inputs.json", release / (board + "-inputs.json"))
        for name in ("final.qor", f"MultimediaSystem_{board}_phy.area", f"MultimediaSystem_{board}_phy.ts"):
            shutil.copy2(folder / name, release / (board + "-" + name))
    gate = (ROOT / "render" / ("Runs/syn_" + args.render_tag) / "MultimediaSystem_render_gate.area").read_text()
    report["render_local_modules"] = []
    for line in gate.splitlines():
        fields = [field.strip() for field in line.split("|")][1:-1]
        if len(fields) == 7 and fields[1] in {
            "text_osd_controller", "text_osd_event_router", "text_osd_view_cdc", "text_osd_overlay"
        }:
            item = dict(zip(("instance", "module", "lut", "ripple", "seq", "bram", "dsp"), fields))
            for key in ("lut", "ripple", "seq", "bram", "dsp"):
                item[key] = int(item[key])
            if item["bram"] or item["dsp"]:
                raise ValueError("Local OSD module consumed BRAM/DSP")
            report["render_local_modules"].append(item)
    if len(report["render_local_modules"]) != 4:
        raise ValueError("Missing OSD hierarchy resources")
    report["dsp_mapping_note"] = (
        "The new OSD modules use zero DSP. Total render DSP increases by one because "
        "the existing brightness_scale instance maps to two DSP instead of one."
    )
    evidence_files = sorted(
        list((ROOT / "media/build/evidence").glob("tb_*.txt")) +
        list((ROOT / "render/build/evidence").glob("tb_*.txt")) +
        list((ROOT / "doc/dual-board/evidence").glob("system-*.txt")) +
        list((ROOT / "doc/dual-board/evidence").glob("audio-system-*.txt"))
    )
    report["simulation_evidence"] = []
    for path in evidence_files:
        content = path.read_text(encoding="utf-8", errors="replace")
        if "PASS" not in content or re.search(r"# Errors: [1-9]", content):
            raise ValueError(f"Simulation evidence failed: {path}")
        report["simulation_evidence"].append({
            "path": path.relative_to(ROOT).as_posix(),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
    report["validation"] = {
        "full_dual_board_regression": "passed",
        "centered_expansion_regression": "affected render tests rerun; unchanged media/network/audio tests reuse the preceding full regression",
        "text_osd_pixel_checks": metric((ROOT / "render/build/evidence/tb_text_osd_overlay.txt").read_text(), r"pixels: (\d+) checks"),
        "text_osd_navigation_edges": 120,
        "text_osd_pipeline": "passed; contrast isolation and final RGB brightness",
        "hardware_acceptance": "pending",
    }
    output = ROOT / "doc/dual-board/evidence/text-osd-qualification.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    shutil.copy2(output, release / "qualification.json")
    lines = ["# Text OSD paired release", "",
             "Protocol v1.4; update both boards together. Hardware acceptance is pending.", "",
             "| Board | Bit | Seed | Physical effort | Setup WNS | Hold WNS | BRAM9K |",
             "|---|---|---:|---|---:|---:|---:|"]
    for item in report["boards"]:
        lines.append(f"| {item['board']} | MultimediaSystem_{item['board']}.bit | "
                     f"{item['place_seed']} | {item['physical_effort']} | "
                     f"{item['setup_wns_ns']:+.3f} ns | {item['hold_wns_ns']:+.3f} ns | "
                     f"{item['bram9k']} |")
    lines.extend(["", "qualification.json records current inputs, bit SHA256, resources and simulation evidence.",
                  "The original keypad_release bits do not contain Text OSD.", "",
                  "Text is centered at y=16. Capacity is 106 ASCII characters (1272 pixels, 4 pixels each side at 1280 width).",
                  "The editor preview scrolls to the final 29 characters; the complete line is retained.", "",
                  "Render reset clears text/configuration; leaving the menu, reconnecting or media reset preserves it.",
                  "Bench checks: edit 106 bytes, return/re-enter, close menus, switch pictures/play audio,",
                  "disconnect/reconnect keypad and network, reset media alone, then reset render.", ""])
    (release / "README.md").write_text("\n".join(lines), encoding="utf-8")
    print(json.dumps({"boards": report["boards"], "release": str(release)}, indent=2))


if __name__ == "__main__":
    main()
