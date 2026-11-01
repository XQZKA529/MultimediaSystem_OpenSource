// Bounded BMP probe. Arithmetic validation is registered outside byte decode.
module bmp_header_parser #(parameter MAX_DIM=4096)(
    input wire clk,rst,start,byte_valid,input wire [7:0] byte_data,
    input wire finish,input wire [31:0] actual_size,
    output reg done,ok,output reg [12:0] width,height,
    output reg [31:0] pixel_offset,row_stride,payload_end
);
    reg [5:0] lane;
    reg format_bytes_ok;
    reg [31:0] declared_size;
    reg [12:0] w,h;
    reg w_overflow,h_overflow,compression_nonzero;
    reg complete,format_ok,offset_ok;
    reg [2:0] state;
    // 13-bit dimensions and a <=24576-byte stride need 28 product bits.
    // A full 32-bit file offset plus that product needs 33 bits (no wrap).
    reg [27:0] span;
    reg [32:0] end_wide;
    reg [31:0] dib_end_offset;
    reg dib_end_carry,dib_end_overflow;
    // Capture raw DIB size here, then add 14 in the existing validation
    // stages. The raw size is no longer needed after state 1.
    wire [8:0] dib_end_low_sum={1'b0,dib_end_offset[7:0]}+9'd14;
    wire [24:0] dib_end_high_sum={1'b0,dib_end_offset[31:8]}+dib_end_carry;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            // Probe start initializes all data before validation consumes it.
            state<=0;done<=0;ok<=0;format_ok<=0;offset_ok<=0;
            dib_end_offset<=0;dib_end_carry<=0;dib_end_overflow<=0;
        end else if(start) begin
            lane<=6'd0;format_bytes_ok<=1;declared_size<=0;
            w<=0;h<=0;w_overflow<=0;h_overflow<=0;compression_nonzero<=0;complete<=0;state<=0;
            done<=0;ok<=0;pixel_offset<=0;format_ok<=0;offset_ok<=0;
            dib_end_offset<=0;dib_end_carry<=0;dib_end_overflow<=0;
        end else begin
            if(byte_valid && state==0) begin
                // Fixed fields have no consumer other than the final format
                // check. Complete headers visit every listed byte exactly once.
                case(lane)
                    0:format_bytes_ok<=format_bytes_ok && byte_data==8'h42;
                    1:format_bytes_ok<=format_bytes_ok && byte_data==8'h4d;
                    26:format_bytes_ok<=format_bytes_ok && byte_data==8'd1;
                    28:format_bytes_ok<=format_bytes_ok && byte_data==8'd24;
                    27,29:format_bytes_ok<=format_bytes_ok && byte_data==8'd0;
                    default:;
                endcase
                if((lane==6'd2)) declared_size[7:0]<=byte_data;
                if((lane==6'd3)) declared_size[15:8]<=byte_data;
                if((lane==6'd4)) declared_size[23:16]<=byte_data;
                if((lane==6'd5)) declared_size[31:24]<=byte_data;
                if((lane==6'd10)) pixel_offset[7:0]<=byte_data;
                if((lane==6'd11)) pixel_offset[15:8]<=byte_data;
                if((lane==6'd12)) pixel_offset[23:16]<=byte_data;
                if((lane==6'd13)) pixel_offset[31:24]<=byte_data;
                if((lane==6'd14)) dib_end_offset[7:0]<=byte_data;
                if((lane==6'd15)) dib_end_offset[15:8]<=byte_data;
                if((lane==6'd16)) dib_end_offset[23:16]<=byte_data;
                if((lane==6'd17)) dib_end_offset[31:24]<=byte_data;
                if((lane==6'd18)) w[7:0]<=byte_data;
                if((lane==6'd19)) begin w[12:8]<=byte_data[4:0];if(|byte_data[7:5]) w_overflow<=1;end
                if((lane==6'd20)||(lane==6'd21)) if(|byte_data) w_overflow<=1;
                if((lane==6'd22)) h[7:0]<=byte_data;
                if((lane==6'd23)) begin h[12:8]<=byte_data[4:0];if(|byte_data[7:5]) h_overflow<=1;end
                if((lane==6'd24)||(lane==6'd25)) if(|byte_data) h_overflow<=1;
                if((lane>=6'd30)&&(lane<=6'd33)&&(|byte_data)) compression_nonzero<=1;
                if((lane==6'd53)) complete<=1;
                if(lane<54) lane<=lane+1'b1;
            end
            case(state)
                0: if(finish) state<=1;
                1: begin
                    format_ok<=complete && format_bytes_ok && dib_end_offset>=40 &&
                        !compression_nonzero &&
                        !w_overflow && w!=0 && w<=MAX_DIM &&
                        !h_overflow && h!=0 && h<=MAX_DIM;
                    width<=w[12:0];height<=h[12:0];
                    row_stride<=({19'd0,w[12:0]}*3+3)&32'hfffffffc;
                    // Split the DIB end-offset addition at the byte boundary.
                    // The parser has several idle validation cycles, so this
                    // avoids feeding a 32-bit add directly into the final
                    // offset compare and the shared `ok` update mux.
                    dib_end_offset[7:0]<=dib_end_low_sum[7:0];
                    dib_end_carry<=dib_end_low_sum[8];
                    state<=2;
                end
                2: begin
                    dib_end_offset[31:8]<=dib_end_high_sum[23:0];
                    dib_end_overflow<=dib_end_high_sum[24];
                    state<=3;
                end
                3: begin
                    offset_ok<=pixel_offset>=54 && !dib_end_overflow &&
                               pixel_offset>=dib_end_offset;
                    state<=4;
                end
                4: begin span<={13'd0,row_stride[14:0]}*{15'd0,height};state<=5;end
                5: begin end_wide<={5'd0,span}+{1'b0,pixel_offset};state<=6;end
                6: begin
                    ok<=format_ok && offset_ok &&
                        end_wide<={1'b0,declared_size} && declared_size<=actual_size;
                    payload_end<=end_wide[31:0];done<=1;state<=7;
                end
                default: ;
            endcase
        end
    end
endmodule
