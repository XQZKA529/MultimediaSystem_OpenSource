"""Generate exact ROM candidates from frozen Verilog, evaluated by ModelSim."""
from pathlib import Path
import re
from resource_experiment import snapshot
from resource_sim import simulate

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "build/resource-v1/base/render"
OUT = ROOT / "build/resource-v1"
ui = (BASE / "rtl/ui/ui_text_overlay.v").read_text(encoding="utf-8-sig")
em = (BASE / "rtl/emergency/emergency_overlay.v").read_text(encoding="utf-8-sig")
case_start = ui.index("                case(icon_0)", ui.index("if(page_0==1 && card_0"))
case_end = ui.index("                endcase", case_start) + len("                endcase")
icon_case = ui[case_start:case_end].replace("begin solid=1;tone=255;end", "icon_bit=1;")
glyph = re.search(r"    function \[4:0\] glyph_row;.*?    endfunction", em, re.S)[0]
work = OUT / "tables"
work.mkdir(parents=True, exist_ok=True)
emitter = work / "tb_emit.v"
emitter.write_text("""module tb_emit;
function icon_bit;
 input [2:0] icon_0;input [10:0] ix_0,iy_0;
 begin icon_bit=0;
""" + icon_case + "\n end endfunction\n" + glyph + """
integer f,k,x,y,c,r;
initial begin
 f=$fopen("icons.bits","w");
 for(k=0;k<7;k=k+1) for(y=0;y<96;y=y+1) for(x=0;x<96;x=x+1)
  $fdisplay(f,"%01x",icon_bit(k,x,y));
 $fclose(f);f=$fopen("glyph.hex","w");
 for(c=0;c<128;c=c+1) for(r=0;r<16;r=r+1) $fdisplay(f,"%04x",glyph_row(c,r));
 $fclose(f);$display("PASS original expressions evaluated exhaustively");$finish;
end endmodule
""", encoding="utf-8")
simulate(work, "tb_emit", [emitter])
bits = [int(v,16) for v in (work / "icons.bits").read_text().split()]
icon_words = [sum(bits[i+j] << j for j in range(16)) for i in range(0,len(bits),16)]
glyph_words = [int(v,16) for v in (work / "glyph.hex").read_text().split()]
coord_words = []
for v in range(512):
    rem,col=v,0
    for threshold,step in [(192,16),(96,8),(48,4),(24,2),(12,1)]:
        if rem>=threshold:rem-=threshold;col+=step
    coord_words.append((col<<4)|(rem&15))


def rom(name, words, aw):
    words=words+[0]*((1<<aw)-len(words))
    text=f"\n// Generated exact table. One synchronous read; no reset on ROM storage.\nmodule {name}(input wire clk,input wire [{aw-1}:0] addr,output wire [15:0] q);\n"
    text+="`ifdef DB_BEHAVIORAL_RAM\n"
    text+=f" reg [15:0] mem[0:{(1<<aw)-1}];reg [15:0] data;assign q=data;\n initial begin\n"
    text+=''.join(f"  mem[{i}]=16'h{w:04x};\n" for i,w in enumerate(words))
    text+=" end\n always @(posedge clk) data<=mem[addr];\n`else\n"
    banks=(len(words)+2047)//2048
    for bank in range(banks):
        text+=f" wire [15:0] q{bank};\n EG_PHY_BRAM32K #( .MODE(\"DP16K\"),.DATA_WIDTH_A(\"16\"),.DATA_WIDTH_B(\"16\"),.REGMODE_A(\"NOREG\"),.REGMODE_B(\"NOREG\"),\n"
        part=words[bank*2048:(bank+1)*2048]+[0]*max(0,2048-len(words[bank*2048:(bank+1)*2048]))
        for i in range(128):
            value=sum(part[i*16+j]<<(16*j) for j in range(16))
            text+=f"  .INIT_{i:02X}(256'h{value:064x})"+(",\n" if i<127 else "\n")
        address="addr[10:0]" if aw>=11 else f"{{{11-aw}'d0,addr}}"
        text+=f") u{bank}(.clka(clk),.addra({address}),.doa(q{bank}),.dia(16'd0),.bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(1'b0),.rsta(1'b0),.ocea(1'b1),\n .clkb(clk),.addrb(11'd0),.dob(),.dib(16'd0),.byteb(1'b0),.byteweb(1'b0),.csb(1'b0),.web(1'b0),.rstb(1'b0),.oceb(1'b1));\n"
    if banks==1:text+=" assign q=q0;\n"
    else:text+=" reg bank_q;always @(posedge clk) bank_q<=addr[11];assign q=bank_q ? q1:q0;\n"
    return text+"`endif\nendmodule\n"


