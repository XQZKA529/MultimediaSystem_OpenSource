// One pipeline stage for an aligned parallel-video stream.
// Registering both timing and RGB keeps the stream contract intact while
// isolating combinational overlay logic at higher pixel clocks.
module video_stream_reg (
    input  wire        clk,
    input  wire        rst,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    input  wire [23:0] rgb_in,
    output reg         hs_out,
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] rgb_out
);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hs_out  <= 1'b0;
            vs_out  <= 1'b0;
            de_out  <= 1'b0;
            rgb_out <= 24'd0;
        end else begin
            hs_out  <= hs_in;
            vs_out  <= vs_in;
            de_out  <= de_in;
            rgb_out <= de_in ? rgb_in : 24'd0;
        end
    end
endmodule
