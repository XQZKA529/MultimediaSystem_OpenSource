// RGB888 crossfade: three clocks of latency, one pixel per clock.
// Preserve round((old*256 + alpha*(new-old))/256), including saturation.
`default_nettype none
module pixel_mixer (
    input wire clk, rst, mix_en,
    input wire [8:0] alpha,
    input wire [23:0] old_rgb,
    input wire old_valid,
    input wire [23:0] new_rgb,
    input wire new_valid,
    output reg [23:0] mixed_rgb,
    output reg pair_ok
);
    reg signed [8:0] diff_r, diff_g, diff_b;
    reg signed [9:0] alpha_q;
    reg signed [18:0] prod_r, prod_g, prod_b;
    reg [23:0] old_s1, old_s2;
    reg valid_s1, valid_s2;
    function [7:0] finish_blend;
        input [7:0] old;
        input signed [18:0] product;
        reg signed [18:0] rounded;
        reg signed [10:0] sum;
        begin
            rounded = (product + 19'sd128) >>> 8;
            sum = $signed({1'b0,old}) + rounded;
            if (sum < 0) finish_blend = 0;
            else if (sum > 255) finish_blend = 255;
            else finish_blend = sum[7:0];
        end
    endfunction
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            diff_r<=0; diff_g<=0; diff_b<=0; alpha_q<=0;
            prod_r<=0; prod_g<=0; prod_b<=0;
            old_s1<=0; old_s2<=0; valid_s1<=0; valid_s2<=0;
            mixed_rgb<=0; pair_ok<=0;
        end else begin
            diff_r <= $signed({1'b0,new_rgb[23:16]}) - $signed({1'b0,old_rgb[23:16]});
            diff_g <= $signed({1'b0,new_rgb[15:8]}) - $signed({1'b0,old_rgb[15:8]});
            diff_b <= $signed({1'b0,new_rgb[7:0]}) - $signed({1'b0,old_rgb[7:0]});
            alpha_q <= mix_en ? $signed({1'b0,alpha}) : 10'sd0;
            old_s1 <= old_rgb;
            valid_s1 <= old_valid && (!mix_en || new_valid);
            prod_r <= alpha_q * diff_r;
            prod_g <= alpha_q * diff_g;
            prod_b <= alpha_q * diff_b;
            old_s2 <= old_s1; valid_s2 <= valid_s1;
            mixed_rgb <= {finish_blend(old_s2[23:16],prod_r),
                          finish_blend(old_s2[15:8],prod_g),
                          finish_blend(old_s2[7:0],prod_b)};
            pair_ok <= valid_s2;
        end
    end
endmodule
`default_nettype wire
