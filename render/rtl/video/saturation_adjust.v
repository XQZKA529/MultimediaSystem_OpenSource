// Image-only RGB saturation, one pixel per clock. Configuration changes at VS end.
`default_nettype none
module saturation_adjust #(parameter VS_ACTIVE_HIGH=1'b1)(
 input wire clk,rst,cfg_valid,input wire [4:0] cfg_level,input wire enable,
 input wire hs_in,vs_in,de_in,input wire [23:0] rgb_in,
 output reg hs_out,vs_out,de_out,output reg [23:0] rgb_out
);
 reg [4:0] pending_level,frame_level;
 reg vs_d;
 wire vs_active=(vs_in==VS_ACTIVE_HIGH);
 wire [4:0] safe_cfg=cfg_level<=20 ? cfg_level:5'd10;
 wire [4:0] level=enable ? frame_level:5'd10;
 always @(posedge clk or posedge rst) begin
  if(rst) begin pending_level<=10;frame_level<=10;vs_d<=0;end
  else begin
   vs_d<=vs_active;
   if(cfg_valid) pending_level<=safe_cfg;
   if(vs_d && !vs_active) frame_level<=cfg_valid ? safe_cfg:pending_level;
  end
 end
 // Luma coefficients are expressed as shift/add networks to avoid DSP inference.
 function [16:0] luma_sum;
  input [23:0] c;
  reg [16:0] r,g,b;
  begin
   r={9'd0,c[23:16]};g={9'd0,c[15:8]};b={9'd0,c[7:0]};
   luma_sum=(r<<6)+(r<<3)+(r<<2)+r+(g<<7)+(g<<4)+(g<<2)+(g<<1)+(b<<4)+(b<<3)+(b<<2)+b+17'd128;
  end
 endfunction
 function signed [14:0] chroma_product;
  input [7:0] c,y;input [4:0] gain;
  reg signed [13:0] d,d3,lo,hi;
  begin
   d=$signed({1'b0,c})-$signed({1'b0,y});d3=d+(d<<<1);
   case(gain[1:0]) 0:lo=0;1:lo=d;2:lo=d<<<1;3:lo=d3;endcase
   case(gain[3:2]) 0:hi=0;1:hi=d;2:hi=d<<<1;3:hi=d3;endcase
   chroma_product=lo+(hi<<<2)+(gain[4]?(d<<<4):14'sd0);
  end
 endfunction
 function [11:0] numerator;
  input signed [14:0] chroma;input [7:0] y;
  reg signed [15:0] n;
  begin
   n=$signed({chroma[14],chroma})+$signed({5'd0,y,3'b000})+$signed({7'd0,y,1'b0})+16'sd5;
   if(n<0) numerator=0;
   else if(n>=2550) numerator=2550;
   else numerator=n[11:0];
  end
 endfunction
 // floor(n/10), exact for 0..2550: floor(n*3277/32768).
 function [7:0] div10;
  input [11:0] n;
  begin div10=n/12'd10;end
 endfunction
 reg [16:0] ysum;
 reg [23:0] rgb1;
 reg [4:0] gain1;
 reg signed [14:0] rp,gp,bp;
 reg [7:0] y2;
 reg [11:0] rn,gn,bn;
 reg [2:0] hp,vp,dp;
 always @(posedge clk or posedge rst) begin
  if(rst) begin ysum<=0;rgb1<=0;gain1<=10;rp<=0;gp<=0;bp<=0;y2<=0;rn<=0;gn<=0;bn<=0;hp<=0;vp<=0;dp<=0;hs_out<=0;vs_out<=0;de_out<=0;rgb_out<=0;end
  else begin
   ysum<=luma_sum(rgb_in);rgb1<=rgb_in;gain1<=level;
   rp<=chroma_product(rgb1[23:16],ysum[15:8],gain1);
   gp<=chroma_product(rgb1[15:8],ysum[15:8],gain1);
   bp<=chroma_product(rgb1[7:0],ysum[15:8],gain1);y2<=ysum[15:8];
   rn<=numerator(rp,y2);gn<=numerator(gp,y2);bn<=numerator(bp,y2);
   rgb_out<={div10(rn),div10(gn),div10(bn)};
   hp<={hp[1:0],hs_in};vp<={vp[1:0],vs_in};dp<={dp[1:0],de_in};
   hs_out<=hp[2];vs_out<=vp[2];de_out<=dp[2];
  end
 end
endmodule
`default_nettype wire
