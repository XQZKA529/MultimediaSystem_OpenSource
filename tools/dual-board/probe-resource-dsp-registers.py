"""Check native DSP register semantics and actual EG4 routing before use.

Cascade outputs may have routing restrictions; a behavioral pass alone never
qualifies a register mapping. Each mode gets an isolated native physical probe.
"""
from pathlib import Path
import argparse,json,re,subprocess
from resource_sim import simulate,TD
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--tag',default='dsp-register-probe')
p.add_argument('--cascade-logic',action='store_true')
args=p.parse_args();OUT=ROOT/'build/resource-v1'/args.tag
for mode,latency in ([('cascade_logic',1)] if args.cascade_logic else [('cascade',1),('product1',1),('product2',2)]):
 w=OUT/mode;w.mkdir(parents=True,exist_ok=True)
 rtl='''module register_probe(input wire clk,rst_a,rst_b,en_a,en_b,
 input wire [35:0] din,output wire [35:0] q);
'''
 if mode.startswith('cascade'):
  rtl+='''EG_PHY_MULT18 #(.INPUTREGA("ENABLE"),.INPUTREGB("ENABLE"),.OUTPUTREG("DISABLE"),
 .SRMODE("ASYNC"),.MODE("MULT18X18C")) u_reg(
 .clk(clk),.a(din[17:0]),.b(din[35:18]),.acin(18'd0),.bcin(18'd0),
 .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
 .cea(en_a),.ceb(en_b),.cepd(1'b0),.rstan(!rst_a),.rstbn(!rst_b),.rstpdn(1'b1),
 .acout(q[17:0]),.bcout(q[35:18]),.p());
'''
 else:
  for n,reset,enable in [(0,'rst_a','en_a'),(1,'rst_b','en_b')]:
   rtl+=f'''wire [35:0] p{n};assign q[{n*18+17}:{n*18}]=p{n}[17:0];
EG_PHY_MULT18 #(.INPUTREGA("{'ENABLE' if latency==2 else 'DISABLE'}"),.INPUTREGB("DISABLE"),.OUTPUTREG("ENABLE"),
 .SRMODE("ASYNC"),.MODE("MULT18X18C")) u{n}(
 .clk(clk),.a(din[{n*18+17}:{n*18}]),.b(18'd1),.acin(18'd0),.bcin(18'd0),
 .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
 .cea({enable}),.ceb(1'b0),.cepd({enable}),.rstan(!{reset}),.rstbn(1'b1),.rstpdn(!{reset}),
 .acout(),.bcout(),.p(p{n}));
'''
 if mode=='cascade_logic':
  rtl=rtl.replace('input wire [35:0] din,','input wire [35:0] mask,input wire [35:0] din,')
  rtl=rtl.replace('EG_PHY_MULT18 #(',"wire [35:0] registered;assign q=registered ^ mask;\nEG_PHY_MULT18 #(",1)
  rtl=rtl.replace('.acout(q[17:0]),.bcout(q[35:18])','.acout(registered[17:0]),.bcout(registered[35:18])')
 rtl+='endmodule\n';(w/'probe.v').write_text(rtl,encoding='utf-8')
 tb='''module tb;
reg clk=0,rst_a=1,rst_b=1,en_a=0,en_b=0;always #5 clk=~clk;
reg [35:0] din=0;wire [35:0] q;
register_probe dut(.clk(clk),.rst_a(rst_a),.rst_b(rst_b),.en_a(en_a),.en_b(en_b),.din(din),.q(q));
reg [17:0] a1=0,a2=0,b1=0,b2=0;integer n,checks=0;
always @(posedge clk or posedge rst_a) if(rst_a)begin a1<=0;a2<=0;end
else if(en_a)begin a1<=din[17:0];a2<=a1;end
always @(posedge clk or posedge rst_b) if(rst_b)begin b1<=0;b2<=0;end
else if(en_b)begin b1<=din[35:18];b2<=b1;end
wire [35:0] expected='''+('{b1,a1}' if latency==1 else '{b2,a2}')+''';
always @(posedge clk or negedge clk)begin #1;
 if(q!==expected)$fatal(1,"Native DSP register differs q=%h expected=%h t=%t",q,expected,$time);
 checks=checks+1;
end
initial begin
repeat(4)@(negedge clk);rst_a=0;rst_b=0;
for(n=0;n<10000;n=n+1)begin
 @(negedge clk);din={$random,$random};en_a=$random;en_b=$random;
 if(n%71==50)begin rst_a=1;#2;rst_a=0;end
 if(n%113==70)begin rst_b=1;#2;rst_b=0;end
end
repeat(5)@(negedge clk);
$display("PASS exact native DSP registers %0d independent CE/reset/stability checks",checks);$finish;
end endmodule
'''
 if mode=='cascade_logic':
  tb=tb.replace('reg [35:0] din=0;','reg [35:0] mask=0;reg [35:0] din=0;')
  tb=tb.replace('register_probe dut(.clk(clk),','register_probe dut(.mask(mask),.clk(clk),')
  tb=tb.replace('wire [35:0] expected={b1,a1};','wire [35:0] expected={b1,a1} ^ mask;')
  tb=tb.replace('din={$random,$random};','din={$random,$random};mask={$random,$random};')
 (w/'tb.v').write_text(tb,encoding='utf-8')
 result=dict(mode=mode,latency=latency)
 try:
  simulate(w/'simulation','tb',[TD/'sim_release/eg4/eg_phy_mult18.v',w/'probe.v',w/'tb.v'],native=True)
  result['simulation_pass']=True
  run=w/'physical';run.mkdir(exist_ok=True)
  # Minimal project containing only the tested primitive and external pads.
  project=f'''<?xml version="1.0" encoding="UTF-8"?>
<Project Version="3" Minor="2" Path="{w.as_posix()}">
<Name>probe</Name><HardWare><Family>EG4</Family><Device>EG4S20BG256</Device><Speed/></HardWare>
<Source_Files><Verilog><File Path="probe.v"><FileInfo>
<Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&amp;R" Val="true"/>
<Attr Name="BelongTo" Val="design_1"/><Attr Name="CompileOrder" Val="1"/>
</FileInfo></File></Verilog></Source_Files>
<FileSets><FileSet Name="design_1" Type="DesignFiles"/><FileSet Name="constraint_1" Type="ConstrainFiles"/></FileSets>
<TOP_MODULE><LABEL>register_probe</LABEL><MODULE>register_probe</MODULE><CREATEINDEX>user</CREATEINDEX></TOP_MODULE>
<Property/><Device_Settings/><Configurations/><Runs/><Project_Settings/>
</Project>'''
  # Preserve all TD version/build metadata from a known valid local project.
  template=(ROOT/'media/MultimediaSystem_media.al').read_text(encoding='utf-8-sig')
  template=re.sub(r'(<Project\b[^>]*\bPath=")[^"]*',lambda m:m[1]+w.as_posix(),template,count=1)
  template=template.replace('<Name>MultimediaSystem_media</Name>','<Name>probe</Name>')
  files=re.search(r'<Source_Files>.*?</Source_Files>',project,re.S)[0]
  template=re.sub(r'<Source_Files>.*?</Source_Files>',lambda _:files,template,flags=re.S)
  template=template.replace('<LABEL>top_media</LABEL>','<LABEL>register_probe</LABEL>').replace(
      '<MODULE>top_media</MODULE>','<MODULE>register_probe</MODULE>')
  (w/'probe.al').write_text(template,encoding='utf-8')
  (run/'probe.sdc').write_text('create_clock -name probe_clk -period 10.000 [get_ports {clk}]\n',encoding='utf-8')
  cfg='''set ADCList [list]
set SDCList [list {probe.sdc}]
set area_option -packarea
set device_name eagle_s20.db
set package_name EG4S20BG256
set prj_name probe
set top_model_name register_probe
set run_type phy
set arr_filter false
set drHoldFix on
set synWildParams {gate map_mode area_prior rtl infer_fsm off route fix_hold on}
set start_step read_design
set end_step opt_route
'''
  (run/'settings.cfg').write_text(cfg,encoding='utf-8')
  (run/'entry.tcl').write_text(f'''if {{[catch {{
source ./settings.cfg
cd {{{w.as_posix()}}}
open_project probe.al
cd {{{run.as_posix()}}}
set singleRun 1
source {{{(ROOT/'media/build/MyFlow.tcl').as_posix()}}}
}} failure]}} {{puts "PROBE_FAILED: $failure"}}
exit
''',encoding='utf-8')
  with (run/'console.txt').open('w',encoding='utf-8') as output:
   process=subprocess.run([str(TD/'bin/td_commands_prompt.exe'),'entry.tcl'],cwd=run,
      stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,timeout=300)
  log=(run/'console.txt').read_text(errors='replace')
  result['route_complete']=(run/'.opt_route.end.f').exists() and not list(run.glob('*.error.f'))
  if (run/'probe_phy.area').exists():
   area=(run/'probe_phy.area').read_text()
   for field in ('lut','reg','dsp'):
    found=re.search(r'(?m)^#'+field+r'\s+(\d+)',area)
    if found:result[field]=int(found[1])
  result['usable']=result['route_complete'] and result.get('dsp',0)>0
  if not result['usable']:result['reason']='No complete native DSP mapping/routing; not qualified'
 except Exception as error:
  result['usable']=False;result['reason']=str(error)[-2000:]
 (w/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8');print(json.dumps(result))
