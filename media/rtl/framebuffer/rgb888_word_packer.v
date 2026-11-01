// Packs a byte-tight RGB888 pixel stream into the SDRAM's native 32-bit words.
// Four pixels become three words, with no colour-depth loss:
//   W0={R0,G0,B0,R1}, W1={G1,B1,R2,G2}, W2={B2,R3,G3,B3}.
`include "../pkg/video_bmp_params.vh"
module rgb888_word_packer #(
    parameter integer FRAME_PIXELS = `VBP_FRAME_PIXELS
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire        pixel_valid,
    input  wire [23:0] pixel_rgb,
    output reg         word_valid,
    output reg  [31:0] word_data,
    output reg         alignment_error,
    output reg         overflow_error
);
    reg [1:0]  phase;
    reg [23:0] carry;
    reg [19:0] pixel_count;

    // Phase zero captures the complete private carry before phase one
    // can publish a word. Reset/start always restore phase zero; public
    // word_data, valid and all error/counter state retain their reset values.
    always @(posedge clk)begin
        if(!rst && !frame_start && pixel_valid && !(pixel_count>=FRAME_PIXELS))begin
            case(phase)
                2'd0:carry<=pixel_rgb;
                2'd1:carry[15:0]<=pixel_rgb[15:0];
                2'd2:carry[7:0]<=pixel_rgb[7:0];
                default:;
            endcase
        end
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            phase           <= 2'd0;
            
            pixel_count     <= 20'd0;
            word_valid      <= 1'b0;
            word_data       <= 32'd0;
            alignment_error <= 1'b0;
            overflow_error  <= 1'b0;
        end else begin
            word_valid <= 1'b0;
            if (frame_start) begin
                if ((pixel_count != 0) &&
                    ((phase != 2'd0) || (pixel_count != FRAME_PIXELS)))
                    alignment_error <= 1'b1;
                phase       <= 2'd0;
                pixel_count <= 20'd0;
            end else if (pixel_valid) begin
                if (pixel_count >= FRAME_PIXELS) begin
                    overflow_error <= 1'b1;
                end else begin
                    pixel_count <= pixel_count + 1'b1;
                    case (phase)
                        2'd0: begin
                            
                            phase  <= 2'd1;
                        end
                        2'd1: begin
                            word_data  <= {carry, pixel_rgb[23:16]};
                            word_valid <= 1'b1;
                            
                            phase      <= 2'd2;
                        end
                        2'd2: begin
                            word_data  <= {carry[15:0], pixel_rgb[23:8]};
                            word_valid <= 1'b1;
                            
                            phase      <= 2'd3;
                        end
                        default: begin
                            word_data  <= {carry[7:0], pixel_rgb};
                            word_valid <= 1'b1;
                            phase      <= 2'd0;
                        end
                    endcase
                end
            end
        end
    end
endmodule
