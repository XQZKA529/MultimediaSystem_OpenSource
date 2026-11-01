"""Retain both full Goertzel states by swapping per-band history banks.

G0 reads S1, G1 reads S2 while multiplying S1, G2 commits new S1 into the old
S2 bank. The old S1 remains in place, so no S1->S2 copy is needed. Every main
phase, sample acceptance edge, product and magnitude/VS phase is unchanged.

Each band's two-bit tag is persistent across warm reset, like the original
unreset state RAM: 00=both zero, 01=only bank1 valid, 10/11=both valid with
bank0/1 current. M2 atomically clears the logical pair by clearing its tag;
there is no early clear that could corrupt a warm reset between M1 and M2.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
p.add_argument('--bram9',action='store_true',help='Rejected probe only: native DP8K does not allow the attempted 18-bit ports')
a=p.parse_args();snapshot(a.source,a.destination)
if a.bram9:print('REJECTED NATIVE PROBE: generated only for failure reproduction; do not synthesize or promote')
f=a.destination/'rtl/fft/audio_fft_osd.v';s=f.read_text(encoding='utf-8-sig')
s,n=re.subn(r'reg signed \[STW-1:0\]\s+s1h, s2h;', 'reg signed [STW-1:0] s1h;\n    wire signed [STW-1:0] s2h;',s);assert n==1
assert len(re.findall(r'\bs2h\s*<=',s))==2
s=re.sub(r'\bs2h\s*<=\s*[^;]+;','',s)
start=s.index('    EG_LOGIC_BRAM #(.DATA_WIDTH_A(2*STW)');end=s.index('\n\n',start)
legacy=s[start:end]
assert '.dob());' in legacy
block='''    localparam PACKED_HISTORY=(STW==25 && NBW==4 && NBANDS>=2 && NBANDS<=16);
    generate if(PACKED_HISTORY)begin: history
        wire [2*NBANDS-1:0] tags;
        wire [1:0] tag=tags[{band,1'b0} +:2];
        wire opposite=(ph==P_G1 || ph==P_G2);
        wire selected_bank=tag[0]^opposite;
        wire selected_valid=(ph==P_G2) || ((ph==P_G1) ? tag[1]:(|tag));
        // Word 32 is permanently zero, outside all writable band/bank words.
        wire [5:0] address=selected_valid ? {1'b0,selected_bank,band}:6'd32;
        wire enable=(ph==P_G0 || ph==P_G1 || ph==P_G2 || ph==P_M0);
        wire signed [24:0] state_q;
        assign s1q=state_q;assign s2q=state_q;assign s2h=state_q;
        resource_goertzel_history_ram u_ram(.clk(clk),.enable(enable),.write(ph==P_G2),
          .address(address),.din(wd1),.q(state_q));
        genvar g;
        for(g=0;g<NBANDS;g=g+1)begin: band_tag
            // No warm-reset input: the tag and its RAM words have one lifetime.
            reg [1:0] value=2'b00;
            assign tags[g*2+:2]=value;
            always @(posedge clk)if(band==g)begin
                if(ph==P_G2)value<={|value,!value[0]};
                else if(ph==P_M2)value<=2'b00;
            end
        end
    end else begin: legacy_state
        reg signed [STW-1:0] s2_registered;
        assign s2h=s2_registered;
        always @(posedge clk or posedge rst)
          if(rst)s2_registered<=0;else if(ph==P_G1)s2_registered<=s2q;
'''+legacy+'''
    end endgenerate'''
s=s[:start]+block+s[end:]
s+='''
// Two disjoint 16-bit port words implement one exact 25-bit synchronous word.
module resource_goertzel_history_ram(input wire clk,enable,write,
 input wire [5:0] address,input wire [24:0] din,output wire signed [24:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [24:0] mem[0:63];reg [24:0] held;integer i;
 initial for(i=0;i<64;i=i+1)mem[i]=0;
 always @(posedge clk)if(enable)begin
   if(write)mem[address]<=din;
   held<=mem[address];
 end
 assign q=held;
`else
 wire [31:0] padded={7'd0,din};wire [31:0] held;
 assign q=held[24:0];
 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
  .INIT_02(256'd0),.INIT_42(256'd0)) u_state(
  .clka(clk),.addra({5'd0,address}),.dia(padded[15:0]),.doa(held[15:0]),
  .bytea(1'b0),.bytewea(1'b0),.csa(enable),.wea(write),.rsta(1'b0),.ocea(1'b1),
  .clkb(clk),.addrb({1'b1,4'd0,address}),.dib(padded[31:16]),.dob(held[31:16]),
  .byteb(1'b0),.byteweb(1'b0),.csb(enable),.web(write),.rstb(1'b0),.oceb(1'b1));
`endif
endmodule
'''
if a.bram9:
 start=s.rindex('`else\n wire [31:0] padded=')
 end=s.index('`endif',start)
 s=s[:start]+'''`else
 wire [17:0] low,high;
 assign q={high[8:0],low[15:0]};
 // The 18-bit ports occupy disjoint physical halves. Both ports read or
 // write together; no logical read and write are simultaneous.
 EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("18"),.DATA_WIDTH_B("18"),.GSR("DISABLE"),
  .INIT_02(256'd0),.INIT_12(256'd0)) u_state(
  .clka(clk),.cea(enable),.ocea(1'b1),.rsta(1'b0),.wea(write),.csa(3'b111),
  .addra({3'd0,address,4'd0}),.dia({2'd0,din[15:0]}),.doa(low),
  .clkb(clk),.ceb(enable),.oceb(1'b1),.rstb(1'b0),.web(write),.csb(3'b111),
  .addrb({1'b1,2'd0,address,4'd0}),.dib({9'd0,din[24:16]}),.dob(high));
'''+s[end:]
f.write_text(s,encoding='utf-8')
