`timescale 1ns/1ps
// Regression for the keepalive/timeout contract, using the PRODUCTION DEFAULT
// parameters (no overrides). tb_link overrides HEARTBEAT/TIMEOUT explicitly, so
// it silently passed while the real hardware -- which uses the module defaults
// -- tore the session down every cycle because TIMEOUT_CYCLES (10ms) was
// shorter than HEARTBEAT_CYCLES (20ms).
//
// Contract under test: with both endpoints idle (only HELLO keepalives), the
// link must stay up across MANY heartbeat periods. We shrink CLK_HZ so the
// default ratios (CLK_HZ/50 and TIMEOUT_CYCLES default) stay intact but the
// simulation is fast, then run for well past several heartbeat periods.
`include "pkg/board_link.vh"
module tb_link_keepalive;
    // Keep the DEFAULT ratios by scaling CLK_HZ. No HEARTBEAT/TIMEOUT overrides.
    localparam integer CLK_HZ=100000;
    reg clk=0,t0=0,t1=0,rst=1,phy=1;
    always #5 clk=~clk;
    always #4 t0=~t0;
    always #4.01 t1=~t1;
    wire up0,up1,reset0,reset1;
    wire [7:0] md0,md1;wire mv0,mv1,ma0,ma1;
    wire [7:0] rd0,rd1;wire rv0,rv1,rg0,rg1;
    wire [31:0] err0,err1;
    // IMPORTANT: only CLK_HZ is set. HEARTBEAT/TIMEOUT/RETRY keep their
    // production defaults derived from CLK_HZ. If the defaults are wrong
    // (timeout <= heartbeat) this test fails.
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

    task fail;
        input [511:0] message;
        begin $display("FAIL %0s at %0t",message,$time);$finish;end
    endtask

    integer drops0,drops1,cycles_up;
    reg prev0,prev1;
    // Heartbeat = CLK_HZ/50 = 2000 cycles here; timeout default = CLK_HZ/2 = 50000.
    // Run 8 heartbeat periods and require the link to stay continuously up.
    localparam integer HEARTBEAT_CYCLES_LOCAL=CLK_HZ/50;
    localparam integer RUN_CYCLES=HEARTBEAT_CYCLES_LOCAL*8;
    initial begin
        drops0=0;drops1=0;cycles_up=0;prev0=0;prev1=0;
        #100;rst=0;
        wait(up0 && up1);
        // Sample every bus clock: once up, it must never fall.
        repeat(RUN_CYCLES) begin
            @(posedge clk);
            if(up0) cycles_up=cycles_up+1;
            if(prev0 && !up0) drops0=drops0+1;
            if(prev1 && !up1) drops1=drops1+1;
            prev0=up0;prev1=up1;
        end
        if(drops0!=0) fail("render session dropped while idle (TIMEOUT<HEARTBEAT?)");
        if(drops1!=0) fail("media session dropped while idle (TIMEOUT<HEARTBEAT?)");
        $display("*** PASS *** keepalive: link stayed up across %0d heartbeat periods, no idle session drop (up0=%b up1=%b)",
            RUN_CYCLES/HEARTBEAT_CYCLES_LOCAL,up0,up1);
        $finish;
    end
    initial begin #20000000;fail("watchdog");end
endmodule

// Same MAC client contract model as tb_link (first-byte ack, unbroken frame).
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
