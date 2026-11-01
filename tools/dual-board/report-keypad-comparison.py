"""Compare final routed builds and verify their archived input fingerprints."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def number(text, expression):
    match = re.search(expression, text)
    if not match:
        raise ValueError(f"Missing report field: {expression}")
    return float(match[1])


def metrics(directory, board):
    directory = directory.resolve()
    root = directory.parents[1]
    inputs = json.loads((directory / "inputs.json").read_text(encoding="utf-8"))
    for name, expected in inputs.items():
        actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f"Input changed: {root / name}")
    settings=(directory/'settings.cfg').read_text()
    seed = int(number(settings, r'place seed (\d+)'))
    if 'map_mode area_prior' not in settings or 'place effort high' not in settings or 'route effort routability' not in settings:
        raise ValueError(f'Unexpected comparison strategy: {directory}')
    project = f"MultimediaSystem_{board}"
    final = (directory / "final.qor").read_text()
    physical = (directory / f"{project}_phy.area").read_text()
    timing = (directory / f"{project}_phy.ts").read_text()
    synthesis = directory.parent / directory.name.replace("phy", "syn", 1)
    gate = (synthesis / f"{project}_gate.area").read_text()
    result = {
        "run": str(directory),
        "place_seed": seed,
        "slices": int(number(final, r"#slices\s*\|\s*(\d+)")),
        "slice_percent": number(final, r"slices percentage\s*\|\s*([0-9.]+)"),
        "physical_luts": int(number(physical, r"#lut\s+(\d+)")),
        "physical_regs": int(number(physical, r"#reg\s+(\d+)")),
        "gate_luts": int(number(gate, r"#lut\s+(\d+)")),
        "gate_regs": int(number(gate, r"#reg\s+(\d+)")),
        "bram9k": int(number(final, r"#RAMs\s*\|\s*(\d+)")),
        "dsp": int(number(final, r"#DSPs\s*\|\s*(\d+)")),
        "setup_wns_ns": number(timing, r"SWNS:\s*([-0-9.]+)ns"),
        "setup_tns_ns": number(timing, r"STNS:\s*([-0-9.]+)ns"),
        "hold_wns_ns": number(timing, r"HWNS:\s*([-0-9.]+)ns"),
        "hold_tns_ns": number(timing, r"HTNS:\s*([-0-9.]+)ns"),
        "input_fingerprint_verified": True,
    }
    result["slice_advisory_exceeded"] = result["slice_percent"] > 80
    result["qualified"] = (
        result["setup_wns_ns"] >= .100 and result["setup_tns_ns"] == 0
        and result["hold_wns_ns"] >= 0 and result["hold_tns_ns"] == 0
        and result["bram9k"] <= 56
    )
    return result, inputs


def main():
    parser = argparse.ArgumentParser()
    for argument in ("baseline", "all_on_media", "media", "render", "output"):
        parser.add_argument(argument, type=Path)
    args = parser.parse_args()
    report = {"tool": "TD 6.2.168116"}
    fingerprints = {}
    for variant in ("baseline", "all_on_media", "media", "render"):
        report[variant], fingerprints[variant] = metrics(getattr(args, variant), "render" if variant == "render" else "media")
    media_seeds = {report[variant]["place_seed"] for variant in ("baseline", "all_on_media", "media")}
    if len(media_seeds) != 1:
        raise ValueError("Media comparison runs must use the same placement seed")
    report["media_seed"] = media_seeds.pop()
    report["render_seed"] = report["render"]["place_seed"]
    exceptions = {"rtl/top_media.v", "constr/media.adc", "build/sources.txt"}
    local_inputs, alternate_inputs = fingerprints["media"], fingerprints["all_on_media"]
    for name, digest in local_inputs.items():
        if name not in exceptions and alternate_inputs.get(name) != digest:
            raise ValueError(f"Comparison has unrelated input difference: {name}")
    allowed_extra = {"rtl/driver/tm1650_keypad.v", "rtl/driver/keypad_event_encoder.v"}
    if set(alternate_inputs) - set(local_inputs) != allowed_extra:
        raise ValueError("Unexpected alternate source set")
    for name in allowed_extra:
        if alternate_inputs[name] != fingerprints['render'].get(name):
            raise ValueError(f'Driver differs between board placements: {name}')
    report["same_business_inputs_verified"] = True
    report["saved_on_media"] = {
        key: report["all_on_media"][key] - report["media"][key]
        for key in ("slices", "physical_luts", "physical_regs", "gate_luts", "gate_regs", "bram9k", "dsp")
    }
    report["saved_on_media"]["slice_percentage_points"] = round(report["saved_on_media"]["slices"] / 98, 4)
    report["media_net_change_from_baseline"] = {
        key: report["media"][key] - report["baseline"][key]
        for key in ("slices", "physical_luts", "physical_regs", "bram9k", "dsp")
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(report["saved_on_media"], ensure_ascii=False))


if __name__ == "__main__":
    main()
