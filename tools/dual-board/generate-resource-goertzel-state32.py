"""Use two native BRAM32Ks for the original packed full-width state pair.

Four independent 16-bit halves cover all 50 default bits at the same address
and clock edge. G0/M0 read, G2/M2 write; no bank tags/copy scheduling. Restore
the exact frozen packed-state controller, including generic native fallback.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--state-reference',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args();snapshot(a.source,a.destination)
s=(a.state_reference/'rtl/fft/audio_fft_osd.v').read_text(encoding='utf-8-sig')
start=s.index('    EG_LOGIC_BRAM #(.DATA_WIDTH_A(2*STW)');end=s.index('\n\n',start)
legacy=s[start:end];assert '.dob());' in legacy
s=s[:start]+'''    generate if(2*STW<=64 && NBW==4)begin: packed_state32
      resource_goertzel_state32 #(.WIDTH(2*STW)) u_state(.clk(clk),.enable(we || rd_en),
        .write(we),.address(band),.din({wd2,wd1}),.q({s2q,s1q}));
    end else begin: legacy_state
'''+legacy+'''
    end endgenerate'''+s[end:]
s+='''
module resource_goertzel_state32 #(parameter WIDTH=50)(input wire clk,enable,write,
 input wire [3:0] address,input wire [WIDTH-1:0] din,output wire [WIDTH-1:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [WIDTH-1:0] mem[0:15],qr;integer i;
 initial for(i=0;i<16;i=i+1)mem[i]=0;
 assign q=qr;
 always @(posedge clk)if(enable)begin
   if(write)mem[address]<=din;else qr<=mem[address];
 end
`else
 wire [63:0] padded={{(64-WIDTH){1'b0}},din};
 wire [63:0] value;
 assign q=value[WIDTH-1:0];
 genvar g;
 generate for(g=0;g<2;g=g+1)begin:bank
   EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
    .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.INIT_00(256'd0),.INIT_40(256'd0)) u_ram(
    .clka(clk),.addra({7'd0,address}),.doa(value[g*32+:16]),.dia(padded[g*32+:16]),
    .bytea(1'b0),.bytewea(1'b0),.csa(enable),.wea(write),.rsta(1'b0),.ocea(1'b1),
    .clkb(clk),.addrb({7'b1000000,address}),.dob(value[g*32+16+:16]),.dib(padded[g*32+16+:16]),
    .byteb(1'b0),.byteweb(1'b0),.csb(enable),.web(write),.rstb(1'b0),.oceb(1'b1));
 end endgenerate
`endif
endmodule
'''
(a.destination/'rtl/fft/audio_fft_osd.v').write_text(s,encoding='utf-8')
