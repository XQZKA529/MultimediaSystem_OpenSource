"""Read final post-hold reports; trial eligibility never changes formal gates."""
import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def board_report(board, run_tag):
    run = ROOT / board / "Runs" / ("phy_" + run_tag)
    project = "MultimediaSystem_" + board
    timing = (run / (project + "_phy.ts")).read_text()
    area = (run / (project + "_phy.area")).read_text()
    qor = (run / "final.qor").read_text()
    inputs = json.loads((run / "inputs.json").read_text())
    actual = {}
    for folder in ("rtl", "al_ip", "constr"):
        for p in (ROOT / board / folder).rglob("*"):
            if p.is_file():
                actual[p.relative_to(ROOT / board).as_posix()] = sha(p)
    for p in (ROOT / board / "build").iterdir():
        if p.is_file() and (p.suffix in (".ps1", ".tcl") or p.name == "sources.txt"):
            actual[p.relative_to(ROOT / board).as_posix()] = sha(p)
    if inputs != actual:
        raise RuntimeError(f"{board}: build inputs no longer match current sources")
    result = {"board": board, "run_tag": run_tag, "inputs": inputs}
    for key in ("SWNS", "STNS", "HWNS", "HTNS"):
        result[key] = float(re.search(key + r":\s*([-0-9.]+)ns", timing)[1])
    result["slices"] = int(re.search(r"#slices\s*\|\s*(\d+)", qor)[1])
    for key in ("lut", "reg", "bram9k", "bram32k", "dsp", "pll"):
        result[key] = int(re.search(r"(?m)^\s*#" + key + r"\s+(\d+)", area)[1])
    for key, phrase in (("setup_violated_endpoints", "Num of violated S-EP"),
                        ("hold_violated_endpoints", "Num of violated H-EP")):
        result[key] = int(re.search(re.escape(phrase) + r"\s*\|\s*(\d+)", qor)[1])
    result["slice_percent"] = round(100 * result["slices"] / 9800, 2)
    result["slice_delta"] = result["slices"] - (9693 if board == "media" else 9052)
    baseline = {"bram9k": 56 if board == "media" else 51,
                "bram32k": 1 if board == "media" else 5,
                "dsp": 7 if board == "media" else 15, "pll": 1 if board == "media" else 2}
    result["hard_block_delta"] = {key: result[key] - value for key, value in baseline.items()}
    limits = {"slices": 9800, "lut": 19600, "reg": 19600, "bram9k": 64,
              "bram32k": 16, "dsp": 29, "pll": 4}
    result["physical_resources_legal"] = all(result[k] <= maximum for k, maximum in limits.items())
    result["trial_timing_eligible"] = (result["physical_resources_legal"] and result["HWNS"] >= 0
                                        and result["HTNS"] == 0 and result["hold_violated_endpoints"] == 0)
    ram_limit = 57 if board == "media" else 56
    result["timing_qualified"] = (result["trial_timing_eligible"] and result["SWNS"] >= 0.100
                                   and result["STNS"] == 0 and result["setup_violated_endpoints"] == 0
                                   and result["bram9k"] <= 56 and result["bram32k"] <= 16
                                   and result["bram9k"] + result["bram32k"] <= ram_limit)
    result["reports"] = {p.name: sha(p) for p in run.iterdir() if p.is_file()
                          and (p.suffix in (".area", ".ts", ".timing", ".qor") or p.name == "inputs.json")}
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--media", required=True)
    parser.add_argument("--render", required=True)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    result = {board: board_report(board, getattr(args, board)) for board in ("media", "render")}
    if args.out:
        args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for board, data in result.items():
        summary = {k: v for k, v in data.items() if k not in ("inputs", "reports")}
        print(json.dumps(summary, ensure_ascii=False))
