// Image-only RGB888 contrast. Resolution-independent, one pixel per clock.
// Configuration is synchronous to clk. Latest cfg_valid wins; apply at the
// end of the VS pulse, in vertical blanking. Reset/invalid level = 100%.
// Fixed three-cycle RGB/HS/VS/DE latency, including enable=0 bypass.
`default_nettype none
module contrast_adjust #(
    parameter VS_ACTIVE_HIGH=1'b1
)(
    input wire clk,rst,
    input wire cfg_valid,input wire [4:0] cfg_level,
    input wire enable,
    input wire hs_in,vs_in,de_in,input wire [23:0] rgb_in,
    output reg hs_out,vs_out,de_out,output reg [23:0] rgb_out
);
    reg [4:0] pending_level,frame_level;
    reg vs_active_d;
    wire vs_active=(vs_in==VS_ACTIVE_HIGH);
    wire [4:0] safe_cfg=(cfg_level<=20) ? cfg_level:5'd10;
    wire [4:0] pixel_level=enable ? frame_level:5'd10;
    always @(posedge clk or posedge rst) begin
        if(rst) begin pending_level<=10;frame_level<=10;vs_active_d<=0;end
        else begin
            vs_active_d<=vs_active;
            if(cfg_valid) pending_level<=safe_cfg;
            if(vs_active_d && !vs_active)
                frame_level<=cfg_valid ? safe_cfg:pending_level;
        end
    end

    // Signed products: (channel-128)*level. Explicit signed operands avoid
    // Verilog's unsigned promotion; 15 bits cover every possible product.
    function signed [14:0] product;
        input [7:0] channel;input [4:0] level;
        reg signed [8:0] delta;
        reg signed [5:0] gain;
        begin
            delta=$signed({1'b0,channel})-9'sd128;
            gain=$signed({1'b0,level});
            product=delta*gain;
        end
    endfunction
    // Add the midpoint and rounding bias before dividing. Clamp the positive
    // numerator first, so the final constant /10 has no signed divide logic.
    function [11:0] numerator;
        input signed [14:0] prod;
        reg signed [15:0] sum;
        begin
            sum=$signed({prod[14],prod})+16'sd1285;
            if(sum<0) numerator=0;
            else if(sum>2550) numerator=12'd2550;
            else numerator=sum[11:0];
        end
    endfunction
    reg signed [14:0] rp,gp,bp;
    reg [11:0] rn,gn,bn;
    reg [1:0] hp,vp,dp;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            rp<=0;gp<=0;bp<=0;rn<=0;gn<=0;bn<=0;
            hp<=0;vp<=0;dp<=0;hs_out<=0;vs_out<=0;de_out<=0;rgb_out<=0;
        end else begin
            rp<=product(rgb_in[23:16],pixel_level);
            gp<=product(rgb_in[15:8],pixel_level);
            bp<=product(rgb_in[7:0],pixel_level);
            rn<=numerator(rp);gn<=numerator(gp);bn<=numerator(bp);
            rgb_out[23:16]<=rn/12'd10;
            rgb_out[15:8]<=gn/12'd10;
            rgb_out[7:0]<=bn/12'd10;
            hp<={hp[0],hs_in};vp<={vp[0],vs_in};dp<={dp[0],de_in};
            hs_out<=hp[1];vs_out<=vp[1];de_out<=dp[1];
        end
    end
endmodule
`default_nettype wire
