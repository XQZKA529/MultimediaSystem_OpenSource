// Per-domain reset synchronizer: async assert, sync de-assert.
// SPDX-License-Identifier: MIT
//
// The top level generates rst_all in the 50 MHz sys_clk domain.  Feeding it
// straight to the async reset pins of other clock domains makes STA check
// sys_clk -> <fast clock> setup on the whole reset tree (observed -0.459 ns
// on EG4S20).  Each domain therefore takes a locally synchronized copy: the
// assert stays asynchronous (every FF is reset no matter its clock), the
// release is aligned to the local clock. The final two sync bits also drive
// a small release decode so the high-fanout async reset tree has enough
// removal delay after the final clock edge. The only sys_clk fan-out left is these three first-stage
// floppers, which the SDC declares asynchronous.
module reset_sync #(
    parameter STAGES     = 3,   // release alignment depth
    parameter ACTIVE_HIGH = 1   // 1: rst_out active high, 0: active low
)(
    input  wire clk,
    input  wire rst_in,         // async input reset, active high
    output wire rst_out
);
    reg [STAGES-1:0] sync_ff;
    initial sync_ff = {STAGES{1'b1}};

    always @(posedge clk or posedge rst_in) begin
        if (rst_in)
            sync_ff <= {STAGES{1'b1}};
        else
            sync_ff <= {sync_ff[STAGES-2:0], 1'b0};
    end

    generate
        if (ACTIVE_HIGH) begin : g_act_high
            assign rst_out = sync_ff[STAGES-1] | sync_ff[STAGES-2];
        end else begin : g_act_low
            assign rst_out = ~(sync_ff[STAGES-1] & sync_ff[STAGES-2]);
        end
    endgenerate
endmodule
