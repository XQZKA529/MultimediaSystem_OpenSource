`timescale 1ns/1ps
module tb_ui_frame_ppm;
    reg clk=0,rst=1,hs=0,vs=0,de=0,active=0,text_page=0,commit=0,we=0;
    reg [3:0] ui_page=1;reg [3:0] cursor=2;reg [8:0] addr=0;reg [7:0] data=0;
    reg [3:0] brightness=10;reg [4:0] contrast=10,volume=20,saturation=10;reg osd_on=1;
    reg [23:0] pixel=0;wire [23:0] out;wire seen,af,pf,ho,vo,dout,hu,vu,du;wire [23:0] ui_rgb;
    wire [6:0] mc,cc;wire [3:0] mx,my,fx,fy;wire [1:0] ma,ca;wire clock_request;
    wire clock_reference_editing=af && ui_page==7;
    wire sh,sv,sd;wire [23:0] sat_pixel;
    saturation_adjust image_color(.clk(clk),.rst(rst),.cfg_valid(1'b1),.cfg_level(saturation),.enable(1'b1),
        .hs_in(hs),.vs_in(vs),.de_in(de),.rgb_in(pixel),.hs_out(sh),.vs_out(sv),.de_out(sd),.rgb_out(sat_pixel));
    function [7:0] sat_channel;input integer c,y,g;integer n;
        begin n=10*y+g*(c-y)+5;if(n<0)n=0;else if(n>2550)n=2550;sat_channel=n/10;end
    endfunction
    function [23:0] image_reference;input [23:0] c;input integer g;integer y;
        begin y=(77*c[23:16]+150*c[15:8]+29*c[7:0]+128)>>8;
            image_reference={sat_channel(c[23:16],y,g),sat_channel(c[15:8],y,g),sat_channel(c[7:0],y,g)};end
    endfunction
    `include "aa_font_reference.vh"
    `include "clock_visual_reference.vh"
    integer x,y,i,fp,count,cx,cy,scenario;reg capture=0;reg [7:0] rows[0:287];
    reg [23:0] bg[0:921599];reg [1023:0] bg_path,filename;
    always #5 clk=~clk;
    ui_text_overlay #(.EXTERNAL_FONT(1)) dut(.saturation_level(saturation),.video_clk(clk),.rst(rst),.hs(sh),.vs(sv),.de(sd),.pix_in(sat_pixel),.pix_out(ui_rgb),
        .hs_out(hu),.vs_out(vu),.de_out(du),.brightness_level(brightness),.brightness_frame(),
        .contrast_level(contrast),.volume_level(volume),.osd_enabled(osd_on),.text_osd_page(text_page),.ui_page(ui_page),
        .ui_active_frame(af),.text_osd_page_frame(pf),.ui_active(active),.ui_commit_toggle(commit),
        .cursor_row(cursor),.cursor_en(1'b1),.wr_clk(clk),.wr_en(we),.wr_addr(addr),.wr_data(data),
        .dbg_commit_seen(seen),.font_char(mc),.font_x(mx),.font_y(my),.font_alpha(ma));
    font_rom #(.SECOND_PORT(1)) shared_font(.clk(clk),.char_code(mc),.gx(mx),.gy(my),.alpha(ma),
        .char_code_b(cc),.gx_b(fx),.gy_b(fy),.alpha_b(ca));
    clock_overlay clock_layer(.clk(clk),.rst(rst),.hs(hu),.vs(vu),.de(du),.rgb_in(ui_rgb),
        .live_digits(48'h261014123456),.draft_digits(48'h000229235959),.focus(3'd2),.editing(clock_reference_editing),
        .font_request(clock_request),.font_char(cc),.font_x(fx),.font_y(fy),.font_alpha(ca),
        .hs_out(ho),.vs_out(vo),.de_out(dout),.rgb_out(out));
    task put;input integer row;input [255:0] s;integer k,n;reg [255:0] aligned;
        begin
            aligned=s;n=0;
            while(aligned[255:248]==0 && n<32) begin aligned=aligned<<8;n=n+1;end
            for(k=0;k<32;k=k+1) rows[row*32+k]=aligned[(31-k)*8 +: 8]==0 ? " ":aligned[(31-k)*8 +: 8];
        end
    endtask
    task snapshot;
        begin
            for(i=0;i<288;i=i+1) begin @(negedge clk);we=1;addr=i;data=rows[i];end
            @(negedge clk);we=0;commit=~commit;active=1;repeat(8) @(negedge clk);
            vs=1;repeat(3) @(negedge clk);vs=0;repeat(12) @(negedge clk);
            if(seen!==commit) $fatal(1,"snapshot not committed");
        end
    endtask
    // Capture only delayed output DE. No guessed pixel shifts or cropped edges.
    always @(posedge clk) begin
        #1;
        if(capture && dout) begin
            $fwrite(fp,"%c%c%c",out[23:16],out[15:8],out[7:0]);
            if(^out===1'bx) $fatal(1,"unknown RGB at output %0d",count);
            cx=count%1280;cy=count/1280;
            if(cx>=8 && cx<144 && cy>=8 && cy<60 && out!==clock_golden(cx,cy,image_reference(bg[count],saturation)))
                $fatal(1,"Clock on UI frame %0d",count);
            if(!(cx>=8 && cx<144 && cy>=8 && cy<60) && (cx<22 || cx>=1258 || cy<150 || cy>=570) && out!==image_reference(bg[count],saturation))
                $fatal(1,"bypass alignment %0d rgb=%h background=%h",count,out,bg[count]);
            count=count+1;
        end
    end
    task frame;input [1023:0] name;
        begin
            fp=$fopen(name,"wb");if(fp==0) $fatal(1,"cannot open frame");
            $fwrite(fp,"P6\n1280 720\n255\n");count=0;capture=1;
            for(y=0;y<720;y=y+1) begin
                for(x=0;x<1280;x=x+1) begin @(negedge clk);de=1;pixel=bg[y*1280+x];end
                @(negedge clk);de=0;hs=1;repeat(12) @(negedge clk);hs=0;
            end
            repeat(12) @(negedge clk);capture=0;
            if(count!=921600) $fatal(1,"frame size %0d",count);
            $fclose(fp);$display("FRAME %0s: %0d pixels, bypass matched",name,count);
        end
    endtask
    initial begin
        if(!$value$plusargs("BG=%s",bg_path)) bg_path="bg_rgb.hex";
        if(!$value$plusargs("CASE=%d",scenario)) scenario=1;
        $readmemh(bg_path,bg);
        for(i=0;i<288;i=i+1) rows[i]=" ";
        repeat(4) @(negedge clk);rst=0;
        case(scenario)
        0:begin ui_page=0;cursor=2;put(0,"FILE BROWSER");put(1,"[..] PARENT");put(2,"CORNFIELD.BMP");put(3,"YACHT.BMP");put(4,"SAILBOAT.BMP");put(5,"MUSIC.WAV");put(8,"2/8 SELECT  5 OPEN  # BACK");filename="ui_browser_frame.ppm";end
        1:begin
            ui_page=1;put(0,"SETTINGS");put(1,"SATURATION TRANSITION INTERVAL");put(2,"FILE BROWSER");put(3,"BRIGHTNESS");put(4,"CONTRAST");put(5,"TEXT OSD");put(6,"VOLUME");put(7,"SD SUBTITLE");put(8,"CLOCK");
            filename="ui_settings_frame.ppm";
        end
        2:begin ui_page=2;brightness=7;put(0,"BRIGHTNESS");put(6,"4/6: -/+10%   # BACK");filename="ui_brightness_frame.ppm";end
        3:begin ui_page=3;contrast=13;put(0,"CONTRAST");put(6,"4/6: -/+10%   # BACK");filename="ui_contrast_frame.ppm";end
        4:begin ui_page=4;volume=11;put(0,"VOLUME");put(6,"4/6: -/+5%    # BACK");filename="ui_volume_frame.ppm";end
        5:begin ui_page=1;cursor=6;brightness=8;contrast=12;volume=9;osd_on=0;put(0,"SETTINGS");put(2,"FILE BROWSER");put(3,"BRIGHTNESS");put(4,"CONTRAST");put(5,"TEXT OSD");put(6,"VOLUME");put(7,"SD SUBTITLE");put(8,"CLOCK");filename="ui_settings_volume_frame.ppm";end
        6:begin ui_page=5;cursor=2;put(0,"SD SUBTITLE");put(2,"DISPLAY     ON");put(3,"AUTO        ON");put(4,"CLEAR MANUAL");put(6,"FIRST LINE ONLY");put(8,"2/8 MOVE  5 SELECT  # BACK");filename="ui_sd_subtitle_frame.ppm";end
        7:begin ui_page=7;cursor=8;filename="ui_clock_editor_frame.ppm";end
        8:begin ui_page=8;cursor=2;put(0,"INTERVAL");put(2,"DELAY: 005 SEC");put(4,"4/6: -/+5 SEC");put(6,"# / KEY2 DOUBLE: BACK");put(8,"KEY3: CLOSE");filename="ui_interval_frame.ppm";end
        9,10,11:begin ui_page=9;saturation=scenario==9 ? 0:scenario==10 ? 10:20;put(0,"SATURATION");put(5,"IMAGE ONLY");put(6,"4/6: -/+10%   # BACK");
            if(scenario==9) filename="ui_saturation_0_frame.ppm";else if(scenario==10) filename="ui_saturation_100_frame.ppm";else filename="ui_saturation_200_frame.ppm";end
        default:$fatal(1,"unknown case");
        endcase
        snapshot;frame(filename);
        $display("*** PASS *** RTL UI frame export scenario %0d",scenario);$finish;
    end
endmodule
