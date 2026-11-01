`timescale 1ns/1ps
module tb_phy_status;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    wire ready,default_ready;
    db_ethernet #(.PHY_STABLE_CYCLES(8)) dut(
        .rst(rst),.bus_clk(clk),.tx_clk(clk),.tx_clk_90(clk),
        .tx_data(8'd0),.tx_valid(1'b0),.phy_ok(ready),
        .rgmii_rxc(clk),.rgmii_rx_ctl(1'b0),.rgmii_rxd(4'd0));
    db_ethernet default_dut(
        .rst(rst),.bus_clk(clk),.tx_clk(clk),.tx_clk_90(clk),
        .tx_data(8'd0),.tx_valid(1'b0),.phy_ok(default_ready),
        .rgmii_rxc(clk),.rgmii_rx_ctl(1'b0),.rgmii_rxd(4'd0));
    task ticks;
        input integer n;
        begin repeat(n) @(negedge clk);end
    endtask
    task check_ready;
        input expected;
        begin if(ready!==expected) begin $display("FAIL PHY qualification at %0t",$time);$finish;end end
    endtask
    initial begin
        ticks(3);rst=0;
        dut.u_mac.link=1;dut.u_mac.speed=2;dut.u_mac.duplex=1;
        ticks(8);check_ready(0);ticks(4);check_ready(1);
        // Short bad status samples must not disconnect a healthy session.
        dut.u_mac.link=0;ticks(1);dut.u_mac.link=1;ticks(12);check_ready(1);
        dut.u_mac.speed=1;ticks(3);dut.u_mac.speed=2;ticks(12);check_ready(1);
        dut.u_mac.duplex=0;ticks(5);dut.u_mac.duplex=1;ticks(12);check_ready(1);
        // A real loss must still disconnect, and a short good pulse cannot reconnect.
        dut.u_mac.link=0;ticks(12);check_ready(0);
        dut.u_mac.link=1;ticks(4);dut.u_mac.link=0;ticks(12);check_ready(0);
        dut.u_mac.link=1;dut.u_mac.speed=1;ticks(20);check_ready(0);
        dut.u_mac.speed=2;dut.u_mac.duplex=0;ticks(20);check_ready(0);
        dut.u_mac.duplex=1;ticks(12);check_ready(1);
        rst=1;#1;check_ready(0);
        ticks(3);rst=0;
        default_dut.u_mac.link=1;default_dut.u_mac.speed=2;default_dut.u_mac.duplex=1;
        ticks(1024);
        if(default_ready!==0) begin $display("FAIL default PHY qualified too early");$finish;end
        ticks(4);
        if(default_ready!==1) begin $display("FAIL default PHY did not qualify");$finish;end
        default_dut.u_mac.link=0;ticks(1);default_dut.u_mac.link=1;ticks(1030);
        if(default_ready!==1) begin $display("FAIL default PHY disconnected on one bad sample");$finish;end
        default_dut.u_mac.link=0;ticks(1030);
        if(default_ready!==0) begin $display("FAIL default PHY did not disconnect on sustained loss");$finish;end
        $display("*** PASS *** PHY status: transient rejection, sustained loss/recovery, gigabit/full requirement, reset, production 1024-cycle threshold");$finish;
    end
endmodule

// Only the vendor MAC's status outputs are modelled here; RGMII electrical
// timing and PHY negotiation remain hardware checks.
module temac_block #(
    parameter P_HALF_DUPLEX=0,parameter DEVICE="EG4"
)(
    input reset,gtx_clk,gtx_clk_90,output rx_clk,rx_clk_en,
    output [7:0] rx_data,output rx_data_valid,rx_correct_frame,rx_error_frame,
    output [26:0] rx_status_vector,output rx_status_vld,
    output tx_clk,tx_clk_en,input [7:0] tx_data,input tx_data_en,output tx_rdy,
    input tx_stop,output tx_collision,tx_retransmit,input [7:0] tx_ifg_val,
    output [28:0] tx_status_vector,output tx_status_vld,output [1:0] tri_speed,
    input pause_req,input [15:0] pause_val,input [47:0] pause_source_addr,unicast_address,
    input s_axi_aclk,input [7:0] s_axi_awaddr,input s_axi_awvalid,output s_axi_awready,
    input [31:0] s_axi_wdata,input s_axi_wvalid,output s_axi_wready,
    output [1:0] s_axi_bresp,output s_axi_bvalid,input s_axi_bready,
    input [7:0] s_axi_araddr,input s_axi_arvalid,output s_axi_arready,
    output [31:0] s_axi_rdata,output [1:0] s_axi_rresp,output s_axi_rvalid,input s_axi_rready,
    input [19:0] mac_cfg_vector,output [3:0] rgmii_txd,output rgmii_tx_ctl,rgmii_txc,
    input [3:0] rgmii_rxd,input rgmii_rx_ctl,rgmii_rxc,
    output inband_link_status,output [1:0] inband_clock_speed,output inband_duplex_status,
    input mdio_i,output mdio_o,mdio_oen,mdio_clk
);
    reg link=0,duplex=0;
    reg [1:0] speed=0;
    assign inband_link_status=link;
    assign inband_clock_speed=speed;
    assign inband_duplex_status=duplex;
endmodule
