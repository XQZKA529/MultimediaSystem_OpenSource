"""Pack browser constants and the existing menu table into one dual-port BRAM32K.

Keep the menu's registered address and blank pipeline; browser reads use the
other port in the existing CHAR_RD/WAIT stages. No arbitration or added cycles.
Input is the independently verified browser-static9 candidate.
"""
import argparse
from pathlib import Path
import re
from resource_experiment import snapshot
from resource_rom import rom
from resource_sim import simulate

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True)
a=p.parse_args()
snapshot(a.source,a.destination)
file=a.destination/'rtl/ui/file_browser.v'
s=file.read_text(encoding='utf-8-sig')
main,old=s.split('\nmodule resource_browser_characters(',1)
browser=[32]*1024
matches=re.findall(r"mem\[(\d+)\]=8'd(\d+);",old)
assert len(matches)==1024
for n,v in matches: browser[int(n)]=int(v)
menu=(a.source/'rtl/ui/settings_menu_text_rom.v').read_text(encoding='utf-8-sig')
menu_words=[32]*1024
for n,v in re.findall(r"rom\[(\d+)\]=8'd(\d+);",menu):menu_words[int(n)]=int(v)
declarations="""    wire [7:0] browser_static_char;
    wire [9:0] browser_static_address=line_is_status ? {1'b0,status_kind,draw_i[4:0]}:{5'b10000,draw_i[4:0]};
"""
assert main.count(declarations)==1
main=main.replace(declarations,'').replace('    resource_browser_characters u_browser_characters(.clk(clk),.addr(browser_static_address),.q(browser_static_char));\n','')
main=main.replace('    wire [7:0] menu_rom_char;',declarations+'    wire [7:0] menu_rom_char;')
main=main.replace('settings_menu_text_rom u_menu_text','resource_browser_menu_rom u_menu_text')
assert main.count('.data(menu_rom_char));')==1
main=main.replace('.data(menu_rom_char));','.data(menu_rom_char),.browser_address(browser_static_address),.browser_data(browser_static_char));')
prefix=menu.split('`ifdef DB_BEHAVIORAL_RAM')[0]
prefix=prefix.replace('module settings_menu_text_rom(', 'module resource_browser_menu_rom(')
prefix=prefix.replace('output wire [7:0] data);','output wire [7:0] data,input wire [9:0] browser_address,output wire [7:0] browser_data);')
helper=prefix+"""
 wire [15:0] qa,qb;
 resource_browser_shared_characters u_shared(.clk(clk),.addr(address),.addr_b(browser_address),.q(qa),.q_b(qb));
 assign data=status_blank ? 8'd32:qa[7:0];
 assign browser_data=qb[15:8];
endmodule
"""
words=[m|(b<<8) for m,b in zip(menu_words,browser)]
file.write_text(main+helper+rom('resource_browser_shared_characters',words,10),encoding='utf-8')
work=a.destination.parent/'browser-menu-rom-equivalence';work.mkdir()
original=(a.reference/'rtl/ui/file_browser.v').read_text(encoding='utf-8-sig')
functions='\n'.join(re.search(r'    function \[7:0\] '+name+r';.*?    endfunction',original,re.S)[0] for name in ('status_char','prefix_char'))
constants='\n'.join(re.findall(r'^\s*localparam[^\n]*\bST_[^\n]*',original,re.M))
initial='\n'.join(f"menu[{i}]=8'd{v};" for i,v in enumerate(menu_words))
tb=work/'tb_shared.v'
tb.write_text('module tb_shared;\n'+constants+'\n'+functions+"""
reg clk=0;always #5 clk=~clk;
reg [9:0] a,b;wire [15:0] qa,qb;reg [7:0] menu[0:1023];integer n;
wire [7:0] new_menu,new_browser,old_menu;
reg [2:0] page;reg [1:0] mode;reg [3:0] row;reg [4:0] col;
resource_browser_shared_characters raw(.clk(clk),.addr(a),.addr_b(b),.q(qa),.q_b(qb));
resource_browser_menu_rom mapped(.clk(clk),.page(page),.mode(mode),.row(row),.col(col),.data(new_menu),.browser_address(b),.browser_data(new_browser));
settings_menu_text_rom golden(.clk(clk),.page(page),.mode(mode),.row(row),.col(col),.data(old_menu));
function [7:0] browser;input [9:0] addr;begin
 browser=addr<512 ? status_char(addr/32,addr%32,4'd0,4'd0,4'd0):addr<544 ? prefix_char(addr-512):8'd32;
end endfunction
initial begin
"""+initial+"""
 for(n=0;n<16384;n=n+1) begin
  @(negedge clk);a=n%1024;b=(n*73+157)%1024;
  {page,mode,row,col}=n;
  @(posedge clk);#1;
  if(qa!=={browser(a),menu[a]} || qb!=={browser(b),menu[b]}) $fatal(1,"Shared ROM address mismatch %0d",n);
  if(new_browser!==browser(b)) $fatal(1,"Browser port mismatch");
  if(n>0 && new_menu!==old_menu) $fatal(1,"Menu pipeline mismatch %0d",n);
 end
 $display("PASS 16384 shared-ROM/menu pipeline checks, all 1024 addresses on independent ports, all page/mode/row/column inputs");$finish;
end endmodule
""",encoding='utf-8')
for native in (False,True):
    simulate(work/('native' if native else 'behavioral'),'tb_shared',[file,a.destination/'rtl/ui/settings_menu_text_rom.v',tb],
             includes=[a.destination/'rtl',a.destination/'rtl/ui'],native=native,
             defines=[] if native else ['DB_BEHAVIORAL_RAM'])
