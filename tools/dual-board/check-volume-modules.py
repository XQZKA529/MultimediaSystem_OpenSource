"""Synthesize volume modules in isolation; record RAM/DSP mapping evidence."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TD = Path('D:/AnLu_FPGA_environment/bin/td_commands_prompt.exe')
OUT = ROOT / 'build/audio-volume-2026-10-09/probes'
MODULES = {
    'volume_controller': 'media/rtl/audio/volume_controller.v',
    'audio_volume_gain': 'render/rtl/audio/audio_volume_gain.v',
    'volume_view_cdc': 'render/rtl/audio/volume_view_cdc.v',
    'volume_hint_controller': 'render/rtl/ui/volume_hint_controller.v',
    'volume_overlay': 'render/rtl/ui/volume_overlay.v',
}
results = []
for name, source in MODULES.items():
    run = OUT / name
    run.mkdir(parents=True, exist_ok=True)
    (run/'probe.v').write_bytes((ROOT/source).read_bytes())
    if name == 'volume_overlay':
        (run/'font_blend.vh').write_bytes((ROOT/'render/rtl/ui/font_blend.vh').read_bytes())
    create = 'open_project probe.al\nexit\n' if (run/'probe.al').exists() else (
        'create_project -family EG4 -device EG4S20BG256 probe .\n'
        f'add_files probe.v\nopen_project probe.al\ntop_module {name}\nexit\n')
    (run/'create.tcl').write_text(create, encoding='utf-8')
    (run/'synth.tcl').write_text(f'open_project probe.al\nimport_device eagle_s20.db -package EG4S20BG256\n'
        f'elaborate -top {name}\noptimize_rtl\noptimize_gate -packarea probe.area\nwrite_verilog probe_gate.v\nexit\n', encoding='utf-8')
    for step in ('create', 'synth'):
        with (run/f'{step}.txt').open('w', encoding='utf-8') as log:
            proc = subprocess.run([str(TD), f'{step}.tcl'], cwd=run, stdout=log, stderr=subprocess.STDOUT)
        console = (run/f'{step}.txt').read_text(encoding='utf-8', errors='replace')
        if proc.returncode or re.search(r'(?m)^[A-Z]+-\d+\s+(ERROR|FATAL)\b|Oops! coredump', console):
            raise RuntimeError(f'{name} {step} failed; see {run}')
    area = (run/'probe.area').read_text(encoding='utf-8', errors='replace')
    counts = {}
    for resource in ('lut', 'reg', 'bram9k', 'bram32k', 'dsp'):
        match = re.search(rf'(?m)^\s*#{resource}\s+(\d+)', area)
        if match:
            counts[resource] = int(match[1])
    assert counts['bram9k'] == counts['bram32k'] == 0, counts
    row = dict(module=name, source=source, source_sha256=hashlib.sha256((ROOT/source).read_bytes()).hexdigest(), **counts)
    results.append(row)
    (OUT/'results.json').write_text(json.dumps(results, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(row), flush=True)
