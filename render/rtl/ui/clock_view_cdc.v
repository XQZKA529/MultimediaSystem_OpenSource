// Stable bundled request/ack mailbox. A video reset forces republishing.
// Binary-to-BCD conversion is a shared, six-field, eight-step double dabble.
module clock_view_cdc(
    input wire clk,rst,input wire [32:0] live,draft,input wire [2:0] focus,input wire editing,
    input wire video_clk,video_rst,vs,
    output reg [47:0] live_digits,draft_digits,output reg [2:0] video_focus,output reg video_editing
);
    reg [69:0] captured;
    reg [95:0] digits;
    // Conversion registers are held for the complete four-phase handshake.
    // They serve directly as the mailbox; a second 100-bit copy is redundant.
    wire [99:0] mailbox={captured[69:66],digits};
    reg [3:0] field;
    reg [3:0] bit_count;
    reg [7:0] binary,bcd;
    reg [1:0] state;
    reg request,ack,alive,dirty;
    (* async_reg="true" *) reg ack1,ack2,req1,req2,alive1,alive2;
    reg vs_d;
    wire [69:0] desired={editing,focus,draft,live};
    function [7:0] get_field;
        input [32:0] t;input [2:0] f;
        begin case(f)
            0:get_field={1'b0,t[32:26]};1:get_field={4'd0,t[25:22]};
            2:get_field={3'd0,t[21:17]};3:get_field={3'd0,t[16:12]};
            4:get_field={2'd0,t[11:6]};default:get_field={2'd0,t[5:0]};
        endcase end
    endfunction
    reg [7:0] correction;
    always @(*) begin
        correction=bcd;
        if(bcd[3:0]>=5) correction[3:0]=bcd[3:0]+4'd3;
        if(bcd[7:4]>=5) correction[7:4]=bcd[7:4]+4'd3;
    end
    wire [7:0] next_bcd={correction[6:0],binary[7]};
    always @(posedge clk or posedge rst) begin
        if(rst) begin captured<=0;digits<=0;field<=0;bit_count<=0;binary<=0;bcd<=0;
            state<=0;request<=0;ack1<=0;ack2<=0;alive1<=0;alive2<=0;dirty<=1;end
        else begin
            ack1<=ack;ack2<=ack1;alive1<=alive;alive2<=alive1;
            if(!alive2) begin request<=0;state<=0;dirty<=1;end
            else case(state)
                0:if(!request && !ack2 && (dirty || desired!=captured)) begin
                    captured<=desired;field<=0;state<=1;
                end
                1:begin binary<=get_field(field<6 ? captured[32:0]:captured[65:33],field<6 ? field[2:0]:field-4'd6);
                    bcd<=0;bit_count<=0;state<=2;end
                2:begin
                    binary<={binary[6:0],1'b0};bcd<=next_bcd;bit_count<=bit_count+1'b1;
                    if(bit_count==7) begin
                        digits<={digits[87:0],next_bcd};
                        if(field==11) state<=3;else begin field<=field+1'b1;state<=1;end
                    end
                end
                3:if(!request) begin
                    // A changed source is rebuilt, never publish a partially converted draft.
                    if(desired!=captured) state<=0;
                    else begin request<=1;dirty<=0;end
                end else if(ack2) begin request<=0;state<=0;end
            endcase
        end
    end
    always @(posedge video_clk or posedge video_rst) begin
        if(video_rst) begin req1<=0;req2<=0;ack<=0;alive<=0;vs_d<=0;
            live_digits<=48'h000101000000;draft_digits<=48'h000101000000;video_focus<=0;video_editing<=0;end
        else begin
            alive<=1;req1<=request;req2<=req1;vs_d<=vs;
            if(!req2) ack<=0;
            else if(vs && !vs_d && !ack) begin
                {video_editing,video_focus,live_digits,draft_digits}<=mailbox;ack<=1;
            end
        end
    end
endmodule
