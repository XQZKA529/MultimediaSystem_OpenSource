# Text OSD 完整实现代码

顶部居中、最多106字符的当前实现。源码文件是维护入口；接线及验证见 [实现记录](text-osd-2026-10-08.md)。

## pkg/text_osd_model.vh

```verilog
`ifndef TEXT_OSD_MODEL_VH
`define TEXT_OSD_MODEL_VH
// Render-local model. Byte i occupies TEXT[i*8 +: 8]; byte len is NUL.
// 1280 active pixels / 12 pixels per character: one full top row.
`define TEXT_OSD_MAX_LEN 106
`define TEXT_OSD_BYTES (`TEXT_OSD_MAX_LEN+1)
`define TEXT_OSD_TEXT_W (`TEXT_OSD_BYTES*8)
`define TEXT_OSD_LEN_W 7
`define TEXT_OSD_TEXT (`TEXT_OSD_TEXT_W-1):0
`define TEXT_OSD_LEN (`TEXT_OSD_TEXT_W+`TEXT_OSD_LEN_W-1):`TEXT_OSD_TEXT_W
`define TEXT_OSD_FOCUS (`TEXT_OSD_TEXT_W+`TEXT_OSD_LEN_W+4):(`TEXT_OSD_TEXT_W+`TEXT_OSD_LEN_W)
`define TEXT_OSD_ENABLE (`TEXT_OSD_TEXT_W+`TEXT_OSD_LEN_W+5)
`define TEXT_OSD_MODEL_W (`TEXT_OSD_TEXT_W+`TEXT_OSD_LEN_W+6)
`endif
```

## ui/text_osd_controller.v

```verilog
`include "../pkg/text_osd_model.vh"
// Owns configuration only. No device key codes, link state or video coordinates.
module text_osd_controller(
    input wire clk,rst,edit_enable,
    input wire up,down,left,right,confirm,
    output reg osd_enable,
    output wire [`TEXT_OSD_TEXT_W-1:0] text_buf,
    output reg [`TEXT_OSD_LEN_W-1:0] text_len,
    output reg [4:0] focus_id,
    output wire [`TEXT_OSD_MODEL_W-1:0] model,
    output reg changed
);
    assign model={osd_enable,focus_id,text_len,text_buf};
    reg [4:0] action;
    always @(posedge clk or posedge rst) begin
        if(rst) action<=0;
        else action<=edit_enable ? {confirm,right,left,down,up}:5'd0;
    end
    reg [4:0] next_focus;
    reg [2:0] col;
    always @(*) begin
        // Four constant ranges avoid a divider in the navigation path.
        if(focus_id<9) col=focus_id-2;
        else if(focus_id<16) col=focus_id-9;
        else if(focus_id<23) col=focus_id-16;
        else col=focus_id-23;
        next_focus=focus_id;
        if(action[0]) begin
            if(focus_id>=9) next_focus=focus_id-7;
            else if(focus_id>=2) next_focus=(col<4) ? 0:1;
        end else if(action[1]) begin
            if(focus_id==0) next_focus=2;
            else if(focus_id==1) next_focus=6;
            else if(focus_id<23) next_focus=focus_id+7;
        end else if(action[2]) begin
            if(focus_id==1) next_focus=0;
            else if(focus_id>=2 && col!=0) next_focus=focus_id-1'b1;
        end else if(action[3]) begin
            if(focus_id==0) next_focus=1;
            else if(focus_id>=2 && col!=6) next_focus=focus_id+1'b1;
        end
    end
    wire [7:0] input_char=(focus_id==28) ? 8'd32:(8'd65+{3'd0,focus_id}-8'd2);
    wire clear_text=edit_enable && action[4] && focus_id==1;
    wire delete_char=edit_enable && action[4] && focus_id==29 && text_len!=0;
    wire append_char=edit_enable && action[4] && focus_id>=2 && focus_id<=28 && text_len<`TEXT_OSD_MAX_LEN;
    // Fixed byte lanes avoid wide dynamic-write barrel logic. All bytes beyond
    // length stay zero, so the terminator is also maintained on every append.
    genvar byte_id;
    generate for(byte_id=0;byte_id<`TEXT_OSD_BYTES;byte_id=byte_id+1) begin: g_text
        reg [7:0] character;
        always @(posedge clk or posedge rst) begin
            if(rst) character<=0;
            else if(clear_text || (delete_char && text_len==byte_id+1)) character<=0;
            else if(append_char && text_len==byte_id) character<=input_char;
        end
        assign text_buf[byte_id*8 +: 8]=character;
    end endgenerate
    always @(posedge clk or posedge rst) begin
        if(rst) begin osd_enable<=0;text_len<=0;focus_id<=0;changed<=0;end
        else begin
            changed<=0;
            if(edit_enable) begin
                // Confirmation wins if two independent semantic inputs coincide.
                if(action[4]) begin
                    if(focus_id==0) begin osd_enable<=~osd_enable;changed<=1;end
                    else if(focus_id==1) begin text_len<=0;changed<=text_len!=0;end
                    else if(focus_id==29) begin
                        if(text_len!=0) begin
                            text_len<=text_len-1'b1;
                            changed<=1;
                        end
                    end else if(text_len<`TEXT_OSD_MAX_LEN) begin
                        text_len<=text_len+1'b1;changed<=1;
                    end
                end else if(next_focus!=focus_id) begin focus_id<=next_focus;changed<=1;end
            end
        end
    end
endmodule
```

## ui/text_osd_event_router.v

```verilog
// Device-neutral event ownership. The encoder remains unaware of menus.
module text_osd_event_router(
    input wire clk,rst,link_up,session_reset,input_cancel,
    input wire ui_active,text_osd_page,ui_commit_toggle,ui_commit_seen,
    input wire event_valid,input wire [5:0] event_data,output wire event_ready,
    output wire remote_valid,output wire [5:0] remote_data,input wire remote_ready,
    output wire encoder_cancel,edit_enable,up,down,left,right,confirm
);
    (* async_reg="true" *) reg ack1,ack2;
    reg commit_seen,fresh,owner_d,ready_d,exit_pending;
    wire new_snapshot=ui_commit_toggle!=commit_seen;
    wire owner=fresh && ui_active && text_osd_page;
    wire ready_local=link_up && !session_reset && owner &&
                     ack2==ui_commit_toggle && !exit_pending;
    assign encoder_cancel=(owner!=owner_d) || (ready_local && !ready_d);
    wire cancel_ev=event_data[5:4]==3;
    wire back_ev=event_data[3:0]==14;
    // During transitions discard editing events, but always drain CANCEL.
    wire forward=cancel_ev || (fresh && (!owner || (back_ev && !exit_pending)));
    assign remote_valid=event_valid && forward && link_up && !session_reset &&
                        (!encoder_cancel || cancel_ev) && (!input_cancel || cancel_ev);
    assign remote_data=event_data;
    assign event_ready=forward ? remote_ready && link_up && !session_reset &&
                       (!encoder_cancel || cancel_ev) && (!input_cancel || cancel_ev):1'b1;
    wire fire=event_valid && event_ready;
    wire press=event_data[5:4]==0;
    wire nav_ev=press || event_data[5:4]==2;
    assign edit_enable=ready_local && !encoder_cancel && !input_cancel;
    assign up=fire && edit_enable && nav_ev && event_data[3:0]==1;
    assign down=fire && edit_enable && nav_ev && event_data[3:0]==9;
    assign left=fire && edit_enable && nav_ev && event_data[3:0]==4;
    assign right=fire && edit_enable && nav_ev && event_data[3:0]==6;
    assign confirm=fire && edit_enable && press && event_data[3:0]==5;
    always @(posedge clk or posedge rst) begin
        if(rst) begin ack1<=0;ack2<=0;commit_seen<=0;fresh<=0;owner_d<=0;ready_d<=0;exit_pending<=0;end
        else begin
            ack1<=ui_commit_seen;ack2<=ack1;
            commit_seen<=ui_commit_toggle;owner_d<=owner;ready_d<=ready_local;
            if(!link_up || session_reset) begin fresh<=0;exit_pending<=0;end
            else begin
                if(new_snapshot) begin
                    fresh<=1;
                    // An older local-page snapshot cannot undo a requested exit.
                    if(!ui_active || !text_osd_page) exit_pending<=0;
                end
                if(fire && remote_valid && owner && back_ev && press) exit_pending<=1;
            end
        end
    end
endmodule
```

## ui/text_osd_view_cdc.v

```verilog
`include "../pkg/text_osd_model.vh"
// Bundled-data mailbox: hold the entire model until VS acknowledgement returns.
module text_osd_view_cdc(
    input wire clk,rst,input wire [`TEXT_OSD_MODEL_W-1:0] model,
    input wire video_clk,video_rst,vs,
    output reg [`TEXT_OSD_MODEL_W-1:0] view
);
    (* no_ram=1 *) reg [`TEXT_OSD_MODEL_W-1:0] mailbox,last_sent;
    localparam DIFF_CHUNKS=(`TEXT_OSD_MODEL_W+31)/32;
    wire [DIFF_CHUNKS*32-1:0] model_padded=model,last_padded=last_sent;
    reg [DIFF_CHUNKS-1:0] difference;
    genvar chunk;
    // Pipeline the wide comparison before its result drives mailbox enables.
    // A delayed difference may send a redundant view, but always samples the
    // current complete model; updates while busy still converge to the latest.
    generate for(chunk=0;chunk<DIFF_CHUNKS;chunk=chunk+1) begin: g_difference
        always @(posedge clk or posedge rst) begin
            if(rst) difference[chunk]<=0;
            else difference[chunk]<=model_padded[chunk*32 +: 32]!=last_padded[chunk*32 +: 32];
        end
    end endgenerate
    reg request,ack,dirty,alive,alive_d,vs_d;
    (* async_reg="true" *) reg ack1,ack2,alive1,alive2,req1,req2;
    wire publish=alive2 && request==ack2 && (dirty || |difference);
    wire consume=vs && !vs_d && req2!=ack;
    // Domain reset synchronizers hold reset across at least two clock edges.
    // Clear the wide data banks synchronously; reset handshake/control flops
    // asynchronously. This avoids thousands of asynchronous reset sinks.
    always @(posedge clk) begin
        if(rst) begin mailbox<=0;last_sent<=0;end
        else if(publish) begin mailbox<=model;last_sent<=model;end
    end
    always @(posedge video_clk) begin
        if(video_rst) view<=0;
        else if(consume) view<=mailbox;
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin request<=0;dirty<=1;ack1<=0;ack2<=0;alive1<=0;alive2<=0;alive_d<=0;end
        else begin
            ack1<=ack;ack2<=ack1;alive1<=alive;alive2<=alive1;alive_d<=alive2;
            if(alive2!=alive_d) dirty<=1;
            if(publish) begin
                request<=~request;dirty<=0;
            end
        end
    end
    always @(posedge video_clk or posedge video_rst) begin
        if(video_rst) begin req1<=0;req2<=0;ack<=0;vs_d<=0;alive<=0;end
        else begin
            alive<=1;req1<=request;req2<=req1;vs_d<=vs;
            if(consume) ack<=req2;
        end
    end
endmodule
```

## ui/text_osd_overlay.v

```verilog
`include "../pkg/text_osd_model.vh"
`include "../pkg/video_bmp_params.vh"
// One font instance serves the mutually exclusive editor and user text line.
// Four stages: coordinates, character index, byte lookup, synchronous font.
// Every pixel and HS/VS/DE takes the same four stages, including bypass.
module text_osd_overlay #(
    parameter [10:0] WIN_X0=`VBP_WIN_X0, WIN_Y0=`VBP_WIN_Y0,
    parameter [10:0] SCREEN_W=`VBP_H_ACTIVE, TEXT_Y=11'd16
)(
    input wire clk,rst,hs,vs,de,input wire [23:0] pix_in,
    input wire ui_active_frame,text_osd_page_frame,diag_show,
    input wire [`TEXT_OSD_MODEL_W-1:0] view,
    output wire hs_out,vs_out,de_out,output reg [23:0] pix_out
);
    localparam [23:0] C_BORDER=24'h808490,C_BG=24'h101018,
                      C_CURSOR=24'h305090,C_TEXT=24'he0e0e0;
    wire [`TEXT_OSD_TEXT_W-1:0] text_buf=view[`TEXT_OSD_TEXT];
    wire [`TEXT_OSD_LEN_W-1:0] text_len=view[`TEXT_OSD_LEN];
    wire [4:0] focus=view[`TEXT_OSD_FOCUS];
    wire osd_enable=view[`TEXT_OSD_ENABLE];
    reg [10:0] x,y;reg de_d,vs_d;
    always @(posedge clk or posedge rst) begin
        if(rst) begin x<=0;y<=0;de_d<=0;vs_d<=0;end
        else begin
            de_d<=de;vs_d<=vs;
            if(vs && !vs_d) y<=0;else if(!de && de_d) y<=y+1'b1;
            if(!de) x<=0;else x<=x+1'b1;
        end
    end
    wire editor=ui_active_frame && text_osd_page_frame;
    wire banner=!ui_active_frame && !diag_show && osd_enable && text_len!=0;
    wire win=editor && x>=WIN_X0 && x<WIN_X0+388 && y>=WIN_Y0 && y<WIN_Y0+148;
    wire txt=editor && x>=WIN_X0+2 && x<WIN_X0+386 && y>=WIN_Y0+2 && y<WIN_Y0+146;
    wire [10:0] width_next=text_len*11'd12;
    reg [10:0] banner_width,banner_x;
    reg [`TEXT_OSD_LEN_W-1:0] preview_start,visible_len;
    reg [23:0] count_characters;
    // The CDC view changes only during VS blanking. Prepare layout independently
    // of the pixel path so index arithmetic and the byte mux do not form one
    // long path; values settle before the next active scanline.
    always @(posedge clk or posedge rst) begin
        if(rst) begin banner_width<=0;banner_x<=SCREEN_W>>1;preview_start<=0;visible_len<=0;count_characters<={"0","0","0"};end
        else begin
            banner_width<=width_next;banner_x<=(SCREEN_W-width_next)>>1;
            preview_start<=text_len>29 ? text_len-29:0;
            visible_len<=text_len>29 ? 29:text_len;
            count_characters[23:16]<="0"+text_len/100;
            count_characters[15:8]<="0"+(text_len/10)%10;
            count_characters[7:0]<="0"+text_len%10;
        end
    end
    wire line= banner && x>=banner_x && x<banner_x+banner_width && y>=TEXT_Y && y<TEXT_Y+16;
    wire [10:0] dx=txt ? x-(WIN_X0+2):line ? x-banner_x:11'd0;
    wire [10:0] dy=txt ? y-(WIN_Y0+2):line ? y-TEXT_Y:11'd0;
    wire [`TEXT_OSD_LEN_W-1:0] col=dx/11'd12;
    wire [3:0] row=dy[7:4];
    wire [2:0] gx=(dx%11'd12)>>1,gy=dy[3:1];
    reg [3:0] focus_row;
    reg [4:0] focus_start,focus_end;
    reg [2:0] focus_col;
    always @(*) begin
        focus_col=0;focus_row=2;focus_start=0;focus_end=10;
        if(focus==1) begin focus_start=25;focus_end=30;end
        else if(focus>=2) begin
            if(focus<9) begin focus_row=4;focus_col=focus-2;end
            else if(focus<16) begin focus_row=5;focus_col=focus-9;end
            else if(focus<23) begin focus_row=6;focus_col=focus-16;end
            else begin focus_row=7;focus_col=focus-23;end
            focus_start={focus_col,2'b00};focus_end=focus_start+4;
            if(focus==28) begin focus_start=20;focus_end=27;end
            if(focus==29) begin focus_start=27;focus_end=32-1;end
        end
    end
    // DEL reaches column 31; handle its inclusive final column explicitly.
    wire highlight=txt && row==focus_row && col>=focus_start &&
                   ((focus==29) ? col<=31:col<focus_end);
    function [7:0] static_char;
        input [3:0] row;input [4:0] col;
        begin
            static_char=8'd32;
            case(row)
            4'd0:case(col)
                5'd0:static_char=8'd84;
                5'd1:static_char=8'd69;
                5'd2:static_char=8'd88;
                5'd3:static_char=8'd84;
                5'd5:static_char=8'd79;
                5'd6:static_char=8'd83;
                5'd7:static_char=8'd68;
                default:static_char=8'd32;
            endcase
            4'd2:case(col)
                5'd0:static_char=8'd91;
                5'd1:static_char=8'd79;
                5'd2:static_char=8'd83;
                5'd3:static_char=8'd68;
                5'd4:static_char=8'd58;
                5'd6:static_char=8'd79;
                5'd7:static_char=8'd70;
                5'd8:static_char=8'd70;
                5'd9:static_char=8'd93;
                5'd25:static_char=8'd91;
                5'd26:static_char=8'd67;
                5'd27:static_char=8'd76;
                5'd28:static_char=8'd82;
                5'd29:static_char=8'd93;
                default:static_char=8'd32;
            endcase
            4'd7:case(col)
                5'd20:static_char=8'd91;
                5'd21:static_char=8'd83;
                5'd22:static_char=8'd80;
                5'd23:static_char=8'd65;
                5'd24:static_char=8'd67;
                5'd25:static_char=8'd69;
                5'd26:static_char=8'd93;
                5'd27:static_char=8'd91;
                5'd28:static_char=8'd68;
                5'd29:static_char=8'd69;
                5'd30:static_char=8'd76;
                5'd31:static_char=8'd93;
                default:static_char=8'd32;
            endcase
            4'd8:case(col)
                5'd0:static_char=8'd50;
                5'd1:static_char=8'd47;
                5'd2:static_char=8'd56;
                5'd3:static_char=8'd47;
                5'd4:static_char=8'd52;
                5'd5:static_char=8'd47;
                5'd6:static_char=8'd54;
                5'd8:static_char=8'd77;
                5'd9:static_char=8'd79;
                5'd10:static_char=8'd86;
                5'd11:static_char=8'd69;
                5'd13:static_char=8'd53;
                5'd15:static_char=8'd79;
                5'd16:static_char=8'd75;
                5'd18:static_char=8'd35;
                5'd20:static_char=8'd66;
                5'd21:static_char=8'd65;
                5'd22:static_char=8'd67;
                5'd23:static_char=8'd75;
                default:static_char=8'd32;
            endcase
            default:static_char=8'd32;
            endcase
        end
    endfunction
    function [7:0] editor_char;
        input [3:0] r;input [4:0] c;
        input [7:0] preview_character;
        input [`TEXT_OSD_LEN_W-1:0] visible_length;
        input scrolled,enabled;input [23:0] count;
        begin
            editor_char=static_char(r,c);
            case(r)
            0:begin
                if(c==24) editor_char=count[23:16];
                if(c==25) editor_char=count[15:8];
                if(c==26) editor_char=count[7:0];
                if(c==27) editor_char="/";
                if(c==28) editor_char="1";
                if(c==29) editor_char="0";
                if(c==30) editor_char="6";
            end
            1:begin
                editor_char=" ";
                if(c==0) editor_char=scrolled ? "<":"[";
                else if(c==31) editor_char="]";
                else if(c==visible_length+1'b1) editor_char="_";
                else if(c>=1 && c<=visible_length) editor_char=preview_character;
            end
            2:begin
                if(c==7 && enabled) editor_char="N";
                if(c==8 && enabled) editor_char=" ";
            end
            4,5,6:begin
                if(c<28 && c[1:0]==1) editor_char="A"+(r-4)*7+c[4:2];
            end
            7:begin
                if(c<20 && c[1:0]==1) editor_char="V"+c[4:2];
            end
            default:begin end
            endcase
        end
    endfunction
    reg [23:0] rgb_a,rgb_b,rgb_c,rgb_d;
    reg [3:0] hs_pipe,vs_pipe,de_pipe;
    reg win_a,txt_a,line_a,high_a,win_b,txt_b,line_b,high_b,win_c,txt_c,line_c,high_c,win_d,txt_d,line_d,high_d;
    reg [`TEXT_OSD_LEN_W-1:0] col_a;reg [3:0] row_a;
    reg [2:0] gx_a,gy_a,gx_b,gy_b,gx_c,gy_c,gx_d,gy_d;
    reg [6:0] char_c;
    reg [`TEXT_OSD_LEN_W-1:0] read_index_b;
    reg read_text_b;reg [7:0] literal_b;
    wire [7:0] selected_character=text_buf[{read_index_b,3'b000} +: 8];
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            rgb_a<=0;rgb_b<=0;rgb_c<=0;rgb_d<=0;hs_pipe<=0;vs_pipe<=0;de_pipe<=0;
            win_a<=0;txt_a<=0;line_a<=0;high_a<=0;win_b<=0;txt_b<=0;line_b<=0;high_b<=0;
            win_c<=0;txt_c<=0;line_c<=0;high_c<=0;win_d<=0;txt_d<=0;line_d<=0;high_d<=0;
            col_a<=0;row_a<=0;gx_a<=0;gy_a<=0;gx_b<=0;gy_b<=0;gx_c<=0;gy_c<=0;gx_d<=0;gy_d<=0;char_c<=32;
            read_index_b<=0;read_text_b<=0;literal_b<=32;
        end else begin
            rgb_a<=pix_in;rgb_b<=rgb_a;rgb_c<=rgb_b;rgb_d<=rgb_c;
            hs_pipe<={hs_pipe[2:0],hs};vs_pipe<={vs_pipe[2:0],vs};de_pipe<={de_pipe[2:0],de};
            win_a<=win;txt_a<=txt;line_a<=line;high_a<=highlight;
            win_b<=win_a;txt_b<=txt_a;line_b<=line_a;high_b<=high_a;
            win_c<=win_b;txt_c<=txt_b;line_c<=line_b;high_c<=high_b;
            win_d<=win_c;txt_d<=txt_c;line_d<=line_c;high_d<=high_c;
            col_a<=col;row_a<=row;gx_a<=gx;gy_a<=gy;gx_b<=gx_a;gy_b<=gy_a;gx_c<=gx_b;gy_c<=gy_b;gx_d<=gx_c;gy_d<=gy_c;
            read_index_b<=line_a ? col_a:preview_start+col_a-1'b1;
            read_text_b<=(line_a && col_a<text_len) ||
                         (txt_a && row_a==1 && col_a>=1 && col_a<=visible_len);
            literal_b<=txt_a ? editor_char(row_a,col_a[4:0],8'd32,visible_len,preview_start!=0,osd_enable,count_characters):8'd32;
            char_c<=read_text_b ? selected_character[6:0]:literal_b[6:0];
        end
    end
    wire [34:0] glyph;
    font_rom #(.LOGIC_ONLY(1)) u_font(.clk(clk),.char_code(char_c),.glyph(glyph));
    reg [4:0] glyph_row;reg glyph_bit;
    always @(*) begin
        case(gy_d)
        0:glyph_row=glyph[34:30];1:glyph_row=glyph[29:25];2:glyph_row=glyph[24:20];
        3:glyph_row=glyph[19:15];4:glyph_row=glyph[14:10];5:glyph_row=glyph[9:5];
        default:glyph_row=glyph[4:0];
        endcase
        case(gx_d)
        0:glyph_bit=glyph_row[4];1:glyph_bit=glyph_row[3];2:glyph_bit=glyph_row[2];
        3:glyph_bit=glyph_row[1];default:glyph_bit=glyph_row[0];
        endcase
        pix_out=rgb_d;
        if(de_pipe[3]) begin
            if(win_d && !txt_d) pix_out=C_BORDER;
            else if(txt_d || line_d) begin
                if(gx_d<5 && gy_d<7 && glyph_bit) pix_out=C_TEXT;
                else pix_out=high_d ? C_CURSOR:C_BG;
            end
        end
    end
    assign hs_out=hs_pipe[3];assign vs_out=vs_pipe[3];assign de_out=de_pipe[3];
endmodule
```
