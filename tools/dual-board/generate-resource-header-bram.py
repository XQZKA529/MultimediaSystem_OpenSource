"""Move the media bus header shift/hold bank into seven BRAM32K pipelines.

Input capture occupies existing state 1, output capture existing state 7. Read
prefetch supplies the next word one clock earlier; publication/payload timing,
all eight queue slots, Gray synchronizers and management scratch stay intact.
Apply the optional implementation separately, preserving existing role-specific
logic. Render retains its original bank because its BRAM32K budget is full.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args()
paths=['rtl/link/db_mac_rx.v','rtl/link/db_link.v']
for board in ('media','render'):snapshot(a.source/board,a.destination/board)
for board in ('media','render'):
 s=(a.source/board/paths[0]).read_text(encoding='utf-8-sig')
 s=s.replace('    parameter [47:0] PEER_MAC=`DB_MAC_RENDER\n',
  '    parameter [47:0] PEER_MAC=`DB_MAC_RENDER,\n    parameter integer BRAM_HEADER=0\n')
 assert '.baddr({rp[2:0],header_ri})' in s
 s=s.replace('.baddr({rp[2:0],header_ri})','.baddr({rp[2:0],header_read_index})')
 decl='''    // Prefetch only changes the enabled BRAM implementation. Never read
     // management scratch word 7 after the last normal header word.
     wire [2:0] header_read_index=BRAM_HEADER ?
       (rd_state==0 ? 3'd0:(rd_state==7 && header_ri!=6 ? header_ri+1'b1:header_ri)):header_ri;
     wire [223:0] header_bram_q;
     wire [223:0] published_header=BRAM_HEADER ? header_bram_q:header_q;
     generate if(BRAM_HEADER) begin:embedded_header
       db_rx_header_pipe u_hold(.clk(bus_clk),.rst(rst),.capture(rd_state==1),.publish(rd_state==7),
         .din({header_bram_q[191:0],header_ram_q}),.q(header_bram_q));
     end else begin:original_header
       assign header_bram_q=224'd0;
     end endgenerate
 '''
 s=s.replace('    reg [3:0] rd_state;\n','')
 decl='    reg [3:0] rd_state;\n'+decl
 split=decl.index('    wire [223:0] header_bram_q;')
 s=s.replace('    wire [31:0] header_ram_q,management_q;',decl[:split]+'    wire [31:0] header_ram_q,management_q;')
 decl=decl[split:]
 s=s.replace('    assign pkt_header={header_q[223:216],`DB_MINOR,8\'d1,header_q[215:208],header_q[207:16],32\'d0};',
  decl+"    assign pkt_header={published_header[223:216],`DB_MINOR,8'd1,published_header[215:208],published_header[207:16],32'd0};")
 assert 'wire [223:0] published_header' in s
 helper='''
 module db_rx_header_pipe(input wire clk,rst,capture,publish,input wire [223:0] din,output wire [223:0] q);
 `ifdef DB_BEHAVIORAL_RAM
  reg [223:0] first,second;
  always @(posedge clk or posedge rst)
    if(rst) begin first<=0;second<=0;end
    else begin if(capture) first<=din;if(publish) second<=first;end
  assign q=second;
 `else
  reg ready;
  always @(posedge clk or posedge rst) if(rst) ready<=0;else if(capture) ready<=1;
  wire clear_output=rst || !ready;
 '''
 for bank in range(7):
  lo=bank*32
  helper+=f''' EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
  .REGMODE_A("OUTREG"),.REGMODE_B("OUTREG"),.SRMODE("ASYNC"),
  .WRITEMODE_A("WRITETHROUGH"),.WRITEMODE_B("WRITETHROUGH"),.INIT_00(256'd0)) u{bank}(
  .clka(clk),.addra(11'd0),.doa(q[{lo+15}:{lo}]),.dia(din[{lo+15}:{lo}]),.bytea(1'b0),.bytewea(1'b0),
  .csa(!rst),.wea(capture),.rsta(clear_output),.ocea(publish),
  .clkb(clk),.addrb(11'd1024),.dob(q[{lo+31}:{lo+16}]),.dib(din[{lo+31}:{lo+16}]),.byteb(1'b0),.byteweb(1'b0),
  .csb(!rst),.web(capture),.rstb(clear_output),.oceb(publish));
 '''
 helper+='`endif\nendmodule\n';s+=helper
 link=(a.source/board/paths[1]).read_text(encoding='utf-8-sig')
 old='db_mac_rx #(.LOCAL_MAC(LOCAL_MAC),.PEER_MAC(PEER_MAC))'
 assert old in link;link=link.replace(old,'db_mac_rx #(.LOCAL_MAC(LOCAL_MAC),.PEER_MAC(PEER_MAC),.BRAM_HEADER(ROLE==1))')
 (a.destination/board/paths[0]).write_text(s,encoding='utf-8')
 (a.destination/board/paths[1]).write_text(link,encoding='utf-8')
