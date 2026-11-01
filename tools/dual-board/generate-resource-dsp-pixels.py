"""Move two existing pixel/sync stages into native DSP input/output registers.

No pixel latency changes. Unsigned multiplication by one preserves all bits;
independently reset native input/output registers replace two existing stages.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
p.add_argument('--clock-only',action='store_true')
p.add_argument('--pack-control',action='store_true',help='Use spare DSP operand bits for matching two-stage controls')
a=p.parse_args()
snapshot(a.source,a.destination)

def helper(name):
    result='\nmodule NAME(input wire clk,rst,input wire [26:0] din,output wire [26:0] q);\n`ifdef DB_BEHAVIORAL_RAM\n reg [26:0] first,second;\n always @(posedge clk or posedge rst)\n   if(rst) begin first<=0;second<=0;end\n   else begin first<=din;second<=first;end\n assign q=second;\n`else\n'.replace('NAME',name)
    for n in range(2):
        source='din[17:0]' if n==0 else "{9'd0,din[26:18]}"
        result+=f"wire [35:0] product{n};\n"
        result+=f"assign q[{17 if n==0 else 26}:{0 if n==0 else 18}]=product{n}[{17 if n==0 else 8}:0];\n"
        result+=f'''EG_PHY_MULT18 #(.INPUTREGA("ENABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("ENABLE"),
 .SRMODE("ASYNC"),.MODE("MULT18X18C")) u{n}(
 .clk(clk),.a({source}),.b(18'd1),.acin(18'd0),.bcin(18'd0),
 .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
 .cea(1'b1),.ceb(1'b0),.cepd(1'b1),.rstan(!rst),.rstbn(1'b1),.rstpdn(!rst),
 .acout(),.bcout(),.p(product{n}));
'''
    return result+'`endif\nendmodule\n'

clock=a.destination/'rtl/ui/clock_overlay.v'
s=clock.read_text(encoding='utf-8-sig')
assert 'reg [23:0] rgb_a,rgb_b;reg [1:0] hp,vp,dp;' in s
s=s.replace('reg [23:0] rgb_a,rgb_b;reg [1:0] hp,vp,dp;',
'''wire [26:0] resource_pixel;
    wire [23:0] rgb_b=resource_pixel[23:0];
    resource_clock_dsp_pipe2 u_pixel_pipe(.clk(clk),.rst(rst),.din({hs,vs,de,rgb_in}),.q(resource_pixel));''')
s=s.replace('rgb_a<=0;rgb_b<=0;hp<=0;vp<=0;dp<=0;','')
s=s.replace('rgb_a<=rgb_in;rgb_b<=rgb_a;hp<={hp[0],hs};vp<={vp[0],vs};dp<={dp[0],de};','')
for x,n in [('hp',26),('vp',25),('dp',24)]:s=s.replace(x+'[1]',f'resource_pixel[{n}]')
clock.write_text(s+helper('resource_clock_dsp_pipe2'),encoding='utf-8')
if not a.clock_only:
    text=a.destination/'rtl/ui/text_osd_overlay.v'
    s=text.read_text(encoding='utf-8-sig')
    s=s.replace('reg [23:0] rgb_a,rgb_b,rgb_c,rgb_d;',
'''wire [26:0] resource_pixel;
    wire [23:0] rgb_b=resource_pixel[23:0];
    resource_text_dsp_pipe2 u_pixel_pipe(.clk(clk),.rst(rst),.din({hs,vs,de,pix_in}),.q(resource_pixel));
    reg [23:0] rgb_c,rgb_d;''')
    s=s.replace('reg [3:0] hs_pipe,vs_pipe,de_pipe;','reg [1:0] hs_pipe,vs_pipe,de_pipe;')
    s=s.replace('rgb_a<=0;rgb_b<=0;','').replace('rgb_a<=pix_in;rgb_b<=rgb_a;','')
    for x,y,n in [('hs_pipe','hs',26),('vs_pipe','vs',25),('de_pipe','de',24)]:
        s=s.replace('{'+x+'[2:0],'+y+'}','{'+x+'[0],resource_pixel['+str(n)+']}').replace(x+'[3]',x+'[1]')
    text.write_text(s+helper('resource_text_dsp_pipe2'),encoding='utf-8')
    ui=a.destination/'rtl/ui/ui_text_overlay.v'
    s=ui.read_text(encoding='utf-8-sig')
    s=s.replace('reg [23:0] rgb_0,rgb_1,rgb_2;',
'''wire [26:0] resource_pixel;
    wire [23:0] rgb_1=resource_pixel[23:0];
    resource_ui_dsp_pipe2 u_pixel_pipe(.clk(video_clk),.rst(rst),.din({hs,vs,de,pix_in}),.q(resource_pixel));
    reg [23:0] rgb_2;''')
    s=s.replace('reg [5:0] hp,vp,dp;','reg [3:0] hp,vp,dp;')
    s=s.replace('rgb_0<=0;rgb_1<=0;','').replace('rgb_0<=pix_in;rgb_1<=rgb_0;','')
    for x,y,n in [('hp','hs',26),('vp','vs',25),('dp','de',24)]:
        s=s.replace('{'+x+'[4:0],'+y+'}','{'+x+'[2:0],resource_pixel['+str(n)+']}').replace(x+'[5]',x+'[3]')
    ui.write_text(s+helper('resource_ui_dsp_pipe2'),encoding='utf-8')

if a.pack_control:
    for file,extras in [
        ('clock_overlay.v',[('panel_a','panel_b','plate || card'),('text_a','text_b','text'),('high_a','high_b','highlight'),('border_a','border_b','border')]),
        ('text_osd_overlay.v',[('gx_a','gx_b','gx'),('gy_a','gy_b','gy')]),
        ('ui_text_overlay.v',[('row_0','row_1','row'),('ty_0','ty_1','ty')])]:
        f=a.destination/'rtl/ui'/file;s=f.read_text(encoding='utf-8')
        width=31 if file=='clock_overlay.v' else 35
        s=s.replace('[26:0]',f'[{width-1}:0]')
        s=s.replace("{9'd0,din[26:18]}","{"+str(36-width)+"'d0,din["+str(width-1)+":18]}")
        s=s.replace('q[26:18]=product1[8:0]',f'q[{width-1}:18]=product1[{width-19}:0]')
        # Original intermediate control names occur only in their pass-through
        # assignments; their second-stage value moves alongside the same RGB.
        inputs=','.join(item[2] for item in extras)
        s=s.replace('.din({hs,vs,de,', '.din({'+inputs+',hs,vs,de,')
        top,helper=s.split('module resource_'+('clock' if file=='clock_overlay.v' else 'text' if file=='text_osd_overlay.v' else 'ui')+'_dsp_pipe2',1)
        offset=width
        for first,second,value in extras:
            bits=1 if file=='clock_overlay.v' else 4
            offset-=bits
            # Rebuild the declaration, including an entirely removed list.
            import re
            def remove_declaration(match):
                remaining=[n.strip() for n in match[2].split(',') if n.strip() not in (first,second)]
                return match[1]+','.join(remaining)+';' if remaining else ''
            top=re.sub(r'(reg\s*(?:\[[^]]+\]\s*)?)([A-Za-z_][A-Za-z0-9_, ]*);',remove_declaration,top)
            for name in (first,second):top=top.replace(name+'<=0;','')
            top=top.replace(first+'<='+value+';','').replace(second+'<='+first+';','')
            top+='\n' if not top.endswith('\n') else ''
            # Must precede endmodule, so consumers never become implicit nets.
            declaration=f"    wire {'['+str(bits-1)+':0] ' if bits>1 else ''}{second}=resource_pixel[{offset+bits-1}:{offset}];\n"
            insertion=top.index(f'wire [{width-1}:0] resource_pixel;')+len(f'wire [{width-1}:0] resource_pixel;')
            top=top[:insertion]+declaration+top[insertion:]
        s=top+'module resource_'+('clock' if file=='clock_overlay.v' else 'text' if file=='text_osd_overlay.v' else 'ui')+'_dsp_pipe2'+helper
        assert all(first+'<=' not in s for first,_,_ in extras)
        f.write_text(s,encoding='utf-8')
