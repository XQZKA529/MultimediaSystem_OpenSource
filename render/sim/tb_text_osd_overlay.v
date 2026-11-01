`timescale 1ns/1ps
`include "pkg/text_osd_model.vh"
module tb_text_osd_overlay;
    reg clk=0,rst=1,hs=0,vs=0,de=0,active=1,page=1,diag=0;
    reg [23:0] pixel=0;reg [`TEXT_OSD_MODEL_W-1:0] view=0;
    wire ho,vo,dout;wire [23:0] result;integer sx=0,sy=0,frame_id=0,i;
    reg [7:0] chars[0:287];
    reg [23:0] expected[0:4];reg [4:0] eh=0,ev=0,ed=0;
    integer checked=0,scan_width=400,n,start,visible_len;
    always #5 clk=~clk;
    wire [7:0] text_addr;reg [7:0] text_data;
    always @(posedge clk) text_data<=text_addr<view[`TEXT_OSD_LEN] ? view[text_addr*8 +: 8]:8'd0;
    text_osd_overlay #(.WIN_X0(2),.WIN_Y0(2)) dut(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.pix_in(pixel),
        .ui_active_frame(active),.text_osd_page_frame(page),.diag_show(diag),.banner_source(1'b0),.banner_reset(1'b0),.view(view[`TEXT_OSD_MODEL_W-1:`TEXT_OSD_TEXT_W]),.text_addr(text_addr),.text_data(text_data),
        .hs_out(ho),.vs_out(vo),.de_out(dout),.pix_out(result));
    `include "aa_font_reference.vh"
    localparam REFERENCE_WIN_X=2,REFERENCE_WIN_Y=2,REFERENCE_SCREEN_W=1280;
    `include "text_osd_visual_reference.vh"
    always @(posedge clk) begin
        if(rst) begin expected[0]<=0;expected[1]<=0;expected[2]<=0;expected[3]<=0;expected[4]<=0;eh<=0;ev<=0;ed<=0;end
        else begin
            expected[0]<=de ? golden(sx,sy,pixel):pixel;expected[1]<=expected[0];expected[2]<=expected[1];expected[3]<=expected[2];expected[4]<=expected[3];
            eh<={eh[3:0],hs};ev<={ev[3:0],vs};ed<={ed[3:0],de};
            #1;
            if(result!==expected[4] || ho!==eh[4] || vo!==ev[4] || dout!==ed[4])
                $fatal(1,"Pixel/sync mismatch at input (%d,%d) result %h expected %h focus %d",sx,sy,result,expected[4],view[`TEXT_OSD_FOCUS]);
            checked=checked+1;
        end
    end
    task drive;input h,v,d;input integer x,y;
        begin @(negedge clk);hs=h;vs=v;de=d;sx=x;sy=y;pixel=(frame_id<<20) ^ (y<<10) ^ x;end
    endtask
    task frame;integer x,y;
        begin
            build_chars;frame_id=frame_id+1;
            drive(0,1,0,0,0);repeat(4) drive(0,1,0,0,0);drive(0,0,0,0,0);
            for(y=0;y<160;y=y+1) begin
                for(x=0;x<scan_width;x=x+1) drive(0,0,1,x,y);
                repeat(4) drive(1,0,0,0,y);
            end
            repeat(5) drive(0,0,0,0,0);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;view[`TEXT_OSD_ENABLE]=1;view[`TEXT_OSD_LEN]=24;
        for(i=0;i<24;i=i+1) view[i*8 +: 8]="A";
        for(i=0;i<30;i=i+1) begin view[`TEXT_OSD_FOCUS]=i;frame;end
        active=0;page=0;scan_width=1280;frame;diag=1;frame;diag=0;view[`TEXT_OSD_ENABLE]=0;frame;
        view[`TEXT_OSD_ENABLE]=1;view[`TEXT_OSD_LEN]=0;frame;
        active=1;page=0;scan_width=400;frame;page=1;view[`TEXT_OSD_FOCUS]=0;frame;
        // Cover the static-centering boundary and both sides of full capacity.
        for(i=0;i<256;i=i+1) view[i*8 +: 8]="A"+i%26;
        for(n=0;n<10;n=n+1) begin
            case(n) 0:i=1;1:i=74;2:i=75;3:i=106;4:i=107;5:i=254;6:i=255;7:i=256;8:i=0;default:i=30;endcase
            view[`TEXT_OSD_LEN]=i;active=1;page=1;scan_width=400;frame;
            active=0;page=0;scan_width=1280;frame;
        end
        if(checked<2000000) $fatal(1,"Insufficient pixel coverage");
        $display("*** PASS *** Text OSD pixels: %0d checks, 30 highlights, alphabet/preview/cursor, banner, hides, 5-stage sync/bypass",checked);$finish;
    end
    initial begin #90000000;$fatal(1,"Overlay timeout");end
endmodule
