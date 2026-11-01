"""Prepare isolated baseline/all-on-media projects; never edits production RTL.

Usage: python tools/dual-board/prepare-keypad-comparison.py build/keypad-compare-final
Then run each media/build/run.ps1 -Stage all -RunTag comparison -PlaceSeed 1.
"""
import io
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def prepare(destination):
    destination = destination.resolve()
    if destination.exists():
        raise FileExistsError(f"Use a new comparison directory: {destination}")
    destination.mkdir(parents=True)
    baseline = destination / "baseline"
    archive = subprocess.check_output(["git", "archive", "--format=zip", "HEAD", "media"], cwd=ROOT)
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        bundle.extractall(baseline)
    # Native project paths are relative to the original directory. Regenerate
    # through project.tcl instead of retaining paths into production sources.
    (baseline / "media/MultimediaSystem_media.al").unlink()
    alternate = destination / "all-on-media/media"
    for folder in ("rtl", "al_ip", "constr", "build"):
        shutil.copytree(ROOT / "media" / folder, alternate / folder)
    driver = alternate / "rtl/driver"
    driver.mkdir(exist_ok=True)
    for name in ("tm1650_keypad", "keypad_event_encoder"):
        shutil.copyfile(ROOT / f"render/rtl/driver/{name}.v", driver / f"{name}.v")
    top = alternate / "rtl/top_media.v"
    source = top.read_text(encoding="utf-8")
    source = source.replace("input wire sys_clk,sys_rst_n,", "input wire sys_clk,sys_rst_n,\n    inout wire KEYPAD_SCL,KEYPAD_SDA,")
    source = source.replace("wire kp_valid;wire [5:0] kp_data;", """wire kp_valid;wire [5:0] kp_data;
    wire kp_down,kp_online,kp_cancel;wire [3:0] kp_id;
    tm1650_keypad u_keypad(.clk(clk),.rst(rst),.scl(KEYPAD_SCL),.sda(KEYPAD_SDA),.down(kp_down),.key_id(kp_id),.online(kp_online),.cancel(kp_cancel));
    keypad_event_encoder u_keypad_events(.clk(clk),.rst(rst),.cancel(kp_cancel),.enabled(link_up && !session_reset),.down(kp_down),.online(kp_online),.key_id(kp_id),.valid(kp_valid),.ready(1'b1),.data(kp_data));""")
    source = source.replace("seam_media  u_seam(\n        .keypad_valid(kp_valid),.keypad_data(kp_data),", "seam_media  u_seam(")
    top.write_text(source, encoding="utf-8")
    with (alternate / "build/sources.txt").open("a", encoding="utf-8") as stream:
        stream.write("rtl/driver/tm1650_keypad.v\nrtl/driver/keypad_event_encoder.v\n")
    with (alternate / "constr/media.adc").open("a", encoding="utf-8") as stream:
        stream.write("\nset_pin_assignment { KEYPAD_SCL } { LOCATION = J12; IOSTANDARD = LVCMOS33; PULLTYPE = PULLUP; }\n")
        stream.write("set_pin_assignment { KEYPAD_SDA } { LOCATION = K14; IOSTANDARD = LVCMOS33; PULLTYPE = PULLUP; }\n")
    (destination / "baseline-revision.txt").write_text(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT).decode())
    print(destination)


if __name__ == "__main__":
    prepare(Path(sys.argv[1]))
