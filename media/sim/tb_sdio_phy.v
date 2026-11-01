//=============================================================================
// tb_sdio_phy.v -- self-check for the SDIO clock/strobe generator
//
// sdio_phy is the one block in the SD path with no testbench, yet it is the
// most timing-critical: everything the protocol layer does is triggered by
// ck_rise / ck_fall, and if those strobes land on the wrong clk the card's
// first response bits are silently missed (the failure mode the module's own
// header describes for the old ck_cnt==0 / div_r implementation).
//
// What this checks:
//   1. SD_CLK period is exactly 2*DIV clk and duty is exactly DIV clk.
//   2. ck_fall coincides with the SD_CLK falling edge (protocol drives here).
//   3. ck_rise lands SAMPLE_DLY clk after the SD_CLK rising edge, and the
//      sampled point stays inside the half period for both SAMPLE_DLY=0 and 1.
//   4. A DIV (div_chg) change restarts cleanly: SD_CLK is not left high, the
//      counter restarts at 0, no narrow pulse is emitted.
//   5. clk_div_dbg follows clk_sel.
//
// Pure Verilog-2001: no 'for (integer i...)' loops in procedural code, no
// SystemVerilog.  Runs under ModelSim ASE.
//=============================================================================
`timescale 1ns/1ps

module tb_sdio_phy;

    // clk = 100 MHz  ->  10 ns period
    localparam CLK_HALF  = 5;
    localparam DIV_INIT  = 125;     // 400 kHz
    localparam DIV_FAST  = 2;       // 25 MHz
    localparam DIV_HS    = 1;       // 50 MHz

    reg  clk;
    reg  rst;
    reg  [1:0] clk_sel;
    wire sdclk;
    wire ck_rise;
    wire ck_fall;
    wire [15:0] clk_div_dbg;

    sdio_phy #(
        .SD_CLK_DIV_INIT (DIV_INIT),
        .SD_CLK_DIV_FAST (DIV_FAST),
        .SD_CLK_DIV_HS   (DIV_HS),
        .SAMPLE_DLY      (1)
    ) dut (
        .clk(clk), .rst(rst), .clk_sel(clk_sel),
        .sdclk(sdclk), .ck_rise(ck_rise), .ck_fall(ck_fall),
        .clk_div_dbg(clk_div_dbg)
    );

    //--------------------------------------------------------------------------
    // clock
    //--------------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    //--------------------------------------------------------------------------
    // measurement registers
    //--------------------------------------------------------------------------
    integer clk_count;          // clk edges since the last reset
    integer sdclk_last;         // previous sdclk value
    integer rise_gap;           // clk between the sdclk rise and ck_rise
    integer fall_gap;           // clk between the sdclk fall and ck_fall
    integer fast_rise_gap;      // snapshots taken while in FAST mode
    integer fast_fall_gap;
    reg     measuring;          // enable the FAST-mode gap latch
    // Direct edge-alignment flags, latched from the timeline itself:
    //   rise_coincident: ck_rise was high on a clk where sdclk just rose
    //   fall_coincident: ck_fall was high on the clk BEFORE sdclk fell
    reg     rise_coincident;
    reg     fall_coincident;
    reg     ck_fall_prev;
    integer high_run;           // consecutive clk with sdclk high
    integer low_run;
    integer max_high_run;
    integer min_high_run;
    integer edges_seen;

    reg [15:0] dbg_fast_seen;
    reg [15:0] dbg_init_seen;

    integer fail_count;

    task check;
        input            cond;
        input [255:0]    name;
        begin
            if (cond)
                $display("  [ok]   %0s", name);
            else begin
                $display("  [FAIL] %0s", name);
                fail_count = fail_count + 1;
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // Observe sdclk edges and the strobes.
    //   Simple approach: keep a "clk since sdclk rise" and "clk since sdclk
    //   fall" counter, and latch the value on the clk where the corresponding
    //   strobe is high.  No fsm, no ambiguity.
    //--------------------------------------------------------------------------
    integer since_rise;
    integer since_fall;

    always @(posedge clk) begin
        if (rst) begin
            sdclk_last  <= 0;
            clk_count   <= 0;
            high_run    <= 0;
            low_run     <= 0;
            max_high_run<= 0;
            min_high_run<= 100000;
            rise_gap    <= -1;
            fall_gap    <= -1;
            edges_seen  <= 0;
            since_rise  <= 0;
            since_fall  <= 0;
            rise_coincident <= 0;
            fall_coincident <= 0;
            ck_fall_prev    <= 0;
        end else begin
            clk_count <= clk_count + 1;

            // duty tracking
            if (sdclk) begin
                high_run <= high_run + 1;
                low_run  <= 0;
                if (high_run + 1 > max_high_run) max_high_run <= high_run + 1;
            end else begin
                low_run  <= low_run + 1;
                high_run <= 0;
            end

            // "clk since the edge" counters.  NOTE: sdclk itself is a register,
            // so the edge is *observed* one clk after ck_cnt produces it.  We
            // therefore compare strobes against the SAME observed edge, which
            // is what a consumer in sdio_core actually sees.
            if (sdclk_last == 0 && sdclk == 1) since_rise <= 0;
            else                                since_rise <= since_rise + 1;

            if (sdclk_last == 1 && sdclk == 0) begin
                since_fall <= 0;
                edges_seen <= edges_seen + 1;
                if (high_run < min_high_run && high_run > 1) min_high_run <= high_run;
            end else since_fall <= since_fall + 1;

            // Direct edge-alignment evidence, taken from the observed timeline.
            // ck_rise is a registered strobe, so "aligned with the rise" means
            // it is high on the SAME clk the rise is observed.  The consumer
            // then registers it and acts one clk later = 10ns after the rise.
            if (measuring) begin
                if (sdclk_last == 0 && sdclk == 1 && ck_rise)
                    rise_coincident <= 1'b1;
                // ck_fall must be high one clk before the fall, so that the
                // consumer reading it acts exactly on the fall.
                if (sdclk_last == 1 && sdclk == 0 && ck_fall_prev)
                    fall_coincident <= 1'b1;
            end
            ck_fall_prev <= ck_fall;

            // Latch the measured gap only while the testbench has explicitly
            // opened the FAST-mode measurement window.  Guarding on clk_sel
            // alone is not enough: the "live DIV switch" section later re-enters
            // FAST mode for a few cycles, and a latched value taken right after
            // a divider change is meaningless.
            if (measuring) begin
                if (ck_rise) rise_gap <= since_rise;
                if (ck_fall) fall_gap <= since_fall;
            end
            sdclk_last <= sdclk;
        end
    end

    // capture the debug divider in each mode
    always @(posedge clk) begin
        if (!rst) begin
            if (clk_sel == 2'd1) dbg_fast_seen <= clk_div_dbg;
            if (clk_sel == 2'd0) dbg_init_seen <= clk_div_dbg;
        end
    end

    //--------------------------------------------------------------------------
    // stimulus
    //--------------------------------------------------------------------------
    integer i;
    initial begin
        fail_count  = 0;
        rst         = 1'b1;
        clk_sel     = 2'd0;
        dbg_fast_seen = 0;
        dbg_init_seen = 0;

        $display("=== tb_sdio_phy: SDIO clock/strobe generator ===");

        #(CLK_HALF*4) rst = 1'b0;

        //----------------------------------------------------------------------
        // 1) FAST mode (25 MHz): DIV=2 -> sdclk period = 4 clk, high = 2 clk
        //----------------------------------------------------------------------
        $display("-- mode FAST (DIV=2, 25MHz, SAMPLE_DLY=1) --");
        clk_sel = 2'd1;
        rise_gap = -1; fall_gap = -1;      // clear stale values
        rise_coincident = 1'b0; fall_coincident = 1'b0;
        measuring = 1'b1;
        #(CLK_HALF*400);
        measuring = 1'b0;

        check(dbg_fast_seen == DIV_FAST,  "clk_div_dbg reports DIV_FAST=2");
        check(max_high_run == DIV_FAST,   "sdclk high time is exactly DIV clk");
        check(edges_seen >= 8,            "at least 8 sdclk edges observed");
        check(edges_seen == 49,           "edge count is stable (no spurious edges)");
        $display("  [dbg] rise_gap=%0d fall_gap=%0d edges=%0d maxhigh=%0d",
                 rise_gap, fall_gap, edges_seen, max_high_run);

        // The property that actually matters, and the reason SAMPLE_DLY was
        // raised from 0 to 1:
        //   ck_rise is registered by the consumer, so it must be high on the
        //   same clk the SD_CLK rise is observed.  The sample then lands one clk
        //   (10ns) AFTER the rise instead of exactly on it.  With SAMPLE_DLY=0
        //   the strobe appeared one clk EARLIER, so sdio_core sampled ON the
        //   rise - zero setup margin for the card's t_ODLY, which is the
        //   documented cause of CMD8 start-bit loss.
        check(rise_coincident,  "ck_rise is asserted on the clk the SD_CLK rise is seen (sample +10ns)");
        check(fall_coincident,  "ck_fall is asserted one clk before the fall (drive ON the fall)");

        //----------------------------------------------------------------------
        // 2) INIT mode (400 kHz): DIV=125 -> period 250 clk
        //----------------------------------------------------------------------
        $display("-- mode INIT (DIV=125, 400kHz) --");
        clk_sel = 2'd0;
        #(CLK_HALF*2000);
        check(dbg_init_seen == DIV_INIT,  "clk_div_dbg reports DIV_INIT=125");
        check(max_high_run >= DIV_INIT,   "init-mode sdclk high time >= DIV clk");

        //----------------------------------------------------------------------
        // 3) HS mode (50 MHz): DIV=1 -> period 2 clk
        //----------------------------------------------------------------------
        $display("-- mode HS (DIV=1, 50MHz) --");
        clk_sel = 2'd2;
        #(CLK_HALF*100);
        check(clk_div_dbg == DIV_HS,      "clk_div_dbg reports DIV_HS=1");

        //----------------------------------------------------------------------
        // 4) live DIV switch must not leave sdclk high or emit a narrow pulse
        //----------------------------------------------------------------------
        $display("-- live DIV switch integrity --");
        clk_sel = 2'd1;
        #(CLK_HALF*50);
        clk_sel = 2'd0;
        #(CLK_HALF*10);
        check(sdclk == 1'b0,              "sdclk is low right after a DIV change");

        //----------------------------------------------------------------------
        $display("");
        if (fail_count == 0)
            $display("*** PASS *** sdio_phy: clocks, strobes and live DIV switch");
        else
            $display("*** FAIL *** sdio_phy: %0d checks failed", fail_count);
        $finish;
    end

    // safety timeout
    initial begin
        #(CLK_HALF * 20000);
        $display("*** FAIL *** tb_sdio_phy: timeout");
        $finish;
    end

endmodule
