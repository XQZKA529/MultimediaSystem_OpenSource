"""Absorb static editor glyphs and decimal count formatting into one ROM.

Port A replaces literal stage B; port B replaces registered decimal formatting.
Dynamic editor cursor/enable/count fields retain their previous sampling edges.
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
args=p.parse_args()
snapshot(args.source,args.destination)
s=(args.source/'rtl/ui/text_osd_overlay.v').read_text(encoding='utf-8-sig')
static=re.search(r'    function \[7:0\] static_char;.*?    endfunction',s,re.S)[0]
editor=re.search(r'    function \[7:0\] editor_char;.*?    endfunction',s,re.S)[0]
work=args.destination.parent/'format-generation';work.mkdir(parents=True,exist_ok=True)
tb=work/'emit.v'
tb.write_text('`include "pkg/text_osd_model.vh"\nmodule emit;\n'+static+editor+'''
integer n;initial begin
 for(n=0;n<512;n=n+1) $display("TABLE %0d %0d",n,editor_char(n/32,n%32,8'd32,7'd0,1'b0,1'b0,24'd0));
 $display("PASS exact editor table");$finish;
end endmodule
''',encoding='utf-8')
simulate(work,'emit',[tb],includes=[args.source/'rtl'])
words=[0]*2048
for line in (work/'simulate.log').read_text(errors='replace').splitlines():
    m=re.search(r'TABLE (\d+) (\d+)',line)
    if m:words[int(m[1])]=int(m[2])
for n in range(128):words[512+n]=(n//100)*256+((n//10)%10)*16+n%10
s=s.replace(static,'').replace(editor,'')
s=s.replace('    reg [23:0] count_characters;', '''    wire [15:0] literal_word,count_word;
    reg count_valid,literal_valid_b;
    wire [11:0] count_bcd=count_valid ? count_word[11:0]:12'd0;
    wire [23:0] count_characters={4'h3,count_bcd[11:8],4'h3,count_bcd[7:4],4'h3,count_bcd[3:0]};
    resource_text_format u_format(.clk(clk),.addr({2'd0,row_a,col_a[4:0]}),
        .addr_b({4'b0100,text_len}),.q(literal_word),.q_b(count_word));
    always @(posedge clk or posedge rst) if(rst) count_valid<=0;else count_valid<=1;''')
# Declare ROM address sources before use (Verilog 2001 does not allow an
# implicit wire to be redeclared as a register later in the same scope).
s=s.replace('    reg [`TEXT_OSD_LEN_W-1:0] col_a;reg [3:0] row_a;','')
s=s.replace('    wire [15:0] literal_word,count_word;', '    reg [`TEXT_OSD_LEN_W-1:0] col_a;reg [3:0] row_a;\n    wire [15:0] literal_word,count_word;')
s=s.replace('count_characters<={"0","0","0"};','')
s=re.sub(r'\s*count_characters\[(?:23:16|15:8|7:0)\]<=.*?;', '',s)
s=s.replace('reg read_text_b;reg [7:0] literal_b;', '''reg read_text_b;
    reg override_b;reg [7:0] override_char_b;
    wire [7:0] literal_b=literal_valid_b ? (override_b ? override_char_b:literal_word[7:0]):8'd32;
    wire count_cell=row_a==0 && col_a[4:0]>=24 && col_a[4:0]<=26;
    reg [7:0] dynamic_character;
    always @(*) begin
        dynamic_character=8'd32;
        if(count_cell) case(col_a[4:0])
            24:dynamic_character=count_characters[23:16];
            25:dynamic_character=count_characters[15:8];
            default:dynamic_character=count_characters[7:0];
        endcase
        else if(row_a==1) begin
            if(col_a[4:0]==0) dynamic_character=preview_start!=0 ? "<":"[";
            else if(col_a[4:0]==31) dynamic_character="]";
            else if(col_a[4:0]==visible_len+1'b1) dynamic_character="_";
        end else if(row_a==2) dynamic_character=col_a[4:0]==7 ? "N":" ";
    end''')
s=s.replace('literal_b<=32;', 'literal_valid_b<=0;override_b<=0;override_char_b<=32;')
s=s.replace('literal_b<=txt_a ? editor_char(row_a,col_a[4:0],8\'d32,visible_len,preview_start!=0,osd_enable,count_characters):8\'d32;', '''literal_valid_b<=txt_a;
            override_b<=count_cell || row_a==1 || (row_a==2 && osd_enable && (col_a[4:0]==7 || col_a[4:0]==8));
            override_char_b<=dynamic_character;''')
assert 'editor_char(' not in s and 'count_characters[' not in s[s.index('always @(posedge clk or posedge rst) begin',s.index('localparam')):s.index('    wire line=')]
(args.destination/'rtl/ui/text_osd_overlay.v').write_text(s+rom('resource_text_format',words,11),encoding='utf-8')
