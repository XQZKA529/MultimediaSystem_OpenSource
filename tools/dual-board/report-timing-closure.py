"""Summarize final routed timing, resources and worst paths without hiding failures."""
import argparse
import hashlib
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument("runs", nargs="+", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
results = []
for run in args.runs:
    timing_files = list(run.glob("*_pr.timing"))
    if len(timing_files) != 1:
        raise SystemExit(f"Expected exactly one routed timing report in {run}")
    timing = timing_files[0]
    content = timing.read_text(encoding="utf-8")
    result = {"run": str(run.resolve()), "timing_sha256": hashlib.sha256(timing.read_bytes()).hexdigest()}
    for field, pattern in [("board", r"Top Model\s*:\s*top_(\w+)"),
                           ("confidence", r"Confidence\s*:\s*(\w+)"),
                           ("check_corner", r"Check Corner\s*:\s*(.*)")]:
        match = re.search(pattern, content)
        if not match:
            raise SystemExit(f"Missing {field}: {timing}")
        result[field] = match[1].strip()
    if result["confidence"] != "Routed" or not result["check_corner"].startswith("Both"):
        raise SystemExit(f"Requires routed timing at both corners: {timing}")
    for name in ["SWNS", "STNS", "HWNS", "HTNS"]:
        match = re.search(rf"\b{name}:\s*([-\d.]+)ns", content)
        if not match:
            raise SystemExit(f"Missing {name}: {timing}")
        result[name] = float(match[1])
    # TD reports explicit max/min-delay paths separately from clock groups.
    # Count both, and prefer the final QoR total when available.
    exception = run / (timing.name.removesuffix("_pr.timing") + "_exception.timing")
    path_reports = [("summary", content)]
    if exception.exists():
        path_reports.append(("exception", exception.read_text(encoding="utf-8")))
        result["exception_timing_sha256"] = hashlib.sha256(exception.read_bytes()).hexdigest()
    combined = "\n".join(report for _, report in path_reports)
    result["setup_violated_endpoints"] = sum(map(int, re.findall(r"^Max\s*:\s*SWNS.*?\s(\d+) Viol Endpoints", combined, re.M)))
    result["hold_violated_endpoints"] = sum(map(int, re.findall(r"^Min\s*:\s*HWNS.*?\s(\d+) Viol Endpoints", combined, re.M)))
    area = next(run.glob("*_phy.area"), None)
    if area:
        text = area.read_text(encoding="utf-8")
        for name in ["lut", "reg", "bram", "bram32k", "dsp", "pll"]:
            match = re.search(rf"^#{name}\s+(\d+)\s+out of\s+(\d+)", text, re.M)
            if match:
                result[name] = {"used": int(match[1]), "capacity": int(match[2])}
    qor = run / "final.qor"
    if not qor.exists():
        qor = run / "route.qor"
    if qor.exists():
        qor_text = qor.read_text(encoding="utf-8")
        match = re.search(r"#slices\s*\|\s*(\d+)", qor_text)
        if match:
            result["slices"] = {"used": int(match[1]), "capacity": 9800}
        if qor.name == "final.qor":
            for label, field in [("Setup WNS", "SWNS"), ("Setup TNS", "STNS"),
                                 ("Hold WNS", "HWNS"), ("Hold TNS", "HTNS")]:
                match = re.search(rf"\|\s*{label}\s*\|\s*([-\d.]+)", qor_text)
                if not match or abs(float(match[1]) / 1000 - result[field]) > 0.0005:
                    raise SystemExit(f"Final QoR and timing disagree: {field} in {run}")
            for label, field in [("Num of violated S-EP", "setup_violated_endpoints"),
                                 ("Num of violated H-EP", "hold_violated_endpoints")]:
                match = re.search(rf"\|\s*{label}\s*\|\s*(\d+)", qor_text)
                if not match:
                    raise SystemExit(f"Missing final endpoint count: {label} in {run}")
                result[field] = int(match[1])
    result["timing_pass"] = (result["SWNS"] >= 0.100 and result["HWNS"] >= 0 and
                             result["STNS"] == result["HTNS"] == 0 and
                             result["setup_violated_endpoints"] == result["hold_violated_endpoints"] == 0)
    paths = []
    for origin, report in path_reports:
        for section in report.split("Slack               : ")[1:]:
            entry = {"slack_ns": float(section.split("ns", 1)[0]), "report": origin}
            for key in ["Begin Point", "End Point", "Check Type", "Logic Level", "Data Path Delay", "Max Fanout"]:
                match = re.search(rf"^{key}\s*:\s*(.*)", section, re.M)
                if match:
                    entry[key] = match[1].split(" (rising edge")[0].split(" (falling edge")[0]
            if entry["slack_ns"] < 0:
                paths.append(entry)
    result["violating_paths_in_summary"] = sorted(paths, key=lambda item: item["slack_ns"])
    results.append(result)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
for result in results:
    print(Path(result["run"]).name, "setup", result["SWNS"], result["STNS"],
          result["setup_violated_endpoints"], "hold", result["HWNS"], result["HTNS"],
          result["hold_violated_endpoints"], "PASS" if result["timing_pass"] else "FAIL")
