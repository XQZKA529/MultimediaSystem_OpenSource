// Independent, two-clock video overlay. Font bytes come from a shared ROM
// read port, never from the Text OSD editor or its display banks.
module volume_overlay #(
    parameter X0=904,Y0=552,WIDTH=360,HEIGHT=48
)(
    input wire clk,rst,hs,vs,de,input wire [23:0] pix_in,
    input wire show,input wire [4:0] level,
    output wire [6:0] font_char,output wire [3:0] font_x,font_y,
    input wire [1:0] font_alpha,
    output wire hs_out,vs_out,de_out,output reg [23:0] pix_out
);
    function [23:0] glass_rgb;
        input [23:0] src; input [23:0] tint;
        reg [9:0] rr,gg,bb;
        begin rr={2'b0,src[23:16]}+({2'b0,src[23:16]}>>1)+({2'b0,tint[23:16]}>>1); gg={2'b0,src[15:8]}+({2'b0,src[15:8]}>>1)+({2'b0,tint[15:8]}>>1); bb={2'b0,src[7:0]}+({2'b0,src[7:0]}>>1)+({2'b0,tint[7:0]}>>1); glass_rgb={rr[9:2],gg[9:2],bb[9:2]}; end
    endfunction
    reg [10:0] x,y;reg de_d,vs_d;
    always @(posedge clk or posedge rst) begin
        if(rst) begin x<=0;y<=0;de_d<=0;vs_d<=0;end
        else begin
            de_d<=de;vs_d<=vs;
            if(vs && !vs_d) y<=0;else if(!de && de_d) y<=y+1'b1;
            if(!de) x<=0;else x<=x+1'b1;
        end
    end
    wire panel=show && x>=X0 && x<X0+WIDTH && y>=Y0 && y<Y0+HEIGHT;
    wire border=panel && (x==X0 || x==X0+WIDTH-1 || y==Y0 || y==Y0+HEIGHT-1);
    wire text=panel && x>=X0+12 && x<X0+144 && y>=Y0+5 && y<Y0+21;
    wire bar=panel && x>=X0+12 && x<X0+332 && y>=Y0+30 && y<Y0+40;
    wire [10:0] tx=x-(X0+12),ty=y-(Y0+5),bx=x-(X0+12);
    wire fill=bar && bx[3:0]<14 && bx<({6'd0,level}<<4);
    // Only 0..100 in steps of five. Constant /12 for character coordinates is
    // outside the RGB mux and registered before the synchronous font read.
    wire [3:0] col=tx/12;
    wire [4:0] tens=level>>1;
    reg [6:0] ch;
    always @(*) begin
        case(col)
            0:ch="V";1:ch="O";2:ch="L";3:ch="U";4:ch="M";5:ch="E";6:ch=":";
            7:ch=level==20 ? "1":" ";
            8:ch=level==20 ? "0":("0"+tens);
            9:ch=level[0] ? "5":"0";10:ch="%";
            default:ch=" ";
        endcase
    end
    reg [6:0] char_a;reg [3:0] gx_a,gy_a;
    reg [23:0] rgb_a,rgb_b;reg [1:0] hp,vp,dp;
    reg panel_a,panel_b,border_a,border_b,text_a,text_b,bar_a,bar_b,fill_a,fill_b;
    assign font_char=char_a;assign font_x=gx_a;assign font_y=gy_a;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            char_a<=32;gx_a<=0;gy_a<=0;rgb_a<=0;rgb_b<=0;hp<=0;vp<=0;dp<=0;
            panel_a<=0;panel_b<=0;border_a<=0;border_b<=0;text_a<=0;text_b<=0;bar_a<=0;bar_b<=0;fill_a<=0;fill_b<=0;
        end else begin
            char_a<=text ? ch:7'd32;gx_a<=tx%12;gy_a<=ty[3:0];
            rgb_a<=pix_in;rgb_b<=rgb_a;hp<={hp[0],hs};vp<={vp[0],vs};dp<={dp[0],de};
            panel_a<=panel;panel_b<=panel_a;border_a<=border;border_b<=border_a;
            text_a<=text;text_b<=text_a;bar_a<=bar;bar_b<=bar_a;fill_a<=fill;fill_b<=fill_a;
        end
    end
    `include "font_blend.vh"
    always @(*) begin
        pix_out=rgb_b;
        if(dp[1] && panel_b) begin
            if(border_b) pix_out=24'hD6DBE1;
            else if(text_b) pix_out=font_blend(24'hF5F7FA,24'h14171B,font_alpha);
            else if(bar_b) pix_out=fill_b ? 24'hF5F7FA:24'h5A6068;
            else pix_out=glass_rgb(rgb_b,24'h14171B);
        end
    end
    assign hs_out=hp[1];assign vs_out=vp[1];assign de_out=dp[1];
endmodule
