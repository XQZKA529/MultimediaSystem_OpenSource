`timescale 1ns/1ps
`include "pkg/text_osd_model.vh"
`include "pkg/osd_model_bus.vh"

// Full 1280x720 production compositor chain, including real bypass latency
// and the menu/Text/volume shared font. SDRAM is replaced by a deterministic
// color image; every active output pixel and every sync clock has an oracle.
module tb_text_osd_frame_ppm;
    localparam integer W=1280,H=720;
    reg clk=0,rst=1,hs=0,vs=0,de=0;
    reg ui_active=0,text_page=0,commit=0;
    reg [3:0] ui_page=1;reg [3:0] cursor_row=2;
    reg [23:0] pixel=0;
    reg [`TEXT_OSD_MODEL_W-1:0] view=0;
    reg [7:0] text_mem[0:255];
    wire ui_active_frame,text_osd_page_frame,commit_seen;
    wire [6:0] menu_char,text_char;wire [7:0] text_addr;
    wire [3:0] menu_x,menu_y,text_x,text_y;
    wire [1:0] menu_alpha,text_alpha;
    wire [23:0] ui_rgb,text_rgb;
    wire hs_ui,vs_ui,de_ui,hs_text,vs_text,de_text;
    wire [3:0] brightness_frame;
    reg [7:0] text_data;
    reg capture=0;
    integer fp=0,count=0,x=0,y=0,i,scenario=0,sx=0,sy=0,start,visible_len,k,checks=0;
    reg [7:0] chars[0:287];
    wire active=ui_active_frame,page=text_osd_page_frame,diag=1'b0;
    localparam REFERENCE_WIN_X=446,REFERENCE_WIN_Y=286,REFERENCE_SCREEN_W=W;
    `include "aa_font_reference.vh"
    `include "text_osd_visual_reference.vh"
    wire clock_reference_editing=1'b0;
    `include "clock_visual_reference.vh"
    localparam LATENCY=29;
    reg [23:0] oracle[0:LATENCY-1];reg [LATENCY-1:0] oh=0,ov=0,od=0;
    reg [1023:0] filename;

    always #5 clk=~clk;

    wire use_menu_font=ui_active_frame && !text_osd_page_frame;
    wire [6:0] clock_char;wire [3:0] clock_x,clock_y;wire clock_request;
    wire [6:0] volume_char;wire [3:0] volume_x,volume_y;wire [1:0] volume_alpha;
    font_rom #(.SECOND_PORT(1)) u_shared_font(.clk(clk),
        .char_code(use_menu_font ? menu_char:text_char),
        .gx(use_menu_font ? menu_x:text_x),.gy(use_menu_font ? menu_y:text_y),.alpha(menu_alpha),
        .char_code_b(clock_request ? clock_char:volume_char),.gx_b(clock_request ? clock_x:volume_x),.gy_b(clock_request ? clock_y:volume_y),.alpha_b(volume_alpha));
    assign text_alpha=menu_alpha;
    wire [23:0] contrast_rgb,error_rgb,audio_rgb,volume_rgb,registered_rgb,final_rgb;
    wire [23:0] normal_rgb,alarm_rgb;wire hnormal,vnormal,dnormal,halarm,valarm,dalarm;
    wire hc,vc,dc,he,ve,de_err,ha,va,da,hvol,vvol,dvol,hr,vr,dr,hfinal,vfinal,dfinal;
    contrast_adjust u_contrast(.clk(clk),.rst(rst),.cfg_valid(1'b0),.cfg_level(5'd10),.enable(1'b1),
        .hs_in(hs),.vs_in(vs),.de_in(de),.rgb_in(pixel),.hs_out(hc),.vs_out(vc),.de_out(dc),.rgb_out(contrast_rgb));
    error_overlay u_error(.video_clk(clk),.rst(rst),.hs(hc),.vs(vc),.de(dc),.pix_in(contrast_rgb),
        .show(1'b0),.code(4'd15),.hs_out(he),.vs_out(ve),.de_out(de_err),.pix_out(error_rgb),.frame_black());
    ui_text_overlay #(.EXTERNAL_FONT(1)) u_ui(.saturation_level(5'd10),
        .video_clk(clk),.rst(rst),.hs(he),.vs(ve),.de(de_err),.pix_in(error_rgb),.pix_out(ui_rgb),
        .hs_out(hs_ui),.vs_out(vs_ui),.de_out(de_ui),.brightness_level(4'd10),.brightness_frame(brightness_frame),
        .contrast_level(5'd10),.volume_level(5'd20),.osd_enabled(1'b1),.text_osd_page(text_page),.ui_page(ui_page),
        .ui_active_frame(ui_active_frame),.text_osd_page_frame(text_osd_page_frame),.ui_active(ui_active),
        .ui_commit_toggle(commit),.cursor_row(cursor_row),.cursor_en(1'b1),.wr_clk(clk),.wr_en(1'b0),
        .wr_addr(9'd0),.wr_data(8'd0),.dbg_commit_seen(commit_seen),.font_char(menu_char),.font_x(menu_x),.font_y(menu_y),.font_alpha(menu_alpha));

    audio_osd_overlay u_audio(.video_clk(clk),.rst(rst),.hs(hs_ui),.vs(vs_ui),.de(de_ui),.pix_in(ui_rgb),
        .i_model({`OSD_M_W{1'b0}}),.hs_out(ha),.vs_out(va),.de_out(da),.pix_out(audio_rgb));
    always @(posedge clk) text_data <= text_addr < view[`TEXT_OSD_LEN] ? text_mem[text_addr] : 8'd0;
    text_osd_overlay #(.EXTERNAL_FONT(1)) u_text(
        .clk(clk),.rst(rst),.hs(ha),.vs(va),.de(da),.pix_in(audio_rgb),
        .ui_active_frame(ui_active_frame),.text_osd_page_frame(text_osd_page_frame),.diag_show(1'b0),.banner_source(1'b0),.banner_reset(1'b0),
        .view(view[`TEXT_OSD_MODEL_W-1:`TEXT_OSD_TEXT_W]),.text_addr(text_addr),.text_data(text_data),
        .hs_out(hs_text),.vs_out(vs_text),.de_out(de_text),.pix_out(text_rgb),
        .font_char(text_char),.font_x(text_x),.font_y(text_y),.font_alpha(text_alpha));

    volume_overlay u_volume(.clk(clk),.rst(rst),.hs(hs_text),.vs(vs_text),.de(de_text),.pix_in(text_rgb),
        .show(1'b0),.level(5'd20),.font_char(volume_char),.font_x(volume_x),.font_y(volume_y),.font_alpha(volume_alpha),
        .hs_out(hvol),.vs_out(vvol),.de_out(dvol),.pix_out(volume_rgb));
    video_stream_reg u_output_reg(.clk(clk),.rst(rst),.hs_in(hvol),.vs_in(vvol),.de_in(dvol),.rgb_in(volume_rgb),
        .hs_out(hr),.vs_out(vr),.de_out(dr),.rgb_out(registered_rgb));
    brightness_scale u_brightness(.clk(clk),.rst(rst),.level(4'd10),.hs_in(hr),.vs_in(vr),.de_in(dr),.rgb_in(registered_rgb),
        .hs_out(hnormal),.vs_out(vnormal),.de_out(dnormal),.rgb_out(normal_rgb));
    emergency_overlay u_alarm(.clk(clk),.rst(rst),.hs(hnormal),.vs(vnormal),.de(dnormal),.rgb_in(normal_rgb),
        .enable(1'b0),.sources(3'd0),.groups(9'd0),.timestamps(144'd0),.hs_out(halarm),.vs_out(valarm),.de_out(dalarm),.rgb_out(alarm_rgb));
    clock_overlay u_clock(.clk(clk),.rst(rst),.hs(halarm),.vs(valarm),.de(dalarm),.rgb_in(alarm_rgb),
        .live_digits(48'h261014123456),.draft_digits(48'h000229235959),.focus(3'd2),.editing(1'b0),
        .font_request(clock_request),.font_char(clock_char),.font_x(clock_x),.font_y(clock_y),.font_alpha(volume_alpha),
        .hs_out(hfinal),.vs_out(vfinal),.de_out(dfinal),.rgb_out(final_rgb));
    always @(posedge clk) begin
        if(rst) begin
            for(k=0;k<LATENCY;k=k+1) oracle[k]<=0;
            oh<=0;ov<=0;od<=0;
        end else begin
            oracle[0]<=de ? clock_golden(sx,sy,golden(sx,sy,pixel)):pixel;
            for(k=1;k<LATENCY;k=k+1) oracle[k]<=oracle[k-1];
            oh<={oh[LATENCY-2:0],hs};ov<={ov[LATENCY-2:0],vs};od<={od[LATENCY-2:0],de};
            #1;
            if(hfinal!==oh[LATENCY-1] || vfinal!==ov[LATENCY-1] || dfinal!==od[LATENCY-1] ||
               (dfinal && final_rgb!==oracle[LATENCY-1]))
                $fatal(1,"Full production chain RGB/sync frame=%0d sample=%0d got=%h expected=%h",scenario,count,final_rgb,oracle[LATENCY-1]);
            if(dfinal) checks=checks+1;
        end
    end
    function [23:0] image_pattern;
        input integer px,py;
        integer r,g,b;
        begin
            r=24+(px/8);g=42+(py/4);b=92+((px+py)/8);
            image_pattern={r[7:0],g[7:0],b[7:0]};
        end
    endfunction

    task put_text;
        input integer n;input [255:0] s;integer j;
        begin for(j=0;j<n;j=j+1) text_mem[j]=s[(n-1-j)*8 +: 8]; end
    endtask

    task drive_blank;
        begin
            @(negedge clk);hs=0;vs=1;de=0;pixel=0;
            repeat(5) @(negedge clk);
            @(negedge clk);vs=0;
            repeat(24) @(negedge clk);
        end
    endtask

    always @(posedge clk) begin
        #1;
        if(capture && dfinal) begin
            if(count==0) $fwrite(fp,"P6\n1280 720\n255\n");
            $fwrite(fp,"%c%c%c",final_rgb[23:16],final_rgb[15:8],final_rgb[7:0]);
            count=count+1;
        end
    end

    task frame;
        integer py,px;
        begin
            count=0;capture=0;drive_blank;
            capture=1;
            for(py=0;py<H;py=py+1) begin
                hs=0;de=1;sx=0;sy=py;pixel=image_pattern(0,py);
                for(px=0;px<W;px=px+1) begin
                    @(negedge clk);if(px+1<W) begin sx=px+1;pixel=image_pattern(px+1,py);end
                end
                de=0;hs=1;repeat(8) @(negedge clk);
            end
            repeat(32) @(negedge clk);capture=0;
            if(count!=W*H) $fatal(1,"frame %0d pixel count %0d",scenario,count);
            $fclose(fp);
        end
    endtask

    task commit_ui;
        begin
            commit=~commit;repeat(5) @(negedge clk);drive_blank;
            if(commit_seen!==commit) $fatal(1,"UI commit was not observed");
        end
    endtask

    task export_case;
        input [1023:0] name;input active_i,page_i;input integer len;input [4:0] focus_i;
        integer j;
        begin
            filename=name;ui_active=active_i;text_page=page_i;view=0;
            view[`TEXT_OSD_ENABLE]=1;view[`TEXT_OSD_LEN]=len;view[`TEXT_OSD_FOCUS]=focus_i;
            for(j=0;j<len;j=j+1) begin text_mem[j]="A"+(j%26);view[j*8 +: 8]=text_mem[j];end
            build_chars;commit_ui;fp=$fopen(filename,"wb");if(fp==0) $fatal(1,"cannot open %s",filename);
            scenario=scenario+1;frame;
        end
    endtask

    initial begin
        for(i=0;i<256;i=i+1) text_mem[i]=8'd32;
        repeat(4) @(negedge clk);rst=0;repeat(8) @(negedge clk);
        export_case("text_osd_banner_short_frame.ppm",0,0,24,0);
        export_case("text_osd_banner_threshold75_frame.ppm",0,0,75,0);
        export_case("text_osd_banner_long_frame.ppm",0,0,106,0);
        export_case("text_osd_banner_max256_frame.ppm",0,0,256,0);
        export_case("text_osd_editor_normal_frame.ppm",1,1,24,0);
        export_case("text_osd_editor_focus_frame.ppm",1,1,256,17);
        $display("*** PASS *** Text OSD full-frame exports: %0d frames, %0d pixels each, clock + subtitle + full production exact RGB and 29-clock HS/VS/DE oracle",scenario,W*H);
        $finish;
    end
    initial begin #300000000;$fatal(1,"full-frame export timeout");end
endmodule
