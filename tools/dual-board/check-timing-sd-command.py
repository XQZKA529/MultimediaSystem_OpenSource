"""Run the real SD card model and compare command pins/results every bus clock."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-root", type=Path, default=ROOT / "media")
parser.add_argument("--reference-revision", default="HEAD")
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--gate", action="store_true", help="Synthesize sdio_cmd and compare its mapped netlist")
parser.add_argument("--test", choices=['all', 'tb_sdio_card', 'tb_sdio_cmd_timeout',
                                       'tb_sdio_timeout_boundaries', 'tb_sdio_command_responses'], default='all')
args = parser.parse_args()
board = args.source_root.resolve()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
source = board / "rtl/sd/sdio_cmd.v"
reference = subprocess.check_output(
    ["git", "show", f"{args.reference_revision}:media/rtl/sd/sdio_cmd.v"], cwd=ROOT)
(out / "reference.v").write_bytes(reference.replace(b"module sdio_cmd(", b"module sdio_cmd_reference("))
ms = Path("D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem")
inputs = ["clk", "rst", "ck_rise", "ck_fall", "issue", "cmd_idx", "cmd_arg",
          "resp_type", "resp_timeout", "cmd_in"]
outputs = dict(busy=1, done=1, no_resp=1, crc_err=1, end_bad=1,
               resp_cmd=6, resp_arg=32, resp_r2=136, cmd_oe=1, cmd_out=1,
               dbg_state=4, dbg_tmo_clk=16)


def run(command, name):
    log_path = out / (name + '.log')
    with log_path.open('wb') as output:
        proc = subprocess.Popen([str(x) for x in command], cwd=out,
                                stdout=output, stderr=subprocess.STDOUT)
        try:
            code = proc.wait(timeout=300)
        except subprocess.TimeoutExpired:
            subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            proc.wait()
            raise SystemExit(f'{name} exceeded 300 seconds: {log_path}')
    log = log_path.read_bytes().decode('utf-8', errors='replace')
    if (code or "** Error" in log or "** Fatal" in log or "[FAIL]" in log or
            re.search(r"^[A-Z]+-\d+\s+(ERROR|FATAL)\b", log, re.M)):
        raise SystemExit(f"{name} failed: {out / (name + '.log')}")
    return log


run([ms / "vlib.exe", "work"], "library")
benches = []
boundary_bench = r"""
`timescale 1ns/1ps
module tb_sdio_timeout_boundaries;
reg clk=0,rst=1,phase=0,issue=0;
reg [15:0] timeout=1;
wire done,no_resp;
integer i;
always #5 clk=~clk;
always @(posedge clk) if(rst) phase<=0;else phase<=~phase;
sdio_cmd dut(.clk(clk),.rst(rst),.ck_rise(phase),.ck_fall(!phase),.issue(issue),
 .cmd_idx(6'd8),.cmd_arg(32'h1aa),.resp_type(2'd1),.resp_timeout(timeout),
 .busy(),.done(done),.no_resp(no_resp),.crc_err(),.end_bad(),.resp_cmd(),.resp_arg(),.resp_r2(),
 .cmd_oe(),.cmd_out(),.cmd_in(1'b1),.dbg_state(),.dbg_tmo_clk());
initial begin
 repeat(4) @(negedge clk);rst=0;
 for(i=0;i<8;i=i+1) begin
  case(i) 0:timeout=0;1:timeout=1;2:timeout=2;3:timeout=3;
          4:timeout=8;5:timeout=255;6:timeout=256;7:timeout=65535;endcase
  @(negedge clk);issue=1;
  @(negedge clk);issue=0;
  wait(done);#2;
  if(!no_resp) $fatal(1,"timeout did not expire: %0d",timeout);
  repeat(4) @(negedge clk);
 end
 $display("*** PASS *** SD timeout boundaries: 0,1,2,3,8,255,256,65535 at 50 MHz SD clock");
 $finish;
end
initial begin #10000000;$fatal(1,"boundary test timeout");end
endmodule
"""
response_bench = r'''
`timescale 1ns/1ps
module tb_sdio_command_responses;
reg clk=0,rst=1,phase=0,issue=0,cmd_in=1;
reg [1:0] typ=0;reg [5:0] idx=8;wire done,crc_err,end_bad;
integer n,j;reg [135:0] bits;reg [6:0] crc;
always #5 clk=~clk;
always @(posedge clk) if(rst) phase<=0;else phase<=~phase;
sdio_cmd dut(.clk(clk),.rst(rst),.ck_rise(phase),.ck_fall(!phase),.issue(issue),
 .cmd_idx(idx),.cmd_arg(32'h1aa),.resp_type(typ),.resp_timeout(16'd64),
 .busy(),.done(done),.no_resp(),.crc_err(crc_err),.end_bad(end_bad),
 .resp_cmd(),.resp_arg(),.resp_r2(),.cmd_oe(),.cmd_out(),.cmd_in(cmd_in),.dbg_state(),.dbg_tmo_clk());
