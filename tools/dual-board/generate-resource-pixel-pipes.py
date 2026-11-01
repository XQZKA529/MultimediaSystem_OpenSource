"""Move two existing pixel/sync stages into native write-through BRAM registers.

No pixel latency changes. Each independent port stores a disjoint constant word.
The ready bit resets the output register until its first fresh input arrives,
preventing pre-reset RAM contents from reappearing after an asynchronous reset.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
p.add_argument('--clock-only',action='store_true')
a=p.parse_args()
snapshot(a.source,a.destination)

def helper(name):
    return '''
module NAME(input wire clk,rst,input wire [26:0] din,output wire [26:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [26:0] first,second;
 always @(posedge clk or posedge rst)
   if(rst) begin first<=0;second<=0;end
   else begin first<=din;second<=first;end
 assign q=second;
`else
 reg ready;
 always @(posedge clk or posedge rst) if(rst) ready<=0;else ready<=1;
 wire clear_output=rst || !ready;
 wire [15:0] upper;
 assign q[26:16]=upper[10:0];
 // Fixed, nonoverlapping words; both ports capture one pixel every clock.
 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
 .REGMODE_A("OUTREG"),.REGMODE_B("OUTREG"),.SRMODE("ASYNC"),
 .WRITEMODE_A("WRITETHROUGH"),.WRITEMODE_B("WRITETHROUGH"),.INIT_00(256'd0)) u_ram(
 .clka(clk),.addra(11'd0),.doa(q[15:0]),.dia(din[15:0]),.bytea(1'b0),.bytewea(1'b0),
 .csa(!rst),.wea(1'b1),.rsta(clear_output),.ocea(1'b1),
 .clkb(clk),.addrb(11'd1024),.dob(upper),.dib({5'd0,din[26:16]}),.byteb(1'b0),.byteweb(1'b0),
 .csb(!rst),.web(1'b1),.rstb(clear_output),.oceb(1'b1));
`endif
endmodule
'''.replace('NAME',name)

def add(s,name,clk,pixel):
    marker='    wire [26:0] resource_pixel;\n'
    return s.replace('    reg [23:0]',marker+f'    {name} u_pixel_pipe(.clk({clk}),.rst(rst),.din({{hs,vs,de,{pixel}}}),.q(resource_pixel));\n    reg [23:0]',1)

clock=a.destination/'rtl/ui/clock_overlay.v'
if not a.clock_only:
    base=Path(__file__).resolve().parents[2]/'build/resource-v1/base/render'
    clock.write_bytes((base/'rtl/ui/clock_overlay.v').read_bytes())
    (a.destination/'rtl/ui/font_rom.v').write_bytes((base/'rtl/ui/font_rom.v').read_bytes())
    core=a.destination/'rtl/render_core.v'
    # The original formatter consumes already frame-committed clock fields.
    if not core.exists():core=a.destination/'rtl/core/render_core.v'
    s=core.read_text(encoding='utf-8-sig')
    assert '#(.FRAME_DIGITS(1))' in s
    core.write_text(s.replace('#(.FRAME_DIGITS(1))',''),encoding='utf-8')
s=clock.read_text(encoding='utf-8-sig')
assert 'reg [23:0] rgb_a,rgb_b;reg [1:0] hp,vp,dp;' in s
s=s.replace('reg [23:0] rgb_a,rgb_b;reg [1:0] hp,vp,dp;',
'''wire [26:0] resource_pixel;
    wire [23:0] rgb_b=resource_pixel[23:0];
    resource_clock_pixel_pipe2 u_pixel_pipe(.clk(clk),.rst(rst),.din({hs,vs,de,rgb_in}),.q(resource_pixel));''')
s=s.replace('rgb_a<=0;rgb_b<=0;hp<=0;vp<=0;dp<=0;','')
s=s.replace('rgb_a<=rgb_in;rgb_b<=rgb_a;hp<={hp[0],hs};vp<={vp[0],vs};dp<={dp[0],de};','')
for x,n in [('hp',26),('vp',25),('dp',24)]:s=s.replace(x+'[1]',f'resource_pixel[{n}]')
clock.write_text(s+helper('resource_clock_pixel_pipe2'),encoding='utf-8')
if not a.clock_only:
    text=a.destination/'rtl/ui/text_osd_overlay.v'
    s=text.read_text(encoding='utf-8-sig')
    s=s.replace('reg [23:0] rgb_a,rgb_b,rgb_c,rgb_d,glyph_bg_d;',
'''wire [26:0] resource_pixel;
    wire [23:0] rgb_b=resource_pixel[23:0];
    resource_text_pixel_pipe2 u_pixel_pipe(.clk(clk),.rst(rst),.din({hs,vs,de,pix_in}),.q(resource_pixel));
    reg [23:0] rgb_c,rgb_d,glyph_bg_d;''')
    s=s.replace('reg [3:0] hs_pipe,vs_pipe,de_pipe;','reg [1:0] hs_pipe,vs_pipe,de_pipe;')
    s=s.replace('rgb_a<=0;rgb_b<=0;','').replace('rgb_a<=pix_in;rgb_b<=rgb_a;','')
    for x,y,n in [('hs_pipe','hs',26),('vs_pipe','vs',25),('de_pipe','de',24)]:
        s=s.replace('{'+x+'[2:0],'+y+'}','{'+x+'[0],resource_pixel['+str(n)+']}').replace(x+'[3]',x+'[1]')
    text.write_text(s+helper('resource_text_pixel_pipe2'),encoding='utf-8')
    ui=a.destination/'rtl/ui/ui_text_overlay.v'
    s=ui.read_text(encoding='utf-8-sig')
    s=s.replace('reg [23:0] rgb_0,rgb_1,rgb_2;',
'''wire [26:0] resource_pixel;
    wire [23:0] rgb_1=resource_pixel[23:0];
    resource_ui_pixel_pipe2 u_pixel_pipe(.clk(video_clk),.rst(rst),.din({hs,vs,de,pix_in}),.q(resource_pixel));
    reg [23:0] rgb_2;''')
    s=s.replace('reg [5:0] hp,vp,dp;','reg [3:0] hp,vp,dp;')
    s=s.replace('rgb_0<=0;rgb_1<=0;','').replace('rgb_0<=pix_in;rgb_1<=rgb_0;','')
    for x,y,n in [('hp','hs',26),('vp','vs',25),('dp','de',24)]:
        s=s.replace('{'+x+'[4:0],'+y+'}','{'+x+'[2:0],resource_pixel['+str(n)+']}').replace(x+'[5]',x+'[3]')
    ui.write_text(s+helper('resource_ui_pixel_pipe2'),encoding='utf-8')
