// Ready/valid byte-to-RGB adapter, including BMP's four-byte row alignment.
module bmp_pixel_unpack(
    input wire clk,rst,start,cancel,input wire [12:0] width,height,
    input wire [31:0] pixel_offset,row_stride,
    input wire byte_valid,input wire [7:0] byte_data,output wire byte_ready,
    output reg pixel_valid,output reg [23:0] pixel_rgb,input wire pixel_ready,
    output reg done
);
    reg [31:0] skip;
    reg [12:0] x,y;
    reg [1:0] phase,padding;
    reg [7:0] b,g;
    reg active;
    assign byte_ready=active && (!pixel_valid || pixel_ready);
    always @(posedge clk or posedge rst) begin
        if(rst) begin skip<=0;x<=0;y<=0;phase<=0;padding<=0;b<=0;g<=0;active<=0;pixel_valid<=0;pixel_rgb<=0;done<=0;end
        // cancel is a synchronous transaction command. It may come from a
        // multi-bit FSM decode and must never feed an asynchronous reset pin.
        else if(cancel) begin active<=0;pixel_valid<=0;done<=0;end
        else if(start) begin
            skip<=pixel_offset;x<=0;y<=0;phase<=0;
            padding<=row_stride[1:0]-(width*3); // modulo four, 0..3
            pixel_valid<=0;done<=0;active<=1;
        end else begin
            if(pixel_valid && pixel_ready) pixel_valid<=0;
            if(byte_valid && byte_ready) begin
                if(skip!=0) skip<=skip-1'b1;
                else if(y==height) done<=1; // Ignore legal trailing bytes.
                else case(phase)
                    0: begin b<=byte_data;phase<=1;end
                    1: begin g<=byte_data;phase<=2;end
                    2: begin
                        pixel_rgb<={byte_data,g,b};pixel_valid<=1;phase<=0;
                        if(x+1==width) begin x<=0;y<=y+1'b1;skip<=padding;end
                        else x<=x+1'b1;
                    end
                    default: ;
                endcase
            end
            if(active && y==height && skip==0 && (!pixel_valid || pixel_ready)) done<=1;
        end
    end
endmodule
