"""Use two remaining DSP input/output registers for existing alarm stream stages."""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
ui=(a.source/'rtl/ui/ui_text_overlay.v').read_text(encoding='utf-8-sig')
helper=re.search(r'module resource_ui_dsp_pipe2\b.*?\nendmodule',ui,re.S)[0]
helper=helper.replace('resource_ui_dsp_pipe2','resource_emergency_dsp_pipe2').replace('[26:0]','[28:0]')
helper=helper.replace("{9'd0,din[26:18]}","{7'd0,din[28:18]}").replace('q[26:18]=product1[8:0]', 'q[28:18]=product1[10:0]')
f=a.destination/'rtl/emergency/emergency_overlay.v';s=f.read_text(encoding='utf-8-sig')
assert 'reg combined1,active1,hs1,vs1,de1;' in s
s=s.replace('reg combined1,active1,hs1,vs1,de1;', 'reg combined1;\n    wire [28:0] resource_pixel;')
s=s.replace('    reg text_bound1;','').replace('    reg [23:0] rgb1;','')
s=s.replace('reg text_bound2,active2,hs2,vs2,de2;', '''wire text_bound2=resource_pixel[27],active2=resource_pixel[28];
    wire hs2=resource_pixel[26],vs2=resource_pixel[25],de2=resource_pixel[24];''')
s=s.replace('reg [23:0] rgb2;', 'wire [23:0] rgb2=resource_pixel[23:0];')
for name in ('text_bound1','active1','hs1','vs1','de1','rgb1','text_bound2','active2','hs2','vs2','de2','rgb2'):
 assert len(re.findall(r'\b'+name+r'\s*<=',s))==2,name
 s=re.sub(r'\b'+name+r'\s*<=\s*[^;]+;','',s)
marker='    function [47:0] layout;';assert marker in s
s=s.replace(marker,'''    // InputREG + OutputREG replace exactly the original first two stages.
    resource_emergency_dsp_pipe2 u_pixel_pipe(.clk(clk),.rst(rst),
      .din({active,text_bound,hs,vs,de,rgb_in}),.q(resource_pixel));
'''+marker)
f.write_text(s+'\n'+helper+'\n',encoding='utf-8')
