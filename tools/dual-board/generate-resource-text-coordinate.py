"""Replace the 11-bit pixel /12 and %12 with a synchronous exact ROM.

The ROM replaces stage A's col/gx registers. Highlight controls are captured on
the same edge, preserving arbitrary per-cycle focus inputs and reset behavior.
All 2048 dx inputs retain the original seven-bit quotient truncation.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
from resource_rom import rom

p = argparse.ArgumentParser()
p.add_argument('--source', type=Path, required=True)
p.add_argument('--destination', type=Path, required=True)
args = p.parse_args()
snapshot(args.source, args.destination)
s = (args.source/'rtl/ui/text_osd_overlay.v').read_text(encoding='utf-8-sig')
s = s.replace('    wire [`TEXT_OSD_LEN_W-1:0] col=dx/11\'d12;', '')
s = s.replace("    wire [3:0] gx=dx%11'd12,gy=dy[3:0];", '    wire [3:0] gy=dy[3:0];')
a=s.index('    wire highlight=');b=s.index('    function [7:0] static_char;',a)
s=s[:a]+s[b:]
s=s.replace('line_a,high_a,win_b','line_a,win_b')
s=s.replace('    reg [`TEXT_OSD_LEN_W-1:0] col_a;reg [3:0] row_a;', '''    wire [15:0] coordinate_word;
    reg coordinate_valid;
    reg [3:0] focus_row_a;
    reg [4:0] focus_start_a,focus_end_a;
    reg focus_del_a;
    reg [3:0] row_a;
    wire [`TEXT_OSD_LEN_W-1:0] col_a=coordinate_valid ? coordinate_word[10:4]:7'd0;
    wire [3:0] gx_a=coordinate_valid ? coordinate_word[3:0]:4'd0;
    wire high_a=txt_a && row_a==focus_row_a && col_a>=focus_start_a &&
        (focus_del_a ? col_a<=31:col_a<focus_end_a);
    resource_text_coordinates u_coordinates(.clk(clk),.addr(dx),.addr_b(11'd0),.q(coordinate_word),.q_b());
''')
s=s.replace('reg [3:0] gx_a,gy_a,','reg [3:0] gy_a,')
s=s.replace('high_a<=0;','coordinate_valid<=0;focus_row_a<=0;focus_start_a<=0;focus_end_a<=0;focus_del_a<=0;')
s=s.replace('col_a<=0;','').replace('gx_a<=0;','')
s=s.replace('high_a<=highlight;', 'coordinate_valid<=1;focus_row_a<=focus_row;focus_start_a<=focus_start;focus_end_a<=focus_end;focus_del_a<=focus==29;')
s=s.replace('col_a<=col;','').replace('gx_a<=gx;','')
assert "dx/11'd12" not in s and 'high_a<=' not in s
(args.destination/'rtl/ui/text_osd_overlay.v').write_text(
    s+rom('resource_text_coordinates',[((n//12)&127)*16+n%12 for n in range(2048)],11),encoding='utf-8')