def icons(source):
    start=source.index("                case(icon_0)",source.index("if(page_0==1 && card_0"))
    end=source.index("                endcase",start)+len("                endcase")
    source=source[:start]+"                if(icon_bit_q) begin solid=1;tone=255;end"+source[end:]
    start=source.index("    function icon;");end=source.index("    endfunction",start)+len("    endfunction")
    source=source[:start]+source[end:]
    decl="""    // Pre-read from combinational map, so ROM output matches ix_0/iy_0.
    wire [2:0] icon_table_kind=icon_kind==7 ? 3'd4:icon_kind;
    wire [11:0] icon_address=({9'd0,icon_table_kind}<<9)+({9'd0,icon_table_kind}<<6)
        +({5'd0,iy[6:0]}<<2)+({5'd0,iy[6:0]}<<1)+{9'd0,ix[6:4]};
    wire [15:0] icon_word;reg [3:0] icon_column_q;reg icon_in_bounds_q;
    always @(posedge video_clk) begin icon_column_q<=ix[3:0];icon_in_bounds_q<=ix<96 && iy<96;end
    wire icon_bit_q=icon_in_bounds_q && icon_word[icon_column_q];
    resource_icon_rom u_icon_rom(.clk(video_clk),.addr(icon_address),.q(icon_word));
"""
    source=source.replace("    reg [2:0] icon_0,value_0,page_0;",decl+"    reg [2:0] icon_0,value_0,page_0;")
    return source+rom("resource_icon_rom",icon_words,12)


def coordinates(source):
    start=source.index("    function [4:0] cell_index;");end=source.index("    endfunction",start)+len("    endfunction")
    source=source[:start]+source[end:]
    source=source.replace("reg [4:0] col_1;", "wire [15:0] coord_q;wire [4:0] col_1=coord_q[8:4];\n    resource_ui_coord_rom u_coord_rom(.clk(video_clk),.addr(tx_0),.q(coord_q));")
    source=source.replace("col_1<=0;", "").replace("col_1<=cell_index(tx_0);", "")
    return source+rom("resource_ui_coord_rom",coord_words,9)


def emergency(source):
    source=source.replace(glyph, "")
    source=source.replace("reg [4:0] glyph2;", "wire [15:0] glyph_word;wire [4:0] glyph2=glyph_word[4:0];\n    resource_emergency_rom u_glyph_rom(.clk(clk),.addr({character1[6:0],text_y1[4:1]}),.q(glyph_word));")
    source=source.replace("glyph2<=0;", "").replace("glyph2<=glyph_row(character1,text_y1[4:1]);", "")
    return source+rom("resource_emergency_rom",glyph_words,11)


for name,change in [("render_icons",icons),("render_coord",coordinates),("render_glyph",None)]:
    dest=OUT/name/"render";snapshot(BASE,dest)
    if change:(dest/"rtl/ui/ui_text_overlay.v").write_text(change(ui),encoding="utf-8")
    else:(dest/"rtl/emergency/emergency_overlay.v").write_text(emergency(em),encoding="utf-8")

dest=OUT/"render_goertzel"/"render";snapshot(BASE,dest)
p=dest/"rtl/fft/audio_fft_osd.v";source=p.read_text(encoding="utf-8-sig")
source=source.replace("reg signed [STW-1:0]  s1mem [0:NBANDS-1];", "// Packed state uses three BRAM9K lanes instead of distributed state RAM.")
source=source.replace("reg signed [STW-1:0]  s2mem [0:NBANDS-1];", "")
source=source.replace("reg signed [STW-1:0]  s1q, s2q;", "wire signed [STW-1:0]  s1q, s2q;")
start=source.index("    always @(posedge clk) begin\n        if (we)    begin s1mem")
end=source.index("    end",start)+len("    end")
source=source[:start]+"""    EG_LOGIC_BRAM #(.DATA_WIDTH_A(2*STW),.DATA_WIDTH_B(2*STW),
        .ADDR_WIDTH_A(NBW),.ADDR_WIDTH_B(NBW),.MODE("DP"),.IMPLEMENT("9K"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL")) u_state_ram(
        .clka(clk),.cea(we || rd_en),.ocea(1'b1),.rsta(1'b0),.wea(we),.bea(1'b1),
        .addra(band),.dia({wd2,wd1}),.doa({s2q,s1q}),
        .clkb(clk),.ceb(1'b0),.oceb(1'b1),.rstb(1'b0),.web(1'b0),.beb(1'b1),
        .addrb({NBW{1'b0}}),.dib({(2*STW){1'b0}}),.dob());
"""+source[end:]
p.write_text(source,encoding="utf-8")
