"""Isolate the FAT controller's state enables without changing transitions.

The legacy numerical diagnostic alias and task return-state values are retained.
Only the private control/return storage and its decode are recoded.
"""
import argparse
import re
from pathlib import Path

from resource_experiment import snapshot


def apply(board):
    path = board / "rtl/fat/fat32_ro.v"
    source = path.read_text(encoding="utf-8-sig")
    original = "reg [6:0] control_state,rd_return_encoded;"
    if source.count(original) != 1:
        raise ValueError("Expected the binary private FAT controller")
    source = source.replace(original, "reg [127:0] control_state,rd_return_encoded;")
    source = source.replace("case(control_state)", "case(1'b1)").replace("case (control_state)", "case (1'b1)")
    source = re.sub(r"7'd(\d+)(\s*:state=)", r"control_state[\1]\2", source)
    source = re.sub(r"^(\s+)(S_\w+)(\s*:)", r"\1control_state[\2]\3", source, flags=re.M)
    source = re.sub(r"control_state\s*==\s*(S_\w+)", r"control_state[\1]", source)
    source = re.sub(r"control_state\s*!=\s*(S_\w+)", r"!control_state[\1]", source)
    source = re.sub(r"(control_state\s*<=)([^;]+);", lambda match:
                    match[1] + re.sub(r"\bS_\w+\b", lambda name:
                                      "(128'b1<<" + name[0] + ")", match[2]) + ";", source)
    source = source.replace("rd_return_encoded<=ret[6:0];", "rd_return_encoded<=128'b1<<ret[6:0];")
    source = source.replace("rd_return_encoded<=0;", "rd_return_encoded<=128'b1;")
    if re.search(r"control_state\s*[!=]=", source):
        raise ValueError("Unconverted FAT state comparison")
    path.write_text(source, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    snapshot(args.source, args.destination)
    apply(args.destination)
