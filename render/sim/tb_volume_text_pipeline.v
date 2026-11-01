`timescale 1ns/1ps
// Both consumers use the actual shared dual-read ROM, with the Text OSD's
// synchronous byte contract. Checks the combined seven-clock stream at 720p.
module tb_volume_text_pipeline;
    reg clk=0,rst=1,hs=0,vs=0,de=0;reg [23:0] rgb=24'h123456;
    wire [23:0] text_rgb,result;wire th,tv,td,oh,ov,od;
    wire [7:0] ta;wire [6:0] tc,vc;wire [3:0] tx,ty,vx,vy;wire [1:0] a,b;
    reg [7:0] text_data;
    integer sx=0,sy=0,x=0,y=0,i,j,col,character,coverage,checks=0;
    reg [23:0] expected[0:6];reg [6:0] eh=0,ev=0,ed=0;
    always #5 clk=~clk;
    `include "aa_font_reference.vh"
    always @(posedge clk) text_data<=ta<106 ? 65+(ta%26):0;
    font_rom #(.SECOND_PORT(1)) font(.clk(clk),.char_code(tc),.gx(tx),.gy(ty),.alpha(a),
        .char_code_b(vc),.gx_b(vx),.gy_b(vy),.alpha_b(b));
    text_osd_overlay #(.EXTERNAL_FONT(1)) text_layer(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.pix_in(rgb),
        .ui_active_frame(1'b0),.text_osd_page_frame(1'b0),.diag_show(1'b0),
        .banner_source(1'b0),.banner_reset(1'b0),.view({1'b1,5'd0,9'd106}),.text_addr(ta),.text_data(text_data),
        .font_char(tc),.font_x(tx),.font_y(ty),.font_alpha(a),.hs_out(th),.vs_out(tv),.de_out(td),.pix_out(text_rgb));
    volume_overlay volume_layer(.clk(clk),.rst(rst),.hs(th),.vs(tv),.de(td),.pix_in(text_rgb),
        .show(1'b1),.level(5'd9),.font_char(vc),.font_x(vx),.font_y(vy),.font_alpha(b),
        .hs_out(oh),.vs_out(ov),.de_out(od),.pix_out(result));
    function [23:0] golden;
        input integer px,py;
        integer c,ch,cov,prev_c,prev_ch;reg [23:0] bg;
        begin
            golden=24'h123456;
            if(px>=192 && px<1088 && py>=64 && py<80) begin
                c=(px-192)/12;ch=65+c%26;cov=reference_alpha(ch,(px-192)%12,py-64);
                bg=24'h123456;
                if(px>192) begin
                    prev_c=(px-193)/12;prev_ch=65+prev_c%26;
                    if(reference_alpha(prev_ch,(px-193)%12,py-64)!=0) bg=reference_blend(24'h20252C,bg,1);
                end
                golden=reference_blend(24'hF5F7FA,bg,cov);
            end
            if(px>=904 && px<1264 && py>=552 && py<600) begin
                // Existing volume glass: (src + floor(src/2) + floor(tint/2))/4.
                golden=24'h091623;
                if(px==904 || px==1263 || py==552 || py==599) golden=24'hD6DBE1;
                else if(px>=916 && px<1048 && py>=557 && py<573) begin
                    c=(px-916)/12;
                    case(c)
                        0:ch=86;1:ch=79;2:ch=76;3:ch=85;4:ch=77;5:ch=69;6:ch=58;
                        7:ch=32;8:ch=52;9:ch=53;10:ch=37;default:ch=32;
                    endcase
                    cov=reference_alpha(ch,(px-916)%12,py-557);
                    golden=reference_blend(24'hF5F7FA,24'h14171B,cov);
                end else if(px>=916 && px<1236 && py>=582 && py<592)
                    golden=(px-916<144 && (px-916)%16<14) ? 24'hF5F7FA:24'h5A6068;
            end
        end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            for(j=0;j<7;j=j+1) expected[j]<=0;eh<=0;ev<=0;ed<=0;
        end else begin
            expected[0]<=de ? golden(sx,sy):rgb;
            for(j=1;j<7;j=j+1) expected[j]<=expected[j-1];
            eh<={eh[5:0],hs};ev<={ev[5:0],vs};ed<={ed[5:0],de};
            #1;
            if(result!==expected[6] || oh!==eh[6] || ov!==ev[6] || od!==ed[6])
                $fatal(1,"106-char/volume composite mismatch x=%d y=%d rgb=%h expected=%h",x,y,result,expected[6]);
            checks=checks+1;
        end
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;vs=1;repeat(5) @(negedge clk);vs=0;
        for(y=0;y<720;y=y+1) begin
            for(x=0;x<1280;x=x+1) begin @(negedge clk);de=1;sx=x;sy=y;end
            @(negedge clk);de=0;repeat(8) @(negedge clk);
        end
        repeat(8) @(negedge clk);
        $display("*** PASS *** %d full 720p composite pixels: 106-character banner + independent volume, concurrent font ports, seven-clock RGB/HS/VS/DE",checks);$finish;
    end
    initial begin #12000000;$fatal(1,"Composite watchdog");end
endmodule
