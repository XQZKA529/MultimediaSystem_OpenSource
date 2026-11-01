`timescale 1ns/1ps
`include "../rtl/pkg/video_bmp_params.vh"
`include "../rtl/pkg/osd_model_bus.vh"

module tb_audio_osd_layout;
    localparam integer W=1280,H=720;
    localparam [23:0] BORDER=24'hD6DBE1;
    reg clk=0,rst=1,hs=0,vs=0,de=0;
    reg [10:0] in_x=0,in_y=0;
    reg [23:0] pix_in=0;
    reg [`OSD_M_W-1:0] model=0;
    wire [23:0] pix_out;wire hs_out,vs_out,de_out;
    wire [23:0] clock_rgb;wire hs_clock,vs_clock,de_clock;
    wire [6:0] clock_char;wire [3:0] clock_x,clock_y;wire [1:0] clock_alpha;wire clock_font_request;
    reg [23:0] ref_rgb0,ref_rgb1;reg ref_de0,ref_de1,ref_hs0,ref_hs1,ref_vs0,ref_vs1;
    reg [10:0] ref_x0,ref_y0,ref_x1,ref_y1;
    reg [`OSD_M_W-1:0] ref_model0,ref_model1;
    integer errors=0,checks=0,frame=0,x,y,b,fd,clock_pixels=0;
    reg [10:0] probe_x=0,probe_y=0;
    reg [59:0] probe_spec=0;
    reg probe_paused=0;
    wire probe_draw;wire [2:0] probe_ink;
    always #5 clk=~clk;

    audio_osd_overlay dut(.video_clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),
        .pix_in(pix_in),.i_model(model),.hs_out(hs_out),.vs_out(vs_out),
        .de_out(de_out),.pix_out(pix_out));
    font_rom #(.SECOND_PORT(1)) clock_font(.clk(clk),.char_code(7'd32),.gx(4'd0),.gy(4'd0),.alpha(),
        .char_code_b(clock_char),.gx_b(clock_x),.gy_b(clock_y),.alpha_b(clock_alpha));
    clock_overlay #(.FRAME_DIGITS(1)) clock_layer(.clk(clk),.rst(rst),.hs(hs_out),.vs(vs_out),.de(de_out),.rgb_in(pix_out),
        .live_digits(48'h261014123456),.draft_digits(48'h000229235959),.focus(3'd0),.editing(1'b0),
        .font_request(clock_font_request),.font_char(clock_char),.font_x(clock_x),.font_y(clock_y),.font_alpha(clock_alpha),
        .hs_out(hs_clock),.vs_out(vs_clock),.de_out(de_clock),.rgb_out(clock_rgb));
    osd_paint_anim single_band_probe(.clk(clk),.rst(rst),.lx(probe_x),.ly(probe_y),.heights(probe_spec),
        .paused(probe_paused),.draw(probe_draw),.ink(probe_ink));

    function [7:0] tint_chan;
        input [7:0] src,tint;
        reg [9:0] value;
        begin value={2'b0,src}+({2'b0,src}>>1)+({2'b0,tint}>>1);tint_chan=value[9:2];end
    endfunction
    function [23:0] glass_pixel;
        input [23:0] src;
        begin glass_pixel={tint_chan(src[23:16],8'd20),tint_chan(src[15:8],8'd23),tint_chan(src[7:0],8'd27)};end
    endfunction
    function [23:0] background_pixel;
        input integer px,py;
        integer r,g,bl;
        begin
            r=24+((px*3+py)%192);g=32+((py*2+px/4)%192);bl=48+((px+py*3)%176);
            background_pixel={r[7:0],g[7:0],bl[7:0]};
        end
    endfunction
    function [5:0] reference_band_map;
        input integer column;
        integer pos,base,rem,phase;
        begin
            pos=column*11;base=pos/79;rem=pos%79;phase=(rem*4+39)/79;
            if(phase==4) begin base=base+1;phase=0;end
            reference_band_map={base[3:0],phase[1:0]};
        end
    endfunction
    function [4:0] reference_bar_height;
        input [79:0] spec;
        input integer column;
        reg [5:0] mapping;
        integer base,phase,h0,h1,diff,step,value;
        begin
            mapping=reference_band_map(column);base=mapping[5:2];phase=mapping[1:0];
            h0=spec[base*5 +: 5];h1=base==11 ? h0:spec[(base+1)*5 +: 5];
            if(h0>22) h0=22;if(h1>22) h1=22;
            diff=h1>=h0 ? h1-h0:h0-h1;step=(diff*phase+2)/4;
            value=phase==0 || h0==h1 ? h0:(h1>=h0 ? h0+step:h0-step);
            reference_bar_height=value[4:0];
        end
    endfunction
    function [23:0] reference_output;
        input [10:0] px,py;
        input [23:0] src;
        input [`OSD_M_W-1:0] state;
        integer cell_x,bar_y,height,depth,inset,bar_left,bar_right;
        reg [4:0] bar_height;
        reg inside_bar,top_edge,panel,border;
        reg [23:0] glass;
        begin
            reference_output=src;
            cell_x=px%16;bar_y=711-py;
            bar_height=reference_bar_height(state[`OSD_M_SPEC],px/16);
            height=bar_height*4;
            inside_bar=state[`OSD_M_SHOW] && px<W && px/16<80 && py>=624 && py<712 &&
                       cell_x>=2 && cell_x<14 && bar_y>=0 && bar_y<height;
            if(inside_bar) begin
                depth=height-1-bar_y;
                inset=depth==0 ? 4:depth==1 ? 2:(depth==2 || depth==3) ? 1:0;
                bar_left=2+inset;bar_right=13-inset;
                if(cell_x>=bar_left && cell_x<=bar_right) begin
                    glass=glass_pixel(src);top_edge=(depth<2);
                    if(top_edge) reference_output={2'b11,src[23:18],2'b11,src[15:10],2'b11,src[7:2]};
                    else reference_output={1'b1,src[23:17],1'b1,src[15:9],1'b1,src[7:1]};
                end
            end
            panel=state[`OSD_M_SHOW] && px>=`VBP_OSD_X0 && px<`VBP_OSD_X0+`VBP_OSD_W &&
                  py>=`VBP_OSD_Y0 && py<`VBP_OSD_Y0+`VBP_OSD_H;
            border=panel && (px==`VBP_OSD_X0 || px==`VBP_OSD_X0+`VBP_OSD_W-1 ||
                    py==`VBP_OSD_Y0 || py==`VBP_OSD_Y0+`VBP_OSD_H-1);
            if(panel && border) reference_output=BORDER;
        end
    endfunction

    always @(posedge clk) begin
        if(rst) begin
            ref_de0<=0;ref_de1<=0;ref_hs0<=0;ref_hs1<=0;ref_vs0<=0;ref_vs1<=0;
            ref_rgb0<=0;ref_rgb1<=0;ref_x0<=0;ref_y0<=0;ref_x1<=0;ref_y1<=0;
            ref_model0<=0;ref_model1<=0;
        end else begin
            ref_de0<=de;ref_de1<=ref_de0;ref_hs0<=hs;ref_hs1<=ref_hs0;ref_vs0<=vs;ref_vs1<=ref_vs0;
            ref_rgb0<=reference_output(in_x,in_y,pix_in,model);ref_rgb1<=ref_rgb0;
            ref_x0<=in_x;ref_x1<=ref_x0;ref_y0<=in_y;ref_y1<=ref_y0;
            ref_model0<=model;ref_model1<=ref_model0;
            #1;
            if(de_out!==ref_de1 || hs_out!==ref_hs1 || vs_out!==ref_vs1)
                $fatal(1,"sync alignment frame=%0d @(x=%0d,y=%0d)",frame,ref_x1,ref_y1);
            if(de_out) begin
                checks=checks+1;
                if(!(ref_model1[`OSD_M_SHOW] && ref_x1>=`VBP_OSD_X0 && ref_x1<`VBP_OSD_X0+`VBP_OSD_W &&
                     ref_y1>=`VBP_OSD_Y0 && ref_y1<`VBP_OSD_Y0+`VBP_OSD_H &&
                     ref_x1!=`VBP_OSD_X0 && ref_x1!=`VBP_OSD_X0+`VBP_OSD_W-1 &&
                     ref_y1!=`VBP_OSD_Y0 && ref_y1!=`VBP_OSD_Y0+`VBP_OSD_H-1) && pix_out!==ref_rgb1) begin
                    errors=errors+1;
                    if(errors<5)$display("RGB mismatch mode=%0d @(x=%0d,y=%0d) got=%06x expected=%06x",ref_model1[`OSD_M_SHOW],ref_x1,ref_y1,pix_out,ref_rgb1);
                end
                if(ref_model1[`OSD_M_SHOW] && ref_x1>=`VBP_OSD_X0 && ref_x1<`VBP_OSD_X0+`VBP_OSD_W &&
                   ref_y1>=`VBP_OSD_Y0 && ref_y1<`VBP_OSD_Y0+`VBP_OSD_H &&
                   (ref_x1==`VBP_OSD_X0 || ref_x1==`VBP_OSD_X0+`VBP_OSD_W-1 ||
                    ref_y1==`VBP_OSD_Y0 || ref_y1==`VBP_OSD_Y0+`VBP_OSD_H-1) && pix_out!==BORDER)
                    $fatal(1,"playback card border moved or lost @(x=%0d,y=%0d)",ref_x1,ref_y1);
            end
            if(frame==0 && de_clock) begin
                $fwrite(fd,"%c%c%c",clock_rgb[23:16],clock_rgb[15:8],clock_rgb[7:0]);
                clock_pixels=clock_pixels+1;
            end
        end
    end

    task run_frame;
        input integer mode;
        begin
            frame=mode;
            model=0;model[`OSD_M_SHOW]=(mode!=3);model[`OSD_M_PAUSED]=(mode==1);
            model[`OSD_M_FILLPX]=`VBP_OSD_BAR_W/2;model[`OSD_M_TXT]=104'h36_35_3A_34_30_20_2F_20_33_32_3A_31_30;
            for(b=0;b<12;b=b+1) begin
                if(mode==2) model[128+b*5 +: 5]=0;
                else model[128+b*5 +: 5]=(b*2+2>22)?22:(b*2+2);
            end
            @(negedge clk);de=0;hs=0;vs=1;in_x=0;in_y=0;pix_in=0;
            repeat(4) @(negedge clk);vs=0;repeat(4) @(negedge clk);
            if(mode==0) begin fd=$fopen("audio_spectrum_layout.ppm","wb");if(!fd)$fatal(1,"frame open failed");$fwrite(fd,"P6\n1280 720\n255\n");clock_pixels=0;end
            for(y=0;y<H;y=y+1) begin
                for(x=0;x<W;x=x+1) begin
                    @(negedge clk);de=1;hs=0;vs=0;in_x=x;in_y=y;
                    pix_in=background_pixel(x,y);
                end
                @(negedge clk);de=0;hs=1;in_x=0;in_y=y;pix_in=0;
                @(negedge clk);hs=0;
            end
            repeat(5) @(negedge clk);
            if(mode==0) begin
                if(clock_pixels!=W*H)$fatal(1,"clock-composited preview pixel count %0d",clock_pixels);
                $fclose(fd);
            end
            if(errors) $fatal(1,"frame %0d had %0d pixel errors",mode,errors);
            $display("PASS frame %0d: 921600 RGB pixels, two-cycle sync, 80-bar geometry, 12-band interpolation, card placement, glass alpha and direct gaps",mode);
        end
    endtask

    task test_single_band_mapping;
        integer band,column,px,screen_y,from_bottom,height,depth,inset,left,right,paused_case;
        reg expected_draw;reg [2:0] expected_ink;reg [4:0] expected_height;
        begin
            for(band=0;band<12;band=band+1) begin
                probe_spec=0;probe_spec[band*5 +: 5]=5'd22;
                for(column=0;column<80;column=column+1) begin
                    for(screen_y=623;screen_y<=712;screen_y=screen_y+1) begin
                        from_bottom=711-screen_y;probe_y=screen_y-624;
                        expected_height=reference_bar_height(probe_spec,column);height=expected_height*4;
                        for(px=0;px<16;px=px+1) begin
                            probe_x=column*16+px;
                            expected_draw=0;expected_ink=0;depth=0;
                            if(screen_y>=624 && screen_y<=711 && from_bottom<height) begin
                                depth=height-1-from_bottom;
                                inset=depth==0 ? 4:depth==1 ? 2:(depth==2 || depth==3) ? 1:0;
                                left=2+inset;right=13-inset;
                                if(px>=left && px<=right) expected_draw=1;
                            end
                            for(paused_case=0;paused_case<2;paused_case=paused_case+1) begin
                                probe_paused=paused_case;#1;
                                expected_ink=!expected_draw ? 3'd0 : depth<2 ? `OSD_INK_HEAD :
                                             paused_case ? `OSD_INK_DIM : `OSD_INK_FILL;
                                if(probe_draw!==expected_draw || probe_ink!==expected_ink)
                                    $fatal(1,"single-band geometry band=%0d column=%0d px=%0d y=%0d got=%b/%d expected=%b/%d",band,column,px,screen_y,probe_draw,probe_ink,expected_draw,expected_ink);
                                checks=checks+1;
                            end
                        end
                    end
                end
            end
            // Minimum nonzero height (level 1, 4 px): the bar is the four cap rows only.
            probe_spec=0;probe_spec[0+:5]=5'd1;
            for(screen_y=706;screen_y<=713;screen_y=screen_y+1) begin
                from_bottom=711-screen_y;probe_y=screen_y-624;
                for(px=0;px<16;px=px+1) begin
                    probe_x=px;
                    expected_draw=0;depth=0;
                    if(screen_y>=708 && screen_y<=711) begin
                        depth=3-from_bottom;
                        inset=depth==0 ? 4:depth==1 ? 2:1;
                        left=2+inset;right=13-inset;
                        if(px>=left && px<=right) expected_draw=1;
                    end
                    probe_paused=0;#1;
                    expected_ink=!expected_draw ? 3'd0 : depth<2 ? `OSD_INK_HEAD : `OSD_INK_FILL;
                    if(probe_draw!==expected_draw || probe_ink!==expected_ink)
                        $fatal(1,"minimum-height bar px=%0d y=%0d got=%b/%d expected=%b/%d",px,screen_y,probe_draw,probe_ink,expected_draw,expected_ink);
                    checks=checks+1;
                end
            end
            probe_spec=0;probe_spec[0+:5]=5'd31;probe_x=8;probe_y=87;probe_paused=0;#1;
            if(!probe_draw)$fatal(1,"maximum-level input did not clamp and reach the bottom edge");
            checks=checks+1;
            $display("PASS 12 isolated bands: all 80 mapped columns and 16 px positions, rounded cap, two-row head, pause tint and height saturation");
        end
    endtask

    initial begin
        if(`VBP_OSD_W!=136 || `VBP_OSD_H!=52) $fatal(1,"Card must match clock plate dimensions");
        if(`VBP_OSD_TXT_X+78>`VBP_OSD_ICON_X0 ||
           `VBP_OSD_ICON_X0+`VBP_OSD_ICON_W>`VBP_OSD_X0+`VBP_OSD_W-2 ||
           `VBP_OSD_ICON_Y0+`VBP_OSD_ICON_H>`VBP_OSD_BAR_Y0 ||
           `VBP_OSD_BAR_X0+`VBP_OSD_BAR_W>`VBP_OSD_X0+`VBP_OSD_W-2 ||
           `VBP_OSD_BAR_Y0+`VBP_OSD_BAR_H>`VBP_OSD_Y0+`VBP_OSD_H-2)
            $fatal(1,"Compact playback contents overlap or escape card");
        repeat(8) @(negedge clk);rst=0;
        test_single_band_mapping;
        run_frame(0);run_frame(1);run_frame(2);run_frame(3);
        $display("*** PASS *** %0d full-frame RGB checks; play/pause/zero-spectrum/hidden modes; preview=audio_spectrum_layout.ppm",checks);
        $finish;
    end
endmodule
