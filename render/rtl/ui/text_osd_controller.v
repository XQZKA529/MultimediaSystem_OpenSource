`include "../pkg/text_osd_model.vh"
// Owns configuration only. No device key codes, link state or video coordinates.
module text_osd_controller(
    input wire clk,rst,edit_enable,
    input wire up,down,left,right,confirm,
    output reg osd_enable,
    input wire [7:0] read_addr,output wire [7:0] read_data,
    output reg [`TEXT_OSD_LEN_W-1:0] text_len,
    output reg [4:0] focus_id,
    output wire [`TEXT_OSD_META_W-1:0] metadata,output reg [31:0] revision,
    output reg changed
);
    assign metadata={osd_enable,focus_id,text_len};
    reg [4:0] action;
    always @(posedge clk or posedge rst) begin
        if(rst) action<=0;
        else action<=edit_enable ? {confirm,right,left,down,up}:5'd0;
    end
    reg [4:0] next_focus;
    reg [2:0] col;
    always @(*) begin
        // Four constant ranges avoid a divider in the navigation path.
        if(focus_id<9) col=focus_id-2;
        else if(focus_id<16) col=focus_id-9;
        else if(focus_id<23) col=focus_id-16;
        else col=focus_id-23;
        next_focus=focus_id;
        if(action[0]) begin
            if(focus_id>=9) next_focus=focus_id-7;
            else if(focus_id>=2) next_focus=(col<4) ? 0:1;
        end else if(action[1]) begin
            if(focus_id==0) next_focus=2;
            else if(focus_id==1) next_focus=6;
            else if(focus_id<23) next_focus=focus_id+7;
        end else if(action[2]) begin
            if(focus_id==1) next_focus=0;
            else if(focus_id>=2 && col!=0) next_focus=focus_id-1'b1;
        end else if(action[3]) begin
            if(focus_id==0) next_focus=1;
            else if(focus_id>=2 && col!=6) next_focus=focus_id+1'b1;
        end
    end
    wire [7:0] input_char=(focus_id==28) ? 8'd32:(8'd65+{3'd0,focus_id}-8'd2);
    wire clear_text=edit_enable && action[4] && focus_id==1;
    wire delete_char=edit_enable && action[4] && focus_id==29 && text_len!=0;
    wire append_char=edit_enable && action[4] && focus_id>=2 && focus_id<=28 && text_len<`TEXT_OSD_MAX_LEN;
    wire [7:0] ram_data;
    reg read_valid;
    text_osd_ram u_edit(.wr_clk(clk),.wr_en(append_char && !rst),
        .wr_addr({1'b0,text_len[7:0]}),.wr_data(input_char),.rd_clk(clk),
        .rd_addr({1'b0,read_addr}),.rd_data(ram_data));
    always @(posedge clk) read_valid<=!rst && {1'b0,read_addr}<text_len;
    assign read_data=read_valid ? ram_data:8'd0;
    // Changes to text or metadata invalidate an in-flight snapshot copy.
    wire mutate=edit_enable && (action[4] ?
        (focus_id==0 || (clear_text && text_len!=0) || delete_char || append_char):
        next_focus!=focus_id);
    always @(posedge clk or posedge rst) begin
        if(rst) revision<=0;
        else if(mutate) revision<=revision+1'b1;
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin osd_enable<=0;text_len<=0;focus_id<=0;changed<=0;end
        else begin
            changed<=0;
            if(edit_enable) begin
                // Confirmation wins if two independent semantic inputs coincide.
                if(action[4]) begin
                    if(focus_id==0) begin osd_enable<=~osd_enable;changed<=1;end
                    else if(focus_id==1) begin text_len<=0;changed<=text_len!=0;end
                    else if(focus_id==29) begin
                        if(text_len!=0) begin
                            text_len<=text_len-1'b1;
                            changed<=1;
                        end
                    end else if(text_len<`TEXT_OSD_MAX_LEN) begin
                        text_len<=text_len+1'b1;changed<=1;
                    end
                end else if(next_focus!=focus_id) begin focus_id<=next_focus;changed<=1;end
            end
        end
    end
endmodule
