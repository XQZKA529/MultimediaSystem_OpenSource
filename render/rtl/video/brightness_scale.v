// Global RGB brightness, AFTER every overlay. Exact rounded percentage scaling.
// Two stages; sync and DE always follow the same path, including 100% bypass.
module brightness_scale(input wire clk,rst,input wire [3:0] level,
    input wire hs_in,vs_in,de_in,input wire [23:0] rgb_in,
    output reg hs_out,vs_out,de_out,output reg [23:0] rgb_out);
    reg [11:0] rp,gp,bp;
    reg h1,v1,d1;
    wire [3:0] safe_level=(level>=1 && level<=10) ? level:4'd10;
    always @(posedge clk or posedge rst) begin
        if(rst) begin rp<=0;gp<=0;bp<=0;h1<=0;v1<=0;d1<=0;hs_out<=0;vs_out<=0;de_out<=0;rgb_out<=0;end
        else begin
            rp<=({4'd0,rgb_in[23:16]}*{8'd0,safe_level})+12'd5;
            gp<=({4'd0,rgb_in[15:8]} *{8'd0,safe_level})+12'd5;
            bp<=({4'd0,rgb_in[7:0]}  *{8'd0,safe_level})+12'd5;
            h1<=hs_in;v1<=vs_in;d1<=de_in;
            hs_out<=h1;vs_out<=v1;de_out<=d1;
            rgb_out[23:16]<=rp/12'd10;
            rgb_out[15:8]<=gp/12'd10;
            rgb_out[7:0]<=bp/12'd10;
        end
    end
endmodule