task send_bit;input b;
 begin
  @(negedge clk);cmd_in=b;
  @(posedge clk);while(!phase)@(posedge clk);#1;
 end
endtask
initial begin
 repeat(4)@(negedge clk);rst=0;
 for(n=0;n<6;n=n+1)begin
  typ=n==0 ? 0:n==1 ? 1:n==2 ? 2:n==3 ? 3:1;
  idx=n+8;
  @(negedge clk);issue=1;
  @(negedge clk);issue=0;
  if(typ!=0)begin
   wait(dut.dbg_state==4);
   bits=136'h00123456789abcdef0123456789abcdef01;
   if(typ!=3)begin
    bits={88'd0,1'b0,1'b0,idx,32'h13579bdf,7'd0,1'b1};
    crc=0;
    for(j=47;j>=8;j=j-1) crc={crc[5:0],1'b0} ^ ((crc[6]^bits[j]) ? 7'h09:7'd0);
    bits[7:1]=crc;
    if(n==4)bits[1]=~bits[1];
    if(n==5)bits[0]=0;
   end
   send_bit(0);
   for(j=(typ==3 ? 134:46);j>=0;j=j-1)send_bit(bits[j]);
   @(negedge clk);cmd_in=1;
  end
  wait(done);#1;
  if(typ==1 && crc_err!==(n==4))$fatal(1,"short CRC outcome n=%0d",n);
  if(end_bad!==(n==5))$fatal(1,"end-bit outcome n=%0d",n);
  repeat(4)@(negedge clk);
 end
 $display("*** PASS *** SD command response types 0/1/2/3, valid and bad CRC, bad end bit at 50 MHz SD clock");$finish;
end
initial begin #100000;$fatal(1,"response watchdog");end
endmodule
'''
for name, hierarchy in [("tb_sdio_card", "tb_sdio_card.dut.u_core.u_cmd"),
                         ("tb_sdio_cmd_timeout", "tb_sdio_cmd_timeout.dut"),
                         ("tb_sdio_timeout_boundaries", "tb_sdio_timeout_boundaries.dut"),
                         ("tb_sdio_command_responses", "tb_sdio_command_responses.dut")]:
    if args.test != 'all' and args.test != name:
        continue
    monitor = "\nmodule sd_command_monitor;\ninteger checks=0;\n"
    monitor += "\n".join(f"wire [{width-1}:0] ref_{port};" for port, width in outputs.items())
    connections = [f".{port}({hierarchy}.{port})" for port in inputs]
    connections += [f".{port}(ref_{port})" for port in outputs]
    monitor += "\nsdio_cmd_reference reference(" + ",".join(connections) + ");\n"
    expected = "{" + ",".join("ref_" + port for port in outputs) + "}"
    actual = "{" + ",".join(hierarchy + "." + port for port in outputs) + "}"
    monitor += f"""
always @(posedge {hierarchy}.clk) begin
 #1;
 if(!{hierarchy}.rst) begin
  if({actual} !== {expected})
   $fatal(1,"SD command changed: pins, results or cycle timing differ at check %0d",checks);
  checks=checks+1;
 end
end
endmodule
"""
    text = (response_bench if name == 'tb_sdio_command_responses' else
            boundary_bench if name == "tb_sdio_timeout_boundaries" else
            (ROOT / "sim" / (name + ".v")).read_text(encoding="utf-8"))
    # The original bench still determines pass/fail and checks all card data.
    text = text.replace("$finish;", '$display("Command equivalence bus clocks: %0d", sd_command_monitor.checks);$finish;')
    target = out / (name + "_monitored.v")
    target.write_text(text + monitor, encoding="utf-8")
    benches.append((name, target))
rtl = [board / "rtl/sd" / (name + ".v")
       for name in ["sd_crc", "sdio_phy", "sdio_cmd", "sdio_core", "sd_card_sdio"]]
source_hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in rtl}
if args.gate:
    td = Path("D:/AnLu_FPGA_environment")
    script = out / 'synthesize.tcl'
    project_setup = (
        'create_project -family EG4 -device EG4S20BG256 sd_command .\n'
        + ''.join(f'add_files {{{path.as_posix()}}}\n' for path in rtl[:1] + [source])
    ) if not (out / 'sd_command.al').exists() else ''
    if project_setup:
        (out / 'create.tcl').write_text(project_setup + 'exit\n', encoding='utf-8')
        run([td / 'bin/td_commands_prompt.exe', 'create.tcl'], 'create')
    script.write_text('import_device eagle_s20.db -package EG4S20BG256\n'
          'open_project sd_command.al\ntop_module sdio_cmd\n'
          'elaborate -top sdio_cmd\noptimize_rtl\noptimize_gate -packarea cmd.area\n'
          'write_verilog sdio_cmd_gate.v\nexit\n', encoding='utf-8')
    run([td / 'bin/td_commands_prompt.exe', script.name], 'synthesis')
    gate = out / 'sdio_cmd_gate.v'
    if not gate.is_file():
        raise SystemExit('No mapped SD command netlist')
    # Keep any emitted CRC child modules independent of the reference RTL.
    gate.write_text(re.sub(r'\bsd_crc7\b', 'sd_crc7_gate', gate.read_text(encoding='utf-8')), encoding='utf-8')
    vendor = [td / 'sim_release/common' / name for name in
              ['al_map_lut.v', 'al_map_adder.v', 'al_map_basic.v', 'al_map_seq.v']]
    vendor += sorted((td / 'sim_release/eg4').glob('*.v'))
    rtl = vendor + [gate if path == source else path for path in rtl]
# Each monitor has a different DUT hierarchy; compile one bench at a time.
results = []
for name, bench in benches:
    run([ms / "vlog.exe", *rtl, out / "reference.v", bench], name + "-compile")
    log = run([ms / "vsim.exe", "-c", name, "sd_command_monitor", *(['glbl'] if args.gate else []),
               "-do", "onerror {quit -code 2}; onbreak {quit -code 3}; run -all; quit -code 0"], name)
    if "PASS" not in log or "Command equivalence bus clocks:" not in log:
        raise SystemExit(f"Missing card/equivalence completion: {name}")
    results.append(dict(test=name, passed=True))
    print("\n".join(line for line in log.splitlines() if "PASS" in line or "Command equivalence" in line))
if any(hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest for path, digest in source_hashes.items()):
    raise SystemExit('SD source changed during validation')
(out / "result.json").write_text(json.dumps(dict(
    source=str(source), source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
    reference_sha256=hashlib.sha256(reference).hexdigest(), tests=results,
    checked="all command pins, results and debug outputs on every bus clock",
    synthesized=args.gate, inputs=source_hashes,
    mapped_netlist_sha256=hashlib.sha256(gate.read_bytes()).hexdigest() if args.gate else None), indent=2), encoding="utf-8")
