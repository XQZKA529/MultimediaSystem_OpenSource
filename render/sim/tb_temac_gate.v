`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_temac_gate;
    reg clk=0,t0=0,t1=0,rst=1,phy=1;
    always #5 clk=~clk;
    always #4 t0=~t0;
    always #4.01 t1=~t1;
    wire up0,up1,reset0,reset1;
    wire [7:0] md0,md1;wire mv0,mv1,ma0,ma1;
    wire [7:0] rd0,rd1;wire rv0,rv1,rg0,rg1;
    reg meta=0,dv=0,last=0;
    reg [7:0] channel=2,op=`DB_IMG_DATA;
    reg [15:0] length=1024;
    reg [31:0] data=0;
    wire metardy,dr;
    wire rmeta,rdvalid,rlast;wire [31:0] rdata,robj,roff;
    wire [7:0] rchan,rop;wire [15:0] rlen;
    reg accept=1;reg [31:0] retries0,errors1;
    wire [31:0] ret0,err1;
    reg drop_next=0,corrupt_next=0;
    wire [31:0] packet_count;
    db_link #(.HEARTBEAT_CYCLES(5000),.TIMEOUT_CYCLES(150000),.RETRY_CYCLES(10000)) a(
        .clk(clk),.rst(rst),.phy_ok(phy),.link_up(up0),.session_reset(reset0),
        .tx_meta_valid(meta),.tx_meta_ready(metardy),.tx_channel(channel),.tx_opcode(op),
        .tx_object(32'd42),.tx_offset(32'd256),.tx_length(length),
        .tx_valid(dv),.tx_ready(dr),.tx_data(data),.tx_last(last),
        .rx_meta_valid(),.rx_meta_ready(1'b1),.rx_channel(),.rx_opcode(),.rx_object(),.rx_offset(),
        .rx_length(),.rx_valid(),.rx_ready(1'b1),.rx_data(),.rx_last(),
        .mac_tx_clk(t0),.mac_tx_data(md0),.mac_tx_valid(mv0),.mac_tx_ack(ma0),
        .mac_rx_clk(t1),.mac_rx_data(rd0),.mac_rx_valid(rv0),.mac_rx_good(rg0),.mac_rx_bad(1'b0),
        .retry_count(ret0),.crc_errors(),.rx_drops());
    db_link #(.ROLE(2),.LOCAL_MAC(`DB_MAC_RENDER),.PEER_MAC(`DB_MAC_MEDIA),
        .HEARTBEAT_CYCLES(5000),.TIMEOUT_CYCLES(150000),.RETRY_CYCLES(10000)) b(
        .clk(clk),.rst(rst),.phy_ok(phy),.link_up(up1),.session_reset(reset1),
        .tx_meta_valid(1'b0),.tx_meta_ready(),.tx_channel(8'd0),.tx_opcode(8'd0),
        .tx_object(32'd0),.tx_offset(32'd0),.tx_length(16'd0),
        .tx_valid(1'b0),.tx_ready(),.tx_data(32'd0),.tx_last(1'b0),
        .rx_meta_valid(rmeta),.rx_meta_ready(accept),.rx_channel(rchan),.rx_opcode(rop),
        .rx_object(robj),.rx_offset(roff),.rx_length(rlen),
        .rx_valid(rdvalid),.rx_ready(accept),.rx_data(rdata),.rx_last(rlast),
        .mac_tx_clk(t1),.mac_tx_data(md1),.mac_tx_valid(mv1),.mac_tx_ack(ma1),
        .mac_rx_clk(t0),.mac_rx_data(rd1),.mac_rx_valid(rv1),.mac_rx_good(rg1),.mac_rx_bad(1'b0),
        .retry_count(),.crc_errors(err1),.rx_drops());
    real_mac_pipe #(.DEST(`DB_MAC_RENDER)) forward(.clk(t0),.rst(rst),.din(md0),.valid(mv0),.ack(ma0),
        .drop_next(drop_next),.corrupt_next(corrupt_next),.dout(rd1),.dv(rv1),.good(rg1),.packets(packet_count));
    real_mac_pipe #(.DEST(`DB_MAC_MEDIA)) backward(.clk(t1),.rst(rst),.din(md1),.valid(mv1),.ack(ma1),
        .drop_next(1'b0),.corrupt_next(1'b0),.dout(rd0),.dv(rv0),.good(rg0),.packets());

    always @(posedge up0 or negedge up0) if(!rst) $display("link0=%b at %t",up0,$time);
    initial begin #100000;$display("SNAP up=%b%b completed=%d MAC good=%d/%d rxerr=%d TXstate=%d/%d speed=%b%b%b",up0,up1,completed,forward.packets,backward.packets,err1,a.tx_state,b.tx_state,forward.s1000,forward.s100,forward.s10);end
    integer received=0,words=0,completed=0;
    reg [31:0] held;
    reg held_valid=0;
    always @(posedge clk) if(!rst) begin
        if(rmeta && accept) begin
            if(robj!=42 || roff!=256 || rlen!=1024 || rchan!=2) fail("metadata");
            received=received+1;words=0;
        end
        if(rdvalid && accept) begin
            if(rdata!==32'h12340000+words) fail("payload byte order / corruption / RAM prefetch");
            words=words+1;
            if(rlast) begin if(words!=256) fail("packet length");completed=completed+1;end
        end
        if(held_valid && rdvalid && !accept && held!==rdata) fail("stalled word changed");
        held=rdata;held_valid=rdvalid && !accept;
    end
    task fail;
        input [511:0] message;
        begin $display("FAIL %0s at %0t",message,$time);$finish;end
    endtask
    task packet;
        integer n;
        begin
            @(negedge clk);meta=1;
            while(!metardy) @(negedge clk);
            @(negedge clk);meta=0;
            for(n=0;n<256;n=n+1) begin
                dv=1;data=32'h12340000+n;last=n==255;
                while(!dr) @(negedge clk);
                @(negedge clk);
            end
            dv=0;last=0;
        end
    endtask
    initial begin
        #100;rst=0;wait(up0 && up1);#1000;
        packet;
        wait(completed==1);#10000;
        if(!up0 || !up1 || ret0!=0 || err1!=0) fail("clean real MAC link errors");
        $display("*** PASS *** real TEMAC: bidirectional HELLO, 1024-byte payload, CRC/ACK, zero retries");$finish;
    end
    initial begin #100000;fail("watchdog");end
endmodule


// Each real MAC loops GMII TX into its own RX; its client RX feeds the
// opposite db_link. The two directions use separate 125MHz clocks.
// Actual shipped gate netlist performs framing, FCS and address filtering.
module real_mac_pipe #(parameter [47:0] DEST=0)(
    input wire clk,rst,input wire [7:0] din,input wire valid,output wire ack,
    input wire drop_next,corrupt_next,output wire [7:0] dout,output wire dv,good,
    output reg [31:0] packets=0
);
    wire bad;
    db_ethernet #(.LOCAL_MAC(DEST),.PHY_STABLE_CYCLES(8)) adapter(
        .rst(rst),.bus_clk(clk),.tx_clk(clk),.tx_clk_90(clk),
        .tx_data(din),.tx_valid(valid),.tx_ack(ack),.rx_clk(),
        .rx_data(dout),.rx_valid(dv),.rx_good(good),.rx_bad(bad),.phy_ok(),
        .rgmii_rxc(clk),.rgmii_rx_ctl(1'b0),.rgmii_rxd(4'd0));
    wire s1000=1'b1,s100=1'b0,s10=1'b0;
    always @(posedge clk) begin
        if(good) packets<=packets+1;
        if(bad) begin $display("FAIL real MAC FCS/receive error at %t",$time);$finish;end
    end
endmodule
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

    assign inband_link_status=1'b1;
    assign inband_clock_speed=2'b10;
    assign inband_duplex_status=1'b1;
    assign rx_clk=gtx_clk;
    wire [7:0] gmii_data;
    wire gmii_en,gmii_er,bad;
    wire s1000,s100,s10;
    TEMAC_CORE mac(
        .reset(reset),.tx_mac_clk(gtx_clk),.rx_mac_clk(gtx_clk),.s_axi_aclk(s_axi_aclk),
        .tx_clk_en(1'b1),.rx_clk_en(1'b1),.gmii_tx_clken(1'b1),
        .tx_data(tx_data),.tx_data_en(tx_data_en),.tx_rdy(tx_rdy),.tx_stop(1'b0),.tx_ifg_val(8'd0),
        .gmii_txd(gmii_data),.gmii_tx_en(gmii_en),.gmii_tx_er(gmii_er),
        .gmii_rxd(gmii_data),.gmii_rx_vld(gmii_en),.gmii_rx_er(gmii_er),
        .gmii_col(1'b0),.gmii_crs(1'b0),
        .rx_data(rx_data),.rx_data_vld(rx_data_valid),.rx_correct_frame(rx_correct_frame),.rx_error_frame(rx_error_frame),
        .speed_1000(s1000),.speed_100(s100),.speed_10(s10),
        .mac_cfg_vector({1'b0,2'b00,2'b10,8'b00000010,7'b0000010}),
        .unicast_addr(unicast_address),.pause_req(1'b0),.pause_val(16'd0),.pause_source_addr(pause_source_addr),
        .mdio_in(1'b1),.s_axi_awaddr(8'd0),.s_axi_awvalid(1'b0),
        .s_axi_wdata(32'd0),.s_axi_wvalid(1'b0),.s_axi_bready(1'b0),
        .s_axi_araddr(8'd0),.s_axi_arvalid(1'b0),.s_axi_rready(1'b0)
    );
endmodule
