"""Replace the existing registered AA arithmetic stage with exact ROM reads.

Preserves the pixel/sync latency and all palette values. Uses the remaining
one BRAM32K and one BRAM9K instead of three weighted sums and constant divides.
Run synthesis/physical implementation before scheduling functional regression.
"""
import argparse
from pathlib import Path

from resource_experiment import snapshot
from resource_rom import byte_rom9, rom


def apply(board):
    path = board / "rtl/ui/text_osd_overlay.v"
    text = path.read_text(encoding="utf-8-sig")
    start = text.index("    // Split the RAM-to-blend path at the weighted sum.")
    end = text.index("    always @(*) begin\n        pix_out=rgb_e;", start)
    text = text[:start] + """    // Exact AA table replaces the existing arithmetic register boundary.
    // The synchronous reads and the bypass RGB/control registers advance
    // together, so pixel latency and coverage alignment stay unchanged.
    wire [15:0] final_r,final_g;
    wire [7:0] final_b;
    reg final_valid;
    reg [23:0] rgb_e;
    reg win_e,txt_e,line_e;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            final_valid<=0;rgb_e<=0;win_e<=0;txt_e<=0;line_e<=0;
        end else begin
            final_valid<=1;rgb_e<=rgb_d;
            win_e<=win_d;txt_e<=txt_d;line_e<=line_d;
        end
    end
    resource_text_final_rg u_final_rg(.clk(clk),.addr({coverage,glyph_background[23:16]}),
        .addr_b({coverage,glyph_background[15:8]}),.q(final_r),.q_b(final_g));
    resource_text_final_b u_final_b(.clk(clk),.addr({coverage,glyph_background[7:0]}),.q(final_b));
    wire [23:0] glyph_rgb=final_valid ? {final_r[7:0],final_g[15:8],final_b}:24'd0;
""" + text[end:]
    channels = [[], [], []]
    for coverage in range(4):
        for background in range(256):
            for channel, foreground in enumerate((245, 247, 250)):
                channels[channel].append((
                    background, (foreground + 2 * background + 1) // 3,
                    (2 * foreground + background + 1) // 3, foreground,
                )[coverage])
    text += rom("resource_text_final_rg", [r | (g << 8) for r, g in
                                          zip(channels[0], channels[1])], 10)
    text += byte_rom9("resource_text_final_b", channels[2])
    path.write_text(text, encoding="utf-8")


def cache_keypad_head(board):
    path = board / "rtl/driver/keypad_event_encoder.v"
    text = path.read_text(encoding="utf-8-sig")
    text = text.replace("reg [5:0] fifo[0:7];", "reg [5:0] head;\n reg [5:0] fifo[0:7];")
    text = text.replace("6'b110000:fifo[rd]", "6'b110000:head")
    text = text.replace("if(rst) begin rd<=0;", "if(rst) begin head<=0;rd<=0;")
    text = text.replace("    rd<=0;wr<=0;count<=0;held<=0;", "    head<=0;rd<=0;wr<=0;count<=0;held<=0;")
    marker = "     if(push) begin fifo[wr]<=event_data;wr<=wr+1'b1;end"
    if marker not in text:
        raise ValueError("Expected the original eight-entry keypad FIFO")
    text = text.replace(marker, """     // Cache the current head at the enqueue/pop edge. Forward a just
     // appended word when it becomes the head, including pop+push at count=1.
     // Consumers no longer decode the eight-entry asynchronous read mux.
     if(push && (count==0 || (count==1 && pop))) head<=event_data;
     else if(pop && count>1) head<=fifo[next_rd];
""" + marker)
    text = text.replace("wire pop=valid && ready;", "wire pop=valid && ready;\n wire [2:0] next_rd=rd+3'd1;")
    path.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--cache-keypad-head", action="store_true")
    args = parser.parse_args()
    snapshot(args.source, args.destination)
    apply(args.destination)
    if args.cache_keypad_head:
        cache_keypad_head(args.destination)
