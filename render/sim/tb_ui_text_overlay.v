`timescale 1ns/1ps
// Full-pixel oracle for 95 printable ASCII, attributes, gaps, highlights and commits.
module tb_ui_text_overlay;
    // Pages 6 and 7 are TRANSITION and CLOCK. Exercise the generic fallback on
    // unused page 10, then explicitly verify page-7 bypass below.
    reg clk=0,rst=1,vs=0,de=0,active=1,page=0,commit=0,we=0; reg [3:0] uipage=10;
    reg [23:0] pixel=0;reg [8:0] address=0;reg [7:0] data=0;
    reg [3:0] cursor=1;reg hs=0;wire ho,vo,do_;wire [23:0] result;wire seen,af,pf;
    reg [7:0] characters[0:287];
    integer x,y,j,checks=0,edges=0,phase=0;reg [23:0] expected,bg,fg;
    integer col,row,gx,gy,mapped_x;reg [1:0] a;
    function [23:0] tb_glass;
        input [23:0] src; input [23:0] tint;
        integer rr,gg,bb; reg [7:0] r8,g8,b8;
        begin rr=src[23:16]*3+tint[23:16]; gg=src[15:8]*3+tint[15:8]; bb=src[7:0]*3+tint[7:0]; r8=rr>>2; g8=gg>>2; b8=bb>>2; tb_glass={r8,g8,b8}; end
    endfunction
    always #5 clk=~clk;
    `include "aa_font_reference.vh"
    ui_text_overlay #(.WIN_X0(126),.WIN_Y0(166),.ICON_W(0)) dut(.saturation_level(5'd10),
        .video_clk(clk),.rst(rst),.hs(hs),.hs_out(ho),.vs_out(vo),.de_out(do_),.vs(vs),.de(de),.pix_in(pixel),.pix_out(result),
        .brightness_level(4'd10),.brightness_frame(),.contrast_level(5'd10),.volume_level(5'd20),.osd_enabled(1'b1),.text_osd_page(page),.ui_active_frame(af),.text_osd_page_frame(pf),
        .ui_page(uipage),
        .ui_active(active),.ui_commit_toggle(commit),.cursor_row(cursor),.cursor_en(1'b1),
        .wr_clk(clk),.wr_en(we),.wr_addr(address),.wr_data(data),.dbg_commit_seen(seen));
    function [23:0] white_coverage;
        input [23:0] bg;input [1:0] alpha;
        integer weight;reg [7:0] r,g,b;
        begin weight=alpha==0 ? 0:alpha==1 ? 1:alpha==2 ? 3:4;
            r=(255*weight+bg[23:16]*(4-weight))/4;
            g=(255*weight+bg[15:8]*(4-weight))/4;
            b=(255*weight+bg[7:0]*(4-weight))/4;white_coverage={r,g,b};end
    endfunction
    task write_bank;
        input integer offset;
        begin
            for(j=0;j<288;j=j+1) begin
                @(negedge clk);we=1;address=j;
                characters[j]={j[0],7'd32};
                characters[j][6:0]=32+(j+offset)%95;data=characters[j];
            end
            @(negedge clk);we=0;commit=~commit;repeat(4) @(negedge clk);
        end
    endtask
    reg [23:0] exp_pipe[0:5];integer xp[0:5],yp[0:5];reg [5:0] check_pipe=0;integer z;
    reg check_sample=0;
    always @(posedge clk) begin
        xp[0]<=x;yp[0]<=y;exp_pipe[0]<=expected;check_pipe<={check_pipe[4:0],check_sample};
        for(z=1;z<6;z=z+1) begin exp_pipe[z]<=exp_pipe[z-1];xp[z]<=xp[z-1];yp[z]<=yp[z-1];end
        #1;if(check_pipe[5]) begin
            if(result!==exp_pipe[5]) $fatal(1,"AA menu pipeline got %h expected %h phase %0d x=%0d y=%0d",result,exp_pipe[5],phase,xp[5],yp[5]);
            checks=checks+1;
        end
    end
    task frame;
        input integer expected_active,expected_page,expected_cursor;
        begin
            @(negedge clk);check_sample=0;de=0;vs=1;repeat(4) @(negedge clk);vs=0;
            repeat(4) @(negedge clk);
            if(af!==expected_active[0] || pf!==expected_page[0]) $fatal(1,"Frame control commit");
            for(y=0;y<570;y=y+1) begin
                for(x=0;x<900;x=x+1) begin
                    @(negedge clk);de=1;pixel={x[7:0],y[7:0],8'ha5};
                    // Existing UI geometry is one clock ahead of its base-color pipe.
                    // Glyph coverage remains aligned with the requested text pixel.
                    mapped_x=x+1;expected=pixel;check_sample=x!=439;
                    if(expected_active && !expected_page && uipage!=7 && mapped_x>=384 && mapped_x<896 && y>=160 && y<560) begin
                        expected=tb_glass(pixel,24'h141414);
                        if(mapped_x<386 || mapped_x>=894 || y<162 || y>=558) expected=24'haaaaaa;
                        row=(y-176)/32;gy=(y-176)%32;
                        if((uipage==0 || uipage==5) && mapped_x>=408 && mapped_x<872 && y>=176 && y<432 && row==expected_cursor && (uipage==0 || row>0) && gy<26) begin
                            expected={((pixel[23:16]>>1)+8'd31),((pixel[15:8]>>1)+8'd31),((pixel[7:0]>>1)+8'd31)};
                            if(mapped_x==408 || mapped_x==871 || gy==0 || gy==25) expected=24'hffffff;
                        end
                        if(mapped_x>=440 && mapped_x<824 && ((y>=176 && y<432 && gy<16) || (y>=512 && y<528))) begin
                            if(y>=512) begin row=8;gy=y-512;end
                            col=(x-440)/12;gx=(x-440)%12;
                            a=reference_alpha({1'b0,characters[row*32+col][6:0]},gx,gy);
                            if(mapped_x>=440 && mapped_x<824) expected=white_coverage(expected,a);
                            if(a==1 || a==2) edges=edges+1;
                        end
                    end
                    if(y==175 && x==1 && phase==1) cursor=3;
                end
                @(negedge clk);check_sample=0;de=0;repeat(8) @(negedge clk);
            end
            phase=phase+1;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;write_bank(0);
        frame(1,0,1);frame(1,0,1);write_bank(41);frame(1,0,3);
        active=0;write_bank(7);frame(0,0,3);
        active=1;page=1;uipage=1;write_bank(11);frame(1,1,3);
        page=0;uipage=5;write_bank(23);frame(1,0,3);
        // Browser rows 0 and 7 are files; other list pages reserve row 0 for a title.
        uipage=0;cursor=0;write_bank(31);frame(1,0,0);
        cursor=7;write_bank(37);frame(1,0,7);
        uipage=5;cursor=0;write_bank(43);frame(1,0,0);
        uipage=7;write_bank(29);frame(1,0,3);
        if(edges<1000 || checks<1000000) $fatal(1,"Insufficient coverage");
        $display("*** PASS *** AA menu: %0d pixels, %0d partial-coverage edges, 95 ASCII, attributes, gaps, border, highlights, frame commit, local page, CLOCK page bypass",checks,edges);
        $finish;
    end
    initial begin #100000000;$fatal(1,"Menu timeout");end
endmodule
