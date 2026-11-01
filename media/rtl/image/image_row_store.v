// One tightly packed RGB888 row. 1280 pixels use 960x32 (four BRAM9K).
module image_row_store #(parameter WIDTH=1280)(
    input wire clk,rst,write_start,write_valid,input wire [23:0] write_rgb,
    input wire read_start,output reg pixel_valid,output reg [23:0] pixel_rgb,
    input wire pixel_ready
);
    localparam WORDS=WIDTH*3/4, AW=$clog2(WORDS);
    reg [31:0] mem[0:WORDS-1] /* fehdl force_ram=1, ram_style="bram" */;
    wire packed_valid;wire [31:0] packed_data;
    reg [AW-1:0] wa,ra;
    reg [31:0] q;
    reg [1:0] phase;
    reg [23:0] carry;
    reg [15:0] count;
    reg [2:0] state;
    rgb888_word_packer #(.FRAME_PIXELS(WIDTH)) pack(
        .clk(clk),.rst(rst),.frame_start(write_start),.pixel_valid(write_valid),
        .pixel_rgb(write_rgb),.word_valid(packed_valid),.word_data(packed_data),
        .alignment_error(),.overflow_error());
    always @(posedge clk) begin
        if(packed_valid) mem[wa]<=packed_data;
        q<=mem[ra];
    end
    always @(posedge clk or posedge rst) begin
        // Addresses/data initialize on write_start/read_start before valid output.
        if(rst) begin state<=0;pixel_valid<=0;end
        else begin
            if(write_start) wa<=0;
            else if(packed_valid) wa<=wa+1'b1;
            if(read_start) begin ra<=0;phase<=0;count<=0;pixel_valid<=0;state<=1;end
            else case(state)
                1: state<=2;
                2: state<=3;
                3: begin
                    case(phase)
                        0: begin pixel_rgb<=q[31:8];carry<={16'd0,q[7:0]};end
                        1: begin pixel_rgb<={carry[7:0],q[31:16]};carry<={8'd0,q[15:0]};end
                        2: begin pixel_rgb<={carry[15:0],q[31:24]};carry<=q[23:0];end
                        3: pixel_rgb<=carry;
                    endcase
                    pixel_valid<=1;state<=4;
                end
                4: if(pixel_valid && pixel_ready) begin
                    pixel_valid<=0;count<=count+1'b1;phase<=phase+1'b1;
                    if(count==WIDTH-1) state<=0;
                    else if(phase==2) begin pixel_rgb<=carry;pixel_valid<=1;end
                    else begin
                        ra<=ra+1'b1;
                        state<=1;
                    end
                end
                default: ;
            endcase
        end
    end
endmodule
