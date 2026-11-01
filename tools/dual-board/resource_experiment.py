"""Freeze optimization inputs and evaluate final, post-hold experiment reports.

This deliberately does not change the production qualification scripts.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil

ROOT = Path(__file__).resolve().parents[2]
LIMITS = {
    "media": dict(slices=9707, swns=-2.413, stns=-638.324, setup_endpoints=956),
    "render": dict(slices=9787, swns=-1.015, stns=-86.454, setup_endpoints=235),
}


def snapshot(source, destination):
    if destination.exists():
        raise RuntimeError(f"Snapshot already exists: {destination}")
    destination.mkdir(parents=True)
    for folder in ("rtl", "al_ip", "constr", "build", "sim"):
        shutil.copytree(source / folder, destination / folder,
                        ignore=shutil.ignore_patterns("evidence", "__pycache__"))
    for p in source.glob("*.al"):
        shutil.copy2(p, destination / p.name)
    hashes = {p.relative_to(destination).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(destination.rglob("*")) if p.is_file()}
    (destination / "frozen-inputs.json").write_text(
        json.dumps(hashes, indent=2), encoding="utf-8")
    print(json.dumps({"snapshot": str(destination), "files": len(hashes)}))


def report(board, run):
    if not (run / '.opt_route.end.f').exists() or (run / '.opt_route.error.f').exists():
        raise RuntimeError('Native routing/hold repair has not completed successfully')
    board_root = run.resolve().parents[1]
    expected = json.loads((run / "inputs.json").read_text(encoding="utf-8-sig"))
    files = []
    for folder in ("rtl", "al_ip", "constr"):
        files.extend(p for p in (board_root / folder).rglob("*") if p.is_file())
    files.extend(p for p in (board_root / "build").iterdir()
                 if p.is_file() and (p.suffix in (".ps1", ".tcl") or p.name == "sources.txt"))
    current = {p.relative_to(board_root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
               for p in files}
    if current != expected:
        changed = sorted(k for k in current.keys() | expected.keys() if current.get(k) != expected.get(k))
        raise RuntimeError(f"Build inputs changed: {changed}")
    qor = (run / "final.qor").read_text()
    area = (run / f"MultimediaSystem_{board}_phy.area").read_text()
    def q(name):
        match = re.search(r"\|\s*" + re.escape(name) + r"\s*\|\s*(-?[\d.]+)", qor)
        if not match:
            raise RuntimeError(f"Missing QoR metric: {name}")
        return float(match[1])
    def a(name):
        match = re.search(r"(?m)^\s*#" + name + r"\s+(\d+)", area)
        if not match:
            raise RuntimeError(f"Missing area metric: {name}")
        return int(match[1])
    values = dict(board=board, run=str(run), slices=int(q("#slices")),
                  swns=q("Setup WNS") / 1000, stns=q("Setup TNS") / 1000,
                  hwns=q("Hold WNS") / 1000, htns=q("Hold TNS") / 1000,
                  setup_endpoints=int(q("Num of violated S-EP")),
                  hold_endpoints=int(q("Num of violated H-EP")),
                  bram9k=a("bram9k"), fifo9k=a("fifo9k"), bram32k=a("bram32k"),
                  lut=a("lut"), registers=a("reg"), dsp=a("dsp"), rams=int(q("#RAMs")))
    values["inputs_sha256"] = hashlib.sha256((run / "inputs.json").read_bytes()).hexdigest()
    post_hold=run / f"MultimediaSystem_{board}_pr.timing"
    timing=post_hold.read_text()
    for label,key in (("SWNS","swns"),("STNS","stns"),("HWNS","hwns"),("HTNS","htns")):
        match=re.search(r'\b'+label+r':\s*(-?[\d.]+)ns',timing)
        if not match or abs(float(match[1])-values[key])>0.0005:
            raise RuntimeError(f'Final QoR and post-hold timing disagree: {label}')
    values["post_hold_timing_sha256"]=hashlib.sha256(post_hold.read_bytes()).hexdigest()
    b = LIMITS[board]
    reasons = []
    for key in ("swns", "stns"):
        if values[key] < b[key]:
            reasons.append(f"{key} worse than delivered baseline")
    if values["setup_endpoints"] > b["setup_endpoints"]:
        reasons.append("more setup violation endpoints")
    if values["hwns"] < 0 or values["htns"] != 0 or values["hold_endpoints"] != 0:
        reasons.append("hold violations")
    if values["bram9k"] + values["fifo9k"] > 60 or values["bram32k"] > 14:
        reasons.append("experimental BRAM budget exceeded")
    if values["dsp"]>29:
        reasons.append("native DSP capacity exceeded")
    if values["rams"] != values["bram9k"] + values["fifo9k"] + values["bram32k"]:
        reasons.append("RAM accounting mismatch")
    if values["slices"] >= b["slices"]:
        reasons.append("no final Slice reduction")
    values.update(experiment_pass=not reasons, rejection_reasons=reasons,
                  target_90_percent=values["slices"] <= 8820,
                  slices_saved=b["slices"] - values["slices"],
                  remaining_to_target=max(0, values["slices"] - 8820),
                  formal_timing_pass=values["swns"] >= .100 and values["stns"] == 0
                  and values["setup_endpoints"] == 0 and values["hwns"] >= 0
                  and values["htns"] == 0 and values["hold_endpoints"] == 0)
    bit = run / f"MultimediaSystem_{board}.bit"
    if not bit.exists():
        bit = run / f"MultimediaSystem_{board}_RESOURCE_TRIAL.bit"
    values["bit_sha256"] = hashlib.sha256(bit.read_bytes()).hexdigest() if bit.exists() else None
    (run / "resource-experiment.json").write_text(
        json.dumps(values, indent=2), encoding="utf-8")
    print(json.dumps(values, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    freeze = sub.add_parser("snapshot")
    freeze.add_argument("--source", type=Path, required=True)
    freeze.add_argument("--destination", type=Path, required=True)
    check = sub.add_parser("report")
    check.add_argument("--board", choices=LIMITS, required=True)
    check.add_argument("--run", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "snapshot":
        snapshot(args.source, args.destination)
    else:
        report(args.board, args.run)
