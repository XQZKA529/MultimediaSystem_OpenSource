// Three-clock signed PCM pipeline. Gain slews only on actual sample strobes.
// Q15 unity is exactly 32768; no division, RAM or playback state is used.
module audio_volume_gain(
    input wire clk,rst,input wire [4:0] level,
    input wire unity,
    input wire in_valid,input wire [23:0] in_left,in_right,
    output reg out_valid,output reg [23:0] out_left,out_right
);
    function [15:0] coefficient;
        input [4:0] n;
        begin
            case(n)
                0:coefficient=0;1:coefficient=1638;2:coefficient=3277;
                3:coefficient=4915;4:coefficient=6554;5:coefficient=8192;
                6:coefficient=9830;7:coefficient=11469;8:coefficient=13107;
                9:coefficient=14746;10:coefficient=16384;11:coefficient=18022;
                12:coefficient=19661;13:coefficient=21299;14:coefficient=22938;
                15:coefficient=24576;16:coefficient=26214;17:coefficient=27853;
                18:coefficient=29491;19:coefficient=31130;
                default:coefficient=32768;
            endcase
        end
    endfunction
    reg [15:0] gain;
    wire [15:0] target=coefficient(level);
    wire [15:0] next_gain=target>gain ?
        (target-gain>69 ? gain+16'd69:target):
        (gain-target>69 ? gain-16'd69:target);
    wire [15:0] sample_gain=unity===1'b1 ? 16'd32768:next_gain;
    reg signed [40:0] product_left,product_right;
    reg valid_a,valid_b;
    reg [23:0] sample_left,sample_right;
    reg [15:0] gain_a;
    // Add half an LSB, with a one-unit correction for negative ties.
    // Arithmetic shift then implements symmetric round-to-nearest, ties away.
    wire signed [40:0] rounded_left=product_left+41'sd16384-(product_left[40] ? 41'sd1:41'sd0);
    wire signed [40:0] rounded_right=product_right+41'sd16384-(product_right[40] ? 41'sd1:41'sd0);
    always @(posedge clk or posedge rst) begin
        if(rst) begin gain<=32768;valid_a<=0;valid_b<=0;out_valid<=0;sample_left<=0;sample_right<=0;gain_a<=0;product_left<=0;product_right<=0;out_left<=0;out_right<=0;end
        else begin
            valid_a<=in_valid;valid_b<=valid_a;out_valid<=valid_b;
            if(in_valid) begin
                gain<=next_gain;
                sample_left<=in_left;sample_right<=in_right;gain_a<=sample_gain;
            end
            if(valid_a) begin
                product_left<=$signed(sample_left)*$signed({1'b0,gain_a});
                product_right<=$signed(sample_right)*$signed({1'b0,gain_a});
            end
            if(valid_b) begin out_left<=rounded_left>>>15;out_right<=rounded_right>>>15;end
        end
    end
endmodule
