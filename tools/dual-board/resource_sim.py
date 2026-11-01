"""Run a bounded ModelSim test with reproducible input hashes and logs."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess

MS = Path(os.environ.get("MODELSIM_BIN", "D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem"))
TD = Path(os.environ.get("TD_ROOT", "D:/AnLu_FPGA_environment"))


def simulate(work, top, files, includes=(), defines=(), native=False, plus=()):
    work = Path(work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    files = [Path(p).resolve() for p in files]
    if native:
        files = [TD / "sim_release/common/al_phy_glbl.v",
                 TD / "sim_release/eg4/eg_phy_bram.v",
                 TD / "sim_release/eg4/eg_phy_bram32k.v",
                 TD / "sim_release/eg4/eg_logic_bram.v",
                 TD / "sim_release/eg4/eg_phy_mult18.v"] + files
    dependencies=set(files)
    pending=list(files)
    include_roots=[Path(p).resolve() for p in includes]
    while pending:
        source=pending.pop()
        for name in re.findall(r'`include\s+"([^"]+)"',source.read_text(errors='replace')):
            target=next((p.resolve() for p in [source.parent/name,*[d/name for d in include_roots]] if p.is_file()),None)
            if target and target not in dependencies:
                dependencies.add(target);pending.append(target)
    for argument in plus:
        if '=' in argument:
            target=Path(argument.split('=',1)[1])
            if target.is_file():dependencies.add(target.resolve())
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(dependencies)}
    (work/'inputs.json').write_text(json.dumps(hashes,indent=2),encoding='utf-8')
    (work/'invocation.json').write_text(json.dumps(dict(top=top,native=native,includes=list(map(str,include_roots)),
                                                      defines=list(defines),plus=list(plus)),indent=2),encoding='utf-8')
    def run(exe, args, log):
        with (work / log).open("w", encoding="utf-8") as output:
            result = subprocess.run([str(MS / exe), *args], cwd=work,
                                    stdout=output, stderr=subprocess.STDOUT, timeout=1800)
        if result.returncode:
            raise RuntimeError((work / log).read_text(errors="replace")[-6000:])
    run("vlib.exe", ["work"], "vlib.log")
    run("vlog.exe", ["-timescale", "1ns/1ps", *["+incdir+"+str(Path(p).resolve()) for p in includes],
                     *["+define+"+d for d in defines], *map(str, files)], "compile.log")
    tops = [top] + (["glbl"] if native else [])
    run("vsim.exe", ["-c", "-voptargs=+acc", *tops, *plus,
                     "-do", "onerror {quit -code 2}; onbreak {quit -code 3}; run -all; quit -code 0"], "simulate.log")
    log = (work / "simulate.log").read_text(errors="replace")
    if "PASS" not in log or "** Error" in log or "** Fatal" in log:
        raise RuntimeError(log[-6000:])
    changed=[str(p) for p in sorted(dependencies)
             if not p.exists() or hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p)]]
    if changed:
        raise RuntimeError('Simulation inputs changed during run: '+', '.join(changed))
    (work/'result.json').write_text(json.dumps(dict(status='PASS',inputs_stable=True,
        source_files=len(hashes),log_sha256=hashlib.sha256((work/'simulate.log').read_bytes()).hexdigest()),
        indent=2),encoding='utf-8')
    print(str(work), next((l.strip() for l in log.splitlines() if "PASS" in l), "PASS"))
