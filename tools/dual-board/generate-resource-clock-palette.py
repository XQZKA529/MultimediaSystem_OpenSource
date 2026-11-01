"""Absorb the final CLOCK RGB register/white blend in two dual-port BRAM9Ks."""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/ui/clock_overlay.v';s=f.read_text(encoding='utf-8-sig')
assert 'output reg [23:0] rgb_out' in s
s=s.replace('output reg [23:0] rgb_out','output wire [23:0] rgb_out')
start=s.index('    function [7:0] clock_blend_channel;');end=s.index('    endfunction',start)+len('    endfunction')
s=s[:start]+s[end:]
s=s.replace('de_out<=0;rgb_out<=0;','de_out<=0;')
start=s.index('rgb_out<=rgb_b;');end=s.index('\n        end\n    end\nendmodule',start)
s=s[:start]+s[end:]
insert='''
    reg [23:0] palette_src;
    reg [1:0] palette_alpha;
    always @(*) begin
      palette_src=rgb_b;palette_alpha=0;
      if(dp[1] && panel_b) begin
        if(border_b) palette_src=24'h949494;
        else if(text_b) begin palette_src=background;palette_alpha=font_alpha;end
        else palette_src=glass(rgb_b);
      end
    end
    wire [23:0] palette_rgb;
    reg palette_valid;
    always @(posedge clk or posedge rst) if(rst) palette_valid<=0;else palette_valid<=1;
    assign rgb_out=palette_valid ? palette_rgb:24'd0;
    resource_clock_palette u_rg(.clk(clk),.a({palette_alpha,palette_src[23:16]}),
      .b({palette_alpha,palette_src[15:8]}),.qa(palette_rgb[23:16]),.qb(palette_rgb[15:8]));
    resource_clock_palette u_b(.clk(clk),.a({palette_alpha,palette_src[7:0]}),
      .b(10'd0),.qa(palette_rgb[7:0]),.qb());
'''
s=s.replace('\nendmodule',insert+'\nendmodule',1)
words=[]
for alpha in range(4):
 for src in range(256):words.append([src,(3*src+255)//4,(src+765)//4,255][alpha])
helper='''
module resource_clock_palette(input wire clk,input wire [9:0] a,b,output wire [7:0] qa,qb);
`ifdef DB_BEHAVIORAL_RAM
reg [7:0] mem[0:1023],ra,rb;assign qa=ra;assign qb=rb;
initial begin
'''+''.join(f"mem[{i}]=8'd{v};\n" for i,v in enumerate(words))+'''end
always @(posedge clk) begin ra<=mem[a];rb<=mem[b];end
`else
wire [8:0] ra,rb;assign qa=ra[7:0];assign qb=rb[7:0];
EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),.GSR("DISABLE"),
'''
for i in range(32):
 val=sum(words[i*32+j]<<(8*j) for j in range(32))
 helper+=f".INIT_{i:02X}(256'h{val:064x})"+(',\n' if i<31 else ') u_rom(\n')
helper+='''.clka(clk),.cea(1'b1),.ocea(1'b1),.rsta(1'b0),.wea(1'b0),.csa(3'b111),.addra({a,3'b000}),.dia(9'd0),.doa(ra),
.clkb(clk),.ceb(1'b1),.oceb(1'b1),.rstb(1'b0),.web(1'b0),.csb(3'b111),.addrb({b,3'b000}),.dib(9'd0),.dob(rb));
`endif
endmodule
'''
f.write_text(s+helper,encoding='utf-8')
