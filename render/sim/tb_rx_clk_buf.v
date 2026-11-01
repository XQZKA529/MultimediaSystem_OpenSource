// ---------------------------------------------------------------------------
// tb_rx_clk_buf.v
//
// Synthesis-shape check for db_rx_clk_buf / rgmii_interface's RX clock path.
//
// No existing testbench instantiates the real rgmii_interface (tb_phy_status
// carries its own temac_block stub), so this bench exists purely to prove:
//   1. rgmii_interface + db_rx_clk_buf elaborate and compile together,
//   2. EG_LOGIC_BUFG resolves to a behavioural model so ModelSim can run it,
//   3. rx_rgmii_clk actually toggles, i.e. RXC reaches the IDDR clock port
//      through the buffer rather than being dropped.
//
// It is a compile/elaborate guard, not a protocol conformance test.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

// Minimal behavioural stand-ins for the two vendor pad primitives.  The real
// ones come from the TD primitive library; for a ModelSim compile check these
// pass-through models are enough to prove the instance/port wiring is legal.
module IDDR #(
    parameter DEVICE   = "EG4",
    parameter ASYNCRST = "ENABLE",
    parameter PIPEMODE = "PIPED"
)(
    output q0, output q1, input clk, input d, input rst
);
    reg r0, r1;
    always @(posedge clk) r0 <= d;
    always @(negedge clk) r1 <= d;
    assign q0 = r0;
    assign q1 = r1;
endmodule

module ODDR #(
    parameter DEVICE   = "EG4",
    parameter ASYNCRST = "ENABLE"
)(
    output q, input clk, input d0, input d1, input rst
);
    reg r;
    always @(posedge clk) r <= d0;
    always @(negedge clk) r <= d1;
    assign q = r;
endmodule

module EG_LOGIC_BUFG (input i, output o);
    assign o = i;
endmodule

module tb_rx_clk_buf;
    reg        clk = 0;
    reg        rst = 1;
    reg  [3:0] rxd = 4'h0;
    reg        rx_ctl = 1'b0;

    wire [3:0] txd;
    wire       tx_ctl, txc;
    wire       link_status, duplex_status;
    wire [1:0] clock_speed;
    wire [7:0] gmii_rxd;
    wire       gmii_rx_dv, gmii_rx_er, gmii_crs, gmii_col;
    wire       rx_rgmii_clk;

    // 125 MHz reference (RGMII gigabit)
    always #4 clk = ~clk;

    rgmii_interface dut (
        .tx_reset        (rst),
        .rx_reset        (rst),
        .speed_10_100    (1'b0),
        .rgmii_txd       (txd),
        .rgmii_tx_ctl    (tx_ctl),
        .rgmii_txc       (txc),
        .rgmii_rxd       (rxd),
        .rgmii_rx_ctl    (rx_ctl),
        .rgmii_rxc       (clk),
        .link_status     (link_status),
        .clock_speed     (clock_speed),
        .duplex_status   (duplex_status),
        .gmii_txc_en     (1'b1),
        .gmii_txd        (8'h00),
        .gmii_tx_en      (1'b0),
        .gmii_tx_er      (1'b0),
        .gmii_crs        (gmii_crs),
        .gmii_col        (gmii_col),
        .gmii_rxd        (gmii_rxd),
        .gmii_rx_dv      (gmii_rx_dv),
        .gmii_rx_er      (gmii_rx_er),
        .tx_clk          (clk),
        .tx_clk_90       (clk),
        .rgmii_txc_en        (1'b1),
        .rgmii_txc_en_shift  (1'b1),
        .rx_rgmii_clk    (rx_rgmii_clk)
    );

    integer rx_edges = 0;
    always @(posedge rx_rgmii_clk) rx_edges = rx_edges + 1;

    initial begin
        // Hold reset through a few clocks so the RX domain settles.
        repeat (10) @(posedge clk);
        rst = 0;

        // Let RX run and count output edges.  If db_rx_clk_buf dropped the
        // clock, rx_edges would stay at 0 and the check below fails.
        repeat (100) @(posedge clk);
        if (rx_edges < 50) begin
            $display("*** FAIL *** rx_rgmii_clk did not toggle (edges=%0d)", rx_edges);
            $finish;
        end

        // In-band status: while gmii_rx_dv/er are low the status register
        // samples gmii_rxd_reg[3:0].  On the real pad the four RXD lanes carry
        // {duplex, speed[1], speed[0], link}, and the IDDR splits each lane
        // across both edges into the low/high nibble of gmii_rxd_reg.  This
        // bench drives all four lanes identically, so both nibbles come out
        // equal and only the low nibble is meaningful here.  Assert that the
        // register actually latched a non-zero value, which proves the IDDR
        // capture path is being clocked through the buffer.
        rxd    = 4'b1111;
        rx_ctl = 1'b0;
        repeat (20) @(posedge clk);
        if (link_status !== 1'b1) begin
            $display("*** FAIL *** in-band status not sampled through clock buffer: link=%b speed=%b dup=%b",
                     link_status, clock_speed, duplex_status);
            $finish;
        end

        // Now present the all-zero pattern and confirm the register follows it,
        // which rules out a stuck-at latch.
        rxd = 4'b0000;
        repeat (20) @(posedge clk);
        if (link_status !== 1'b0) begin
            $display("*** FAIL *** in-band status did not track RXD: link=%b", link_status);
            $finish;
        end

        $display("*** PASS *** rx clk buf: rx_rgmii_clk toggling (edges=%0d), in-band status tracked through the buffer", rx_edges);
        $finish;
    end

    initial begin
        #200000;
        $display("*** FAIL *** timeout");
        $finish;
    end
endmodule
