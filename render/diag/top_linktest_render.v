`include "../rtl/pkg/board_link.vh"
module top_linktest_render(
 input wire sys_clk,sys_rst_n,input wire rgmii_rxc,rgmii_rx_ctl,input wire [3:0]rgmii_rxd,
 output wire rgmii_txc,rgmii_tx_ctl,output wire [3:0]rgmii_txd,output wire mdc,inout wire mdio,
 output wire LED1,DBG_LINK_UP,DBG_ERROR,
 output wire [31:0]DBG_TX_FRAMES,DBG_RX_FRAMES,DBG_FCS_ERRORS,DBG_PATTERN_ERRORS,DBG_LENGTH_ERRORS,DBG_SEQUENCE_GAPS,
 output wire [41:0]DBG_TX_BYTES,DBG_RX_BYTES
);
 wire clk,tx_clk,mem_sft,tx_clk_90,lock,board_rst,rst,rx_clk,phy_ok;
 wire [7:0]tx_data,rx_data;wire tx_valid,tx_ack,rx_valid,rx_good,rx_bad;
 board_sys_pll u_sys_pll(.refclk(sys_clk),.reset(1'b0),.extlock(lock),.clk0_out(clk),.clk1_out(tx_clk),.clk2_out(mem_sft),.clk3_out(tx_clk_90));
 board_reset u_reset_hold(.clk(sys_clk),.rst_n(sys_rst_n),.locked(lock),.rst(board_rst));
 reset_sync u_bus_reset(.clk(clk),.rst_in(board_rst),.rst_out(rst));
 db_ethernet #(.LOCAL_MAC(`DB_MAC_RENDER))u_ethernet(
  .rst(rst),.tx_clk(tx_clk),.tx_clk_90(tx_clk_90),.bus_clk(clk),.tx_data(tx_data),.tx_valid(tx_valid),.tx_ack(tx_ack),
  .rx_clk(rx_clk),.rx_data(rx_data),.rx_valid(rx_valid),.rx_good(rx_good),.rx_bad(rx_bad),.phy_ok(phy_ok),
  .rgmii_rxc(rgmii_rxc),.rgmii_rx_ctl(rgmii_rx_ctl),.rgmii_rxd(rgmii_rxd),
  .rgmii_txc(rgmii_txc),.rgmii_tx_ctl(rgmii_tx_ctl),.rgmii_txd(rgmii_txd),.mdc(mdc),.mdio(mdio));
 db_prbs_mac #(.ROLE(2),.LOCAL_MAC(`DB_MAC_RENDER),.PEER_MAC(`DB_MAC_MEDIA))u_prbs(
  .rst(rst),.tx_clk(tx_clk),.rx_clk(rx_clk),.phy_ok(phy_ok),.tx_data(tx_data),.tx_valid(tx_valid),.tx_ack(tx_ack),
  .rx_data(rx_data),.rx_valid(rx_valid),.rx_good(rx_good),.rx_bad(rx_bad),
  .tx_frames(DBG_TX_FRAMES),.rx_frames(DBG_RX_FRAMES),.fcs_errors(DBG_FCS_ERRORS),.pattern_errors(DBG_PATTERN_ERRORS),
  .length_errors(DBG_LENGTH_ERRORS),.sequence_gaps(DBG_SEQUENCE_GAPS),.tx_payload_bytes(DBG_TX_BYTES),.rx_payload_bytes(DBG_RX_BYTES),.error_seen(DBG_ERROR));
 (* async_reg="true" *)reg error1,error2;
 always @(posedge clk or posedge rst)if(rst)begin error1<=0;error2<=0;end else begin error1<=DBG_ERROR;error2<=error1;end
 assign DBG_LINK_UP=phy_ok;assign LED1=phy_ok && !error2;
endmodule
