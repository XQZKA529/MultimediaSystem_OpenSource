`include "../pkg/board_link.vh"
module db_ethernet #(
    parameter [47:0] LOCAL_MAC=`DB_MAC_MEDIA,
    parameter integer PHY_STABLE_CYCLES=1024
)(
    input wire rst,input wire tx_clk,input wire tx_clk_90,input wire bus_clk,
    input wire [7:0] tx_data,input wire tx_valid,output wire tx_ack,
    output wire rx_clk,output wire [7:0] rx_data,
    output wire rx_valid,rx_good,rx_bad,output wire phy_ok,
    input wire rgmii_rxc,input wire rgmii_rx_ctl,input wire [3:0] rgmii_rxd,
    output wire rgmii_txc,rgmii_tx_ctl,output wire [3:0] rgmii_txd,
    output wire mdc,inout wire mdio
);
    wire status_link,status_duplex;
    wire [1:0] status_speed;
    wire phy_good=status_link && status_speed==2'b10 && status_duplex;
    (* async_reg="true" *) reg good1,good2;
    always @(posedge bus_clk or posedge rst)
        if(rst) begin good1<=0;good2<=0;end else begin good1<=phy_good;good2<=good1;end
    // A single in-band status sample must not destroy all reliable-link state.
    // Qualify both transitions for 10.24us at the 100MHz bus clock. Sustained
    // loss/unsupported speed still disconnects, well before the peer timeout.
    localparam PHY_COUNT_BITS=PHY_STABLE_CYCLES>1 ? $clog2(PHY_STABLE_CYCLES):1;
    reg [PHY_COUNT_BITS-1:0] phy_age;
    reg phy_qualified;
    always @(posedge bus_clk or posedge rst) begin
        if(rst) begin phy_age<=0;phy_qualified<=0;end
        else if(good2==phy_qualified) phy_age<=0;
        else if(phy_age==PHY_STABLE_CYCLES-1) begin
            phy_age<=0;phy_qualified<=good2;
        end else phy_age<=phy_age+1'b1;
    end
    assign phy_ok=phy_qualified;
    assign mdc=1'b0;assign mdio=1'bz;
    // TEMAC's address register is little-endian by byte; wire MAC addresses
    // in db_link stay in network order. Render's default address is a byte
    // palindrome, which concealed this mismatch in that receive direction.
    wire [47:0] mac_unicast={LOCAL_MAC[7:0],LOCAL_MAC[15:8],LOCAL_MAC[23:16],
                            LOCAL_MAC[31:24],LOCAL_MAC[39:32],LOCAL_MAC[47:40]};
    temac_block #(.P_HALF_DUPLEX(0),.DEVICE("EG4")) u_mac(
        .reset(rst),.gtx_clk(tx_clk),.gtx_clk_90(tx_clk_90),
        .rx_clk(rx_clk),.rx_clk_en(),.rx_data(rx_data),.rx_data_valid(rx_valid),
        .rx_correct_frame(rx_good),.rx_error_frame(rx_bad),.rx_status_vector(),.rx_status_vld(),
        .tx_clk(),.tx_clk_en(),.tx_data(tx_data),.tx_data_en(tx_valid),.tx_rdy(tx_ack),
        .tx_stop(1'b0),.tx_collision(),.tx_retransmit(),.tx_ifg_val(8'd0),
        .tx_status_vector(),.tx_status_vld(),.tri_speed(),
        .pause_req(1'b0),.pause_val(16'd0),.pause_source_addr(LOCAL_MAC),
        .unicast_address(mac_unicast),.s_axi_aclk(bus_clk),
        .s_axi_awaddr(8'd0),.s_axi_awvalid(1'b0),.s_axi_awready(),
        .s_axi_wdata(32'd0),.s_axi_wvalid(1'b0),.s_axi_wready(),
        .s_axi_bresp(),.s_axi_bvalid(),.s_axi_bready(1'b0),
        .s_axi_araddr(8'd0),.s_axi_arvalid(1'b0),.s_axi_arready(),
        .s_axi_rdata(),.s_axi_rresp(),.s_axi_rvalid(),.s_axi_rready(1'b0),
        .mac_cfg_vector({1'b0,2'b00,2'b10,8'b00000010,7'b0000010}),
        .rgmii_txd(rgmii_txd),.rgmii_tx_ctl(rgmii_tx_ctl),.rgmii_txc(rgmii_txc),
        .rgmii_rxd(rgmii_rxd),.rgmii_rx_ctl(rgmii_rx_ctl),.rgmii_rxc(rgmii_rxc),
        .inband_link_status(status_link),.inband_clock_speed(status_speed),
        .inband_duplex_status(status_duplex),
        .mdio_i(1'b1),.mdio_o(),.mdio_oen(),.mdio_clk());
endmodule
