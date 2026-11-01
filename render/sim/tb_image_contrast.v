`timescale 1ns/1ps
`include "pkg/text_osd_model.vh"
`include "pkg/osd_model_bus.vh"
// Same ordering/commit wiring as render_core, with real diagnostic/menu/audio
// overlays. Synthetic pixels replace SDRAM only; every output pixel is checked.
module tb_image_contrast #(parameter TEXT_TEST=0);
    localparam W=192,H=80;
    reg clk=0,rst=1,h=0,v=0,d=0,image_enable=1,commit=0,seen_d=0,we=0;
    reg [4:0] level=10,saturation=10;reg [23:0] rgb=0;
    reg [8:0] address=0;reg [7:0] character=0;
    reg [`OSD_M_W-1:0] model=0;
    wire seen,hc,vc,dc,he,ve,de_,hp,vp,dp,ha,va,da;
    wire menu_active_frame,local_page_frame,mh,mv,md;
    wire [6:0] mchar,tchar;wire [3:0] mx,my,tx,ty;wire [1:0] alpha;
    wire menu_font=menu_active_frame && !local_page_frame;
    font_rom shared_font(.clk(clk),.char_code(menu_font ? mchar:tchar),
        .gx(menu_font ? mx:tx),.gy(menu_font ? my:ty),.alpha(alpha));
    wire [23:0] rc,rs,re,rp,ru,ra,raudio,rtext;wire sh,sv,sd;wire ah,av,ad,th,tv,td;
    reg [3:0] gain=10;reg [`TEXT_OSD_MODEL_W-1:0] text_view=0;
    integer xout=0,yout=0,frames=0,count=0,test_level=10,text_white_seen=0;
    reg vd=0,dd=0;reg [23:0] original,expected;
    always #5 clk=~clk;
    always @(posedge clk) if(rst) seen_d<=0;else seen_d<=seen;
    contrast_adjust contrast(.clk(clk),.rst(rst),.cfg_valid(seen!=seen_d),.cfg_level(level),.enable(image_enable),
        .hs_in(h),.vs_in(v),.de_in(d),.rgb_in(rgb),.hs_out(hc),.vs_out(vc),.de_out(dc),.rgb_out(rc));
    saturation_adjust saturation_stage(.clk(clk),.rst(rst),.cfg_valid(seen!=seen_d),.cfg_level(saturation),.enable(image_enable),
        .hs_in(hc),.vs_in(vc),.de_in(dc),.rgb_in(rc),.hs_out(sh),.vs_out(sv),.de_out(sd),.rgb_out(rs));
    error_overlay #(.TEXT_X(10),.TEXT_Y(45)) diagnostic(.video_clk(clk),.rst(rst),
        .hs(sh),.vs(sv),.de(sd),.pix_in(rs),.code(4'd5),.show(!TEXT_TEST),
        .hs_out(he),.vs_out(ve),.de_out(de_),.pix_out(re),.frame_black());
    assign hp=he;assign vp=ve;assign dp=de_;assign rp=re;
    ui_text_overlay #(.EXTERNAL_FONT(1),.WIN_X0(10),.WIN_Y0(6),.SCALE(1),.COLS(4),.LINES(2)) menu(.saturation_level(5'd10),
        .font_char(mchar),.font_x(mx),.font_y(my),.font_alpha(alpha),
        .video_clk(clk),.rst(rst),.hs(hp),.vs(vp),.de(dp),.pix_in(rp),.pix_out(ru),
        .hs_out(mh),.vs_out(mv),.de_out(md),.ui_page(3'd0),.contrast_level(level),.volume_level(5'd20),.osd_enabled(1'b1),
        .brightness_level(4'd10),.text_osd_page(1'b0),.ui_active(!TEXT_TEST),.ui_commit_toggle(commit),
        .cursor_row(4'd0),.cursor_en(1'b1),.wr_clk(clk),.wr_en(we),.wr_addr(address),
        .wr_data(character),.dbg_commit_seen(seen),.brightness_frame(),
        .ui_active_frame(menu_active_frame),.text_osd_page_frame(local_page_frame));
    audio_osd_overlay #(.PANEL_X0(100),.PANEL_Y0(6),.PANEL_W(80),.PANEL_H(25)) audio(
        .video_clk(clk),.rst(rst),.hs(mh),.vs(mv),.de(md),.pix_in(ru),.i_model(model),
        .hs_out(ah),.vs_out(av),.de_out(ad),.pix_out(raudio));
    wire [7:0] text_addr;reg [7:0] text_data;
    always @(posedge clk) text_data<=text_addr<text_view[`TEXT_OSD_LEN] ? text_view[text_addr*8 +: 8]:8'd0;
    text_osd_overlay #(.EXTERNAL_FONT(1),.SCREEN_W(W)) text_layer(.clk(clk),.rst(rst),.hs(ah),.vs(av),.de(ad),.pix_in(raudio),
        .font_char(tchar),.font_x(tx),.font_y(ty),.font_alpha(alpha),
        .ui_active_frame(menu_active_frame),.text_osd_page_frame(local_page_frame),.diag_show(!TEXT_TEST),.banner_source(1'b0),.banner_reset(1'b0),.view(text_view[`TEXT_OSD_MODEL_W-1:`TEXT_OSD_TEXT_W]),.text_addr(text_addr),.text_data(text_data),
        .hs_out(th),.vs_out(tv),.de_out(td),.pix_out(rtext));
    wire ch,cv,cd;wire [23:0] composited;
    video_stream_reg after_text(.clk(clk),.rst(rst),
        .hs_in(th),.vs_in(tv),.de_in(td),.rgb_in(rtext),
        .hs_out(ch),.vs_out(cv),.de_out(cd),.rgb_out(composited));
    brightness_scale final_brightness(.clk(clk),.rst(rst),.level(gain),
        .hs_in(ch),.vs_in(cv),.de_in(cd),.rgb_in(composited),.hs_out(ha),.vs_out(va),.de_out(da),.rgb_out(ra));
    function [23:0] pattern;input integer x,y;
        integer r,g,b;
        begin r=30+(x/4);g=150+(y/4);b=215+(x/12);pattern={r[7:0],g[7:0],b[7:0]};end
    endfunction
    function [7:0] dim;input [7:0] value;input [3:0] g;begin dim=(value*g+5)/10;end endfunction
    function [7:0] channel;input integer c,g;integer z;
        begin z=((c-128)*g+1285)/10;
            // Negative intermediate division truncates toward zero; both are
            // saturated to zero, so the oracle needs no signed floor helper.
            channel=(z<0) ? 0:((z>255) ? 255:z);
        end
    endfunction
    function [7:0] saturation_channel;input integer c,y,g;integer z;
        begin z=10*y+g*(c-y)+5;if(z<0)z=0;else if(z>2550)z=2550;saturation_channel=z/10;end
    endfunction
    function [23:0] sat_reference;input [23:0] c;input integer g;integer y;
        begin y=(77*c[23:16]+150*c[15:8]+29*c[7:0]+128)>>8;
            sat_reference={saturation_channel(c[23:16],y,g),saturation_channel(c[15:8],y,g),saturation_channel(c[7:0],y,g)};end
    endfunction
    `include "aa_font_reference.vh"
    integer cx=0,cy=0,sx=0,sy=0,txout=0,tyout=0,k,contrast_checks=0,composite_checks=0,saturation_checks=0;
    reg svold=0,sdold=0;reg [23:0] sexpected;
    reg cvold=0,cdold=0,tvold=0,tdold=0;
    reg [23:0] oracle[0:7];reg [7:0] oh=0,ov=0,od=0;
    function [23:0] text_reference;
        input integer x,y;input [23:0] base;
        reg [23:0] bg;reg [1:0] a;integer left;
        begin
            text_reference=base;left=(W-12)/2;
            if(TEXT_TEST && x>=left && x<left+12 && y>=64 && y<80) begin
                bg=base;
                if(x>left && reference_alpha("A",x-left-1,y-64)!=0)
                    bg=reference_blend(24'h20252C,base,1);
                a=reference_alpha("A",x-left,y-64);
                text_reference=reference_blend(24'hF5F7FA,bg,a);
                if(a!=0) text_white_seen=text_white_seen+1;
            end
        end
    endfunction
    // Independent math oracle at contrast output, followed by a eight-clock
    // Text OSD + output register + brightness scoreboard. No adjacent-pixel
    // tolerance and no captured constant baseline for transparent overlays.
    always @(posedge clk) begin
        if(rst) begin
            for(k=0;k<8;k=k+1) oracle[k]<=0;
            oh<=0;ov<=0;od<=0;txout=0;tyout=0;tvold=0;tdold=0;
        end else begin
            if(av && !tvold) begin txout=0;tyout=0;end
            if(!ad && tdold) begin txout=0;tyout=tyout+1;end
            expected=ad ? text_reference(txout,tyout,raudio):raudio;
            oracle[0]<={dim(expected[23:16],gain),dim(expected[15:8],gain),dim(expected[7:0],gain)};
            for(k=1;k<8;k=k+1) oracle[k]<=oracle[k-1];
            oh<={oh[6:0],ah};ov<={ov[6:0],av};od<={od[6:0],ad};
            if(ad) txout=txout+1;
            tvold=av;tdold=ad;
            #1;
            if((da && ra!==oracle[7]) || ha!==oh[7] || va!==ov[7] || da!==od[7])
                $fatal(1,"Text/brightness pixel or sync mismatch got=%h expected=%h",ra,oracle[7]);
            composite_checks=composite_checks+1;
        end
    end
    always @(negedge clk) if(!rst) begin
        if(vc && !cvold) begin cx=0;cy=0;end
        if(!dc && cdold) begin cx=0;cy=cy+1;end
        if(dc) begin
            original=pattern(cx,cy);
            expected=image_enable ? {channel(original[23:16],test_level),channel(original[15:8],test_level),channel(original[7:0],test_level)}:24'd0;
            if(rc!==expected) $fatal(1,"Contrast math x=%0d y=%0d got=%h expected=%h",cx,cy,rc,expected);
            contrast_checks=contrast_checks+1;cx=cx+1;
        end
        if(sv && !svold) begin sx=0;sy=0;end
        if(!sd && sdold) begin sx=0;sy=sy+1;end
        if(sd) begin
            original=pattern(sx,sy);
            sexpected=image_enable ? {channel(original[23:16],test_level),channel(original[15:8],test_level),channel(original[7:0],test_level)}:24'd0;
            if(image_enable) sexpected=sat_reference(sexpected,saturation);
            if(rs!==sexpected) $fatal(1,"Saturation pipeline x=%0d y=%0d got=%h expected=%h",sx,sy,rs,sexpected);
            saturation_checks=saturation_checks+1;sx=sx+1;
        end
        svold=sv;sdold=sd;
        cvold=vc;cdold=dc;
        if(va && !vd) begin xout=0;yout=0;frames=frames+1;end
        if(!da && dd) begin xout=0;yout=yout+1;end
        if(da) begin
            if(xout>=W || yout>=H) $fatal(1,"Output coordinates shifted");
            count=count+1;xout=xout+1;
        end
        vd=va;dd=da;
    end
    task step;input integer n;begin repeat(n) @(negedge clk);#1;end endtask
    task page;input integer want;
        integer j;
        begin
            level=want;
            for(j=0;j<8;j=j+1) begin we=1;address=j;character=(j==0) ? "C":" ";step(1);end
            we=0;step(4);commit=~commit;step(5);
        end
    endtask
    task frame;input integer want;
        integer x,y,start_count;
        begin
            page(want);test_level=want;start_count=count;
            v=1;d=0;step(24);v=0;step(24);
            if(seen!=commit) $fatal(1,"Menu configuration mailbox not committed");
            for(y=0;y<H;y=y+1) begin
                h=0;d=1;rgb=image_enable ? pattern(0,y):24'd0;
                for(x=0;x<W;x=x+1) begin step(1);if(x+1<W) rgb=image_enable ? pattern(x+1,y):24'd0;end
                d=0;h=1;step(18);
            end
            step(15);
            if(count-start_count!=W*H) $fatal(1,"Pixel count/alignment");
        end
    endtask
    initial begin
        model[`OSD_M_SHOW]=1;
        if(TEXT_TEST) begin text_view[`TEXT_OSD_ENABLE]=1;text_view[`TEXT_OSD_LEN]=1;text_view[7:0]="A";end
        step(4);rst=0;step(4);
        // Prime the multi-stage stream once so the first captured frame starts
        // with a valid pixel rather than the reset/blanking pipeline contents.
        frame(10);frames=0;count=0;
        frame(10);saturation=0;frame(0);saturation=20;frame(20);saturation=10;frame(6);
        image_enable=0;frame(0);
        if(TEXT_TEST) begin image_enable=1;gain=5;frame(20);end
        if(count<4*W*H) $fatal(1,"Insufficient pipeline coverage");
        if(TEXT_TEST && text_white_seen==0) $fatal(1,"Text OSD banner was not visible in the composed pipeline");
        $display("*** PASS *** image/text pipeline (text=%0d, gain=%0d): independent contrast math and eight-clock text/shadow/brightness pixel + HS/VS/DE oracle (%0d pixels)",TEXT_TEST,gain,count);
        $finish;
    end
    initial begin #2000000;$fatal(1,"Overlay watchdog");end
endmodule
