"""Keep full 32-bit protocol sequence state in spare native DSP output registers.

Media maps both banks (12 DSPs); render maps receive state only (6 DSPs).
Session/disconnect clears retain priority over same-cycle sequence advancement.
No descriptor format, buffer capacity, CDC register or packet timing changes.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);p.add_argument('--multiply-clear',action='store_true');a=p.parse_args()
for board in ('media','render'):
 snapshot(a.source/board,a.destination/board)
 f=a.destination/board/'rtl/link/db_link.v';s=f.read_text(encoding='utf-8-sig')
 s=s.replace('reg [31:0] next_seq[0:2],expect_seq[0:2];','wire [31:0] next_seq[0:2],expect_seq[0:2];')
 loop='for(i=0;i<3;i=i+1) begin next_seq[i]<=0;expect_seq[i]<=0;end'
 assert s.count(loop)==3;s=s.replace(loop,'')
 old="if(receive_advance && !session_reset) expect_seq[delivery_ch]<=delivery_seq+1'b1;"
 assert old in s;s=s.replace(old,'')
 old="next_seq[tx_channel]<=next_seq[tx_channel]+1'b1;"
 assert old in s;s=s.replace(old,'')
 disconnected='!phy_ok || (link_up && peer_expired)' if board=='media' else '!phy_ok || (link_up && peer_age>=TIMEOUT_CYCLES)'
 assert 'if('+disconnected+') begin' in s
 logic='''
    wire sequence_clear=(DISCONNECTED) ||
      (m_valid && m_ready && hello_accept && (!link_up || m_change));
    genvar sequence_channel;
    generate for(sequence_channel=0;sequence_channel<3;sequence_channel=sequence_channel+1)begin:sequence_bank
      wire tx_advance=tx_meta_valid && tx_meta_ready && tx_channel==sequence_channel;
      wire rx_advance=receive_advance && !session_reset && delivery_ch==sequence_channel;
      wire [31:0] tx_next=sequence_clear ? 32'd0:next_seq[sequence_channel]+32'd1;
      wire [31:0] rx_next=sequence_clear ? 32'd0:delivery_seq+32'd1;
      if(ROLE==1)begin:transmit_dsp
        db_sequence_hold u_tx(.clk(clk),.rst(rst),.enable(sequence_clear || tx_advance),
          .din(tx_next),.q(next_seq[sequence_channel]));
      end else begin:transmit_ff
        reg [31:0] held;
        always @(posedge clk or posedge rst)
          if(rst)held<=0;else if(sequence_clear || tx_advance)held<=tx_next;
        assign next_seq[sequence_channel]=held;
      end
      db_sequence_hold u_rx(.clk(clk),.rst(rst),.enable(sequence_clear || rx_advance),
        .din(rx_next),.q(expect_seq[sequence_channel]));
    end endgenerate
'''.replace('DISCONNECTED',disconnected)
 i=s.rindex('endmodule');s=s[:i]+logic+s[i:]
 s+='''
module db_sequence_hold(input wire clk,rst,enable,input wire [31:0] din,output wire [31:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [31:0] held;
 always @(posedge clk or posedge rst)if(rst)held<=0;else if(enable)held<=din;
 assign q=held;
`else
 wire [35:0] low,high;
 assign q={high[13:0],low[17:0]};
 EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("ENABLE"),
  .SRMODE("ASYNC"),.MODE("MULT18X18C")) u_low(
  .clk(clk),.a(din[17:0]),.b(18'd1),.acin(18'd0),.bcin(18'd0),
  .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
  .cea(1'b0),.ceb(1'b0),.cepd(enable),.rstan(1'b1),.rstbn(1'b1),.rstpdn(!rst),.acout(),.bcout(),.p(low));
 EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("ENABLE"),
  .SRMODE("ASYNC"),.MODE("MULT18X18C")) u_high(
  .clk(clk),.a({4'd0,din[31:18]}),.b(18'd1),.acin(18'd0),.bcin(18'd0),
  .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
  .cea(1'b0),.ceb(1'b0),.cepd(enable),.rstan(1'b1),.rstbn(1'b1),.rstpdn(!rst),.acout(),.bcout(),.p(high));
`endif
endmodule
'''
 if a.multiply_clear:
  s=s.replace("sequence_clear ? 32'd0:next_seq[sequence_channel]+32'd1", "next_seq[sequence_channel]+32'd1")
  s=s.replace("sequence_clear ? 32'd0:delivery_seq+32'd1", "delivery_seq+32'd1")
  s=s.replace('if(rst)held<=0;else if(sequence_clear || tx_advance)held<=tx_next;',
    'if(rst)held<=0;else if(sequence_clear)held<=0;else if(tx_advance)held<=tx_next;')
  s=s.replace('.rst(rst),.enable(sequence_clear', '.rst(rst),.clear(sequence_clear),.enable(sequence_clear')
  s=s.replace('input wire clk,rst,enable,', 'input wire clk,rst,clear,enable,')
  s=s.replace('else if(enable)held<=din;', "else if(enable)held<=clear ? 32'd0:din;")
  s=s.replace(".b(18'd1)",".b({17'd0,!clear})")
 f.write_text(s,encoding='utf-8')
