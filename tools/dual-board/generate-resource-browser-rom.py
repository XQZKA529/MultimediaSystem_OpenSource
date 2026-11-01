"""Map actually used browser status/prefix cases to one synchronous BRAM9K.

Existing D_CHAR_RD/WAIT cover the ROM read. No state, handshake or UI commit
latency changes. TXT status keeps its existing independent menu ROM lookup.
"""
import argparse
from pathlib import Path
import re
from resource_experiment import snapshot
from resource_rom import byte_rom9
from resource_sim import simulate

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
args=p.parse_args()
snapshot(args.source,args.destination)
file=args.destination/'rtl/ui/file_browser.v'
s=file.read_text(encoding='utf-8-sig')
functions=[re.search(r'    function \[7:0\] '+name+r';.*?    endfunction',s,re.S)[0]
           for name in ('status_char','prefix_char')]
constants='\n'.join(re.findall(r'^\s*localparam[^\n]*\bST_[^\n]*',s,re.M))
work=args.destination.parent/'browser-rom-generation';work.mkdir(parents=True,exist_ok=True)
tb=work/'emit.v'
tb.write_text('module emit;\n'+constants+'\n'+'\n'.join(functions)+'''
integer n;initial begin
 for(n=0;n<512;n=n+1) $display("TABLE %0d %0d",n,status_char(n/32,n%32,4'd0,4'd0,4'd0));
 for(n=0;n<32;n=n+1) $display("TABLE %0d %0d",512+n,prefix_char(n));
 $display("PASS exact browser table");$finish;
end endmodule
''',encoding='utf-8')
simulate(work,'emit',[tb])
words=[32]*1024;seen=set()
for line in (work/'simulate.log').read_text(errors='replace').splitlines():
    m=re.search(r'TABLE (\d+) (\d+)',line)
    if m:words[int(m[1])]=int(m[2]);seen.add(int(m[1]))
assert len(seen)==544
for function in functions:s=s.replace(function,'')
s=s.replace('    reg [7:0] line_byte;', '''    wire [7:0] browser_static_char;
    wire [9:0] browser_static_address=line_is_status ? {1'b0,status_kind,draw_i[4:0]}:{5'b10000,draw_i[4:0]};
    resource_browser_characters u_browser_characters(.clk(clk),.addr(browser_static_address),.q(browser_static_char));
    reg [7:0] line_byte;''')
s=s.replace("status_char(status_kind, draw_i[4:0], 4'd0, 4'd0, 4'd0)", 'browser_static_char')
s=s.replace('prefix_char(draw_i[4:0])','browser_static_char')
assert 'status_char(' not in s and 'prefix_char(' not in s
file.write_text(s+byte_rom9('resource_browser_characters',words),encoding='utf-8')
# Keep exact original table oracle for all 1024 physical addresses.
oracle=work/'tb_browser_rom.v'
oracle.write_text('module tb_browser_rom;\n'+constants+'\n'+'\n'.join(functions)+'''
reg clk=0;always #5 clk=~clk;reg [9:0] addr=0;wire [7:0] q;reg [7:0] expected;integer n;
resource_browser_characters dut(.clk(clk),.addr(addr),.q(q));
initial begin
 for(n=0;n<1024;n=n+1) begin
  @(negedge clk);addr=n;
  expected=n<512 ? status_char(n/32,n%32,4'd0,4'd0,4'd0):n<544 ? prefix_char(n-512):8'd32;
  @(posedge clk);#1;if(q!==expected) $fatal(1,"Browser ROM address %0d q=%h expected=%h",n,q,expected);
 end
 $display("PASS 1024 browser status/prefix ROM addresses");$finish;
end endmodule
''',encoding='utf-8')
for native in (False,True):
    simulate(work/('native' if native else 'behavioral'),'tb_browser_rom',[file,oracle],
             includes=[args.destination/'rtl',args.destination/'rtl/ui'],native=native,
             defines=[] if native else ['DB_BEHAVIORAL_RAM'])
