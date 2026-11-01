"""Share the mutually exclusive draft-field increment/decrement datapath.

The live second tick remains independent and may coincide with any edit.
Field truncation, invalid values, day clamp and input priority are unchanged.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/ui/calendar_clock.v';s=f.read_text(encoding='utf-8-sig')
start=s.index('    always @(*) begin');end=s.index('    always @(posedge clk',start)
s=s[:start]+'''    // Exactly one draft field is edited on an input event. Select before
    // one eight-bit add/subtract; each destination keeps its original width.
    reg [7:0] edit_value,edit_min,edit_max,edit_next;
    always @(*) begin
        {y,m,d,h,n,s}=draft;
        edit_value=0;edit_min=0;edit_max=0;
        case(focus)
            0:begin edit_value={1'b0,y};edit_max=99;end
            1:begin edit_value={4'd0,m};edit_min=1;edit_max=12;end
            2:begin edit_value={3'd0,d};edit_min=1;edit_max={3'd0,last_day(y,m)};end
            3:begin edit_value={3'd0,h};edit_max=23;end
            4:begin edit_value={2'd0,n};edit_max=59;end
            5:begin edit_value={2'd0,s};edit_max=59;end
            default:begin end
        endcase
        edit_next=edit_value+(right ? 8'd1:8'hff);
        if(right && edit_value==edit_max)edit_next=edit_min;
        else if(!right && edit_value==edit_min)edit_next=edit_max;
        case(focus)
            0:y=edit_next[6:0];1:m=edit_next[3:0];2:d=edit_next[4:0];
            3:h=edit_next[4:0];4:n=edit_next[5:0];5:s=edit_next[5:0];
            default:begin end
        endcase
        if(d>last_day(y,m))d=last_day(y,m);
        adjusted={y,m,d,h,n,s};
    end
'''+s[end:]
f.write_text(s,encoding='utf-8')
