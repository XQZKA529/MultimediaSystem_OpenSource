`timescale 1ns/1ps
// Session-stability regression using PRODUCTION DEFAULT parameters.
//
// db_link with default params: HEARTBEAT=CLK_HZ/50 (20ms), TIMEOUT=CLK_HZ/10
// (100ms), RETRY=CLK_HZ/200 (5ms). tb_link overrides all three, so it never
// exercised the defaults. This test drives two real endpoints with matched
// session handshakes and asserts that steady-state keepalive traffic does NOT
// repeatedly raise session_reset.
//
// CLK_HZ is scaled down so the simulation is fast while the default RATIOS
// (and therefore the heartbeat/timeout relationship) stay exactly as on HW.
`include "pkg/board_link.vh"
module tb_session_stability;
    localparam integer CLK_HZ=20000;   // HB=400 cyc, TO=2000 cyc, RETRY=100 cyc
    reg clk=0,t0=0,t1=0,rst=1,phy=1;
    always #5 clk=~clk;
    always #4 t0=~t0;
    always #4.01 t1=~t1;
    wire up0,up1,reset0,reset1;
    wire [7:0] md0,md1;wire mv0,mv1,ma0,ma1;
    wire [7:0] rd0,rd1;wire rv0,rv1,rg0,rg1;
    wire [31:0] err0,err1;
    db_link #(.CLK_HZ(CLK_HZ)) a(
        .clk(clk),.rst(rst),.phy_ok(phy),.link_up(up0),.session_reset(reset0),
        .tx_meta_valid(1'b0),.tx_meta_ready(),.tx_channel(8'd0),.tx_opcode(8'd0),
        .tx_object(32'd0),.tx_offset(32'd0),.tx_length(16'd0),
        .tx_valid(1'b0),.tx_ready(),.tx_data(32'd0),.tx_last(1'b0),
        .rx_meta_valid(),.rx_meta_ready(1'b1),.rx_required(),.rx_channel(),.rx_opcode(),.rx_object(),.rx_offset(),
        .rx_length(),.rx_valid(),.rx_ready(1'b1),.rx_data(),.rx_last(),
        .mac_tx_clk(t0),.mac_tx_data(md0),.mac_tx_valid(mv0),.mac_tx_ack(ma0),
        .mac_rx_clk(t1),.mac_rx_data(rd0),.mac_rx_valid(rv0),.mac_rx_good(rg0),.mac_rx_bad(1'b0),
        .retry_count(),.crc_errors(err0),.rx_drops(),
        .retry_seen(),.error_seen(),.drop_seen());
    db_link #(.ROLE(2),.LOCAL_MAC(`DB_MAC_RENDER),.PEER_MAC(`DB_MAC_MEDIA),.CLK_HZ(CLK_HZ)) b(
        .clk(clk),.rst(rst),.phy_ok(phy),.link_up(up1),.session_reset(reset1),
        .tx_meta_valid(1'b0),.tx_meta_ready(),.tx_channel(8'd0),.tx_opcode(8'd0),
        .tx_object(32'd0),.tx_offset(32'd0),.tx_length(16'd0),
        .tx_valid(1'b0),.tx_ready(),.tx_data(32'd0),.tx_last(1'b0),
        .rx_meta_valid(),.rx_meta_ready(1'b1),.rx_required(),.rx_channel(),.rx_opcode(),.rx_object(),.rx_offset(),
        .rx_length(),.rx_valid(),.rx_ready(1'b1),.rx_data(),.rx_last(),
        .mac_tx_clk(t1),.mac_tx_data(md1),.mac_tx_valid(mv1),.mac_tx_ack(ma1),
        .mac_rx_clk(t0),.mac_rx_data(rd1),.mac_rx_valid(rv1),.mac_rx_good(rg1),.mac_rx_bad(1'b0),
        .retry_count(),.crc_errors(err1),.rx_drops(),
        .retry_seen(),.error_seen(),.drop_seen());
    tb_mac_client_pipe forward(.clk(t0),.rst(rst),.din(md0),.valid(mv0),.ack(ma0),
        .drop_next(1'b0),.corrupt_next(1'b0),.dout(rd1),.dv(rv1),.good(rg1),.packets());
    tb_mac_client_pipe backward(.clk(t1),.rst(rst),.din(md1),.valid(mv1),.ack(ma1),
        .drop_next(1'b0),.corrupt_next(1'b0),.dout(rd0),.dv(rv0),.good(rg0),.packets());

    integer resets_seen,ups0,ups1;
    initial begin
        resets_seen=0;ups0=0;ups1=0;
        #100;rst=0;
        wait(up0 && up1);
        // Let the handshake settle, then observe steady state for 20 heartbeat periods.
        repeat(CLK_HZ/50*2) @(posedge clk);
        resets_seen=0;
        repeat(CLK_HZ/50*20) begin
            @(posedge clk);
            if(reset0) resets_seen=resets_seen+1;
            if(up0) ups0=ups0+1;
            if(up1) ups1=ups1+1;
        end
        if(resets_seen!=0)
            begin $display("FAIL steady state raised session_reset %0d times (link flapping)",resets_seen);$finish;end
        $display("*** PASS *** session stability: no session_reset in steady state; up0 ratio=%0d up1 ratio=%0d",
            ups0/(CLK_HZ/50*20),ups1/(CLK_HZ/50*20));
        $finish;
    end
    initial begin #50000000;$display("FAIL watchdog");$finish;end
endmodule

module tb_mac_client_pipe(
    input wire clk,rst,input wire [7:0] din,input wire valid,output wire ack,
    input wire drop_next,corrupt_next,output reg [7:0] dout,output reg dv,good,
    output reg [31:0] packets
);
    reg active,drop_frame,corrupt_frame;
    reg [11:0] bytes;
    assign ack=valid && !active;
    always @(posedge clk or posedge rst) begin
        if(rst) begin active<=0;drop_frame<=0;corrupt_frame<=0;bytes<=0;dout<=0;dv<=0;good<=0;packets<=0;end
        else begin
            good<=0;dv<=0;
            if(valid) begin
                active<=1;bytes<=active ? bytes+1'b1:1;
                if(!active) begin drop_frame<=drop_next;corrupt_frame<=corrupt_next;end
                dout<=din ^ ((active && corrupt_frame && bytes==62) ? 8'h01:8'h00);
                dv<=!(active ? drop_frame:drop_next);
            end else if(active) begin
                active<=0;good<=!drop_frame;packets<=packets+1'b1;
            end
        end
    end
endmodule
