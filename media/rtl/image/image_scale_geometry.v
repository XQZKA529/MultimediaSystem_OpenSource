`include "../pkg/image_scale_modes.vh"
// One setup-time serial division; no variable divider in the pixel path.
module image_scale_geometry(
    input wire clk,rst,start,input wire [12:0] src_w,src_h,
    input wire [15:0] dst_w,dst_h,input wire [1:0] mode,
    output reg done,ok,output reg [15:0] scaled_w,scaled_h,left,bottom
);
    reg [3:0] state;
    reg wide;
    reg [12:0] second_src;reg [15:0] second_dst;
    wire [12:0] mul_src=start ? src_w:second_src;
    wire [15:0] mul_dst=start ? dst_h:second_dst;
    // Split operand selection from multiplication. These registers need no
    // reset: only values clocked by start and its following wait state are used.
    reg [12:0] mul_src_q;
    reg [15:0] mul_dst_q;
    always @(posedge clk) begin mul_src_q<=mul_src;mul_dst_q<=mul_dst;end
    wire [28:0] product=mul_src_q*mul_dst_q;
    reg [28:0] cross_w,cross_h,numerator,quotient;
    reg [13:0] remainder;
    reg [12:0] divisor;
    reg [4:0] bit_index;
    wire [13:0] shifted={remainder[12:0],numerator[28]};
    wire [13:0] reduced=shifted-{1'b0,divisor};
    wire [14:0] twice_remainder={remainder,1'b0};
    wire round_up=(twice_remainder>{2'd0,divisor}) ||
        (twice_remainder=={2'd0,divisor} && quotient[0]);
    reg round_latched;
    reg [15:0] rounded_dim;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            // Data is defined by setup states; only validity needs reset.
            state<=0;done<=0;ok<=0;
        end else if(start) begin
            done<=0;ok<=mode==`IMAGE_SCALE_CONTAIN && src_w!=0 && src_h!=0 && dst_w!=0 && dst_h!=0;
            second_src<=src_h;second_dst<=dst_w;state<=8;
        end else case(state)
            8:begin cross_w<=product;state<=1;end
            1:begin cross_h<=product;state<=2;end
            2: begin
                wide<=cross_w>=cross_h;
                numerator<=cross_w>=cross_h ? cross_h:cross_w;
                divisor<=cross_w>=cross_h ? src_w:src_h;
                quotient<=0;remainder<=0;bit_index<=29;state<=3;
            end
            3: begin
                numerator<=numerator<<1;
                quotient<={quotient[27:0],shifted>={1'b0,divisor}};
                remainder<=shifted>={1'b0,divisor} ? reduced:shifted;
                bit_index<=bit_index-1'b1;
                if(bit_index==1) state<=4;
            end
            4: begin round_latched<=round_up;state<=5;end
            // CONTAIN's quotient is bounded by the 16-bit target dimension.
            // Separate compare, increment and min-one selection timing paths.
            5: begin rounded_dim<=quotient[15:0]+round_latched;state<=6;end
            6: begin
                scaled_w<=wide ? dst_w:(rounded_dim==0 ? 16'd1:rounded_dim);
                scaled_h<=wide ? (rounded_dim==0 ? 16'd1:rounded_dim):dst_h;
                state<=7;
            end
            7: begin
                left<=(dst_w-scaled_w)>>1;
                // Storage runs bottom-up: odd extra padding belongs at bottom.
                bottom<=dst_h-scaled_h-((dst_h-scaled_h)>>1);
                done<=1;state<=0;
            end
            default: ;
        endcase
    end
endmodule
