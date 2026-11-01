"""Move settings row decode into the existing first registered read boundary.

One spare BRAM32K supplies the row base and width; the existing character ROM
remains the second stage. No character, status fallback or read latency changes.
"""
import argparse
import re
from pathlib import Path

from resource_experiment import snapshot
from resource_rom import rom


def apply(board):
    path = board / "rtl/ui/settings_menu_text_rom.v"
    source = path.read_text(encoding="utf-8-sig")
    case = source[source.index("case({page,row})"):source.index("if(page==2 && row==5)")]
    entries = {int(code): (int(slot), int(wide)) for code, slot, wide in re.findall(
        r"8'd(\d+):begin row_slot=6'd(\d+);row_wide=1'b([01]);end", case)}
    if len(entries) < 40:
        raise ValueError("Expected packed settings/status row decoder")
    mode_case = source[source.index("if(page==2 && row==5)"):
                       source.index("wire [9:0] status_addr")]
    modes = {int(mode): (int(slot), int(wide)) for mode, slot, wide in re.findall(
        r"2'd(\d+):begin row_slot=6'd(\d+);row_wide=1'b([01]);end", mode_case)}
    status_base = int(re.search(r"status_addr=10'd(\d+)", source)[1])
    words = []
    for address in range(2048):
        status, mode, page, row = (address >> 10) & 1, (address >> 8) & 3, (address >> 4) & 15, address & 15
        if status:
            base, wide = status_base + ((row if row < 10 else 0) << 4), 0
        else:
            slot, wide = entries.get((page << 4) | row, (0, 0))
            if page == 2 and row == 5:
                slot, wide = modes.get(mode, (0, 0))
            base = slot << 4
        words.append(base | (wide << 10))
    start = source.index(" reg [5:0] row_slot;")
    end = source.index("`ifdef DB_BEHAVIORAL_RAM", start)
    source = source[:start] + """ // Preserve the two read boundaries: registered row metadata, then byte.
 wire use_status_bank=(status_bank===1'b1) || ((status_bank!==1'b0) && page==6);
 wire [15:0] metadata;
 reg [4:0] col_q;
 reg status_blank;
 always @(posedge clk) begin
  col_q<=col;
  status_blank<=!metadata[10] && col_q[4];
 end
 settings_menu_row_decode u_decode(.clk(clk),.addr({use_status_bank,mode,page,row}),
  .addr_b(11'd0),.q(metadata),.q_b());
 wire [9:0] address=metadata[9:0] | (metadata[10] ? {5'd0,col_q}:{6'd0,col_q[3:0]});
""" + source[end:]
    source += rom("settings_menu_row_decode", words, 11)
    path.write_text(source, encoding="utf-8")


def retime_receive_sequence(board):
    path = board / "rtl/link/db_link.v"
    source = path.read_text(encoding="utf-8-sig")
    source = source.replace("delivery_seq", "delivery_next_seq")
    source = source.replace("delivery_next_seq<=p_hdr[159:128];", "delivery_next_seq<=p_hdr[159:128]+32'd1;")
    source = source.replace("rx_next=delivery_next_seq+32'd1", "rx_next=delivery_next_seq")
    path.write_text(source, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    snapshot(args.source, args.destination)
    apply(args.destination)
    retime_receive_sequence(args.destination)
