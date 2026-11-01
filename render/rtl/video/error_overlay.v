// Native 15x21 AA diagnostics, 18-pixel pitch; two pixel/sync stages.
// Its second stage replaces render_core's former register after this overlay.
module error_overlay #(
    // 720p 默认，与 rtl/pkg/video_bmp_params.vh 的 VBP_TEXT_* 一致；TB 可 override
    parameter [10:0] TEXT_X = 11'd578,
    parameter [10:0] TEXT_Y = 11'd349
)(
    input  wire        video_clk,
    input  wire        rst,                 // 高有效
    input  wire        hs,
    input  wire        vs,                  // 与 de / pix_in 对齐的场同步
    input  wire        de,                  // 与 pix_in 对齐的数据有效
    input  wire [23:0] pix_in,
    input  wire [3:0]  code,                // 0..9: ERROR n; 13: WAIT DATA; 14: LINK DOWN
    input  wire        show,                // 1 = 叠加显示
    output reg         hs_out,
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] pix_out,
    output reg         frame_black          // 上一帧有效像素是否全为 0
);
    function [23:0] glass_rgb;
        input [23:0] src; input [23:0] tint;
        reg [9:0] rr,gg,bb;
        begin rr={2'b0,src[23:16]}+({2'b0,src[23:16]}>>1)+({2'b0,tint[23:16]}>>1); gg={2'b0,src[15:8]}+({2'b0,src[15:8]}>>1)+({2'b0,tint[15:8]}>>1); bb={2'b0,src[7:0]}+({2'b0,src[7:0]}>>1)+({2'b0,tint[7:0]}>>1); glass_rgb={rr[9:2],gg[9:2],bb[9:2]}; end
    endfunction

    //=========================================================================
    // 排版常量
    //=========================================================================
    localparam [10:0] PITCH   = 11'd18;     // 字符步进（含 3 像素间隙）
    localparam [10:0] TXT_W   = 11'd159;    // fits "LINK DOWN"
    localparam [10:0] TXT_H   = 11'd21;

    wire [10:0] txt_x0 = TEXT_X;
    wire [10:0] txt_y0 = TEXT_Y;

    // 底色块（比文字四周各留几像素，保证任何画面上都看得清）
    wire [10:0] ban_x0 = (TEXT_X >= 11'd9) ? (TEXT_X - 11'd9)  : 11'd0;
    wire [10:0] ban_x1 = TEXT_X + 11'd167;
    wire [10:0] ban_y0 = (TEXT_Y >= 11'd6) ? (TEXT_Y - 11'd6)  : 11'd0;
    wire [10:0] ban_y1 = TEXT_Y + 11'd26;

    //=========================================================================
    // 从 de/vs 重建坐标
    //=========================================================================
    reg [10:0] x_cnt, y_cnt;
    reg        de_d, vs_d;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            x_cnt <= 11'd0;
            y_cnt <= 11'd0;
            de_d  <= 1'b0;
            vs_d  <= 1'b0;
        end else begin
            de_d <= de;
            vs_d <= vs;

            if (vs & ~vs_d)
                y_cnt <= 11'd0;                       // 帧首
            else if (~de & de_d)
                y_cnt <= y_cnt + 11'd1;               // 行末

            if (de & ~de_d)
                x_cnt <= 11'd0;                       // 行首
            else if (de)
                x_cnt <= x_cnt + 11'd1;
        end
    end

    //=========================================================================
    // 文字窗口判定 + 字模取位
    //=========================================================================
    wire in_txt_x = (x_cnt >= txt_x0) && (x_cnt < (txt_x0 + TXT_W));
    wire in_txt_y = (y_cnt >= txt_y0) && (y_cnt < (txt_y0 + TXT_H));

    wire [10:0] dx = in_txt_x ? (x_cnt - txt_x0) : 11'd0;
    wire [10:0] dy = in_txt_y ? (y_cnt - txt_y0) : 11'd0;

    wire in_ban = (x_cnt >= ban_x0) && (x_cnt <= ban_x1) &&
                  (y_cnt >= ban_y0) && (y_cnt <= ban_y1);

    // 先锁存窗口定位结果，再做字符寻址和像素混合。这样 75 MHz 下不会
    // 把坐标比较、除法/取模、字模选择和 RGB mux 串成一条长组合路径。
    // Window-local coordinates are bounded by 159x21. Narrow operands keep
    // constant division/modulo from synthesizing unused wide arithmetic.
    reg [4:0] gx_s;
    reg [4:0] glyph_s;
    reg [4:0] dy_s;
    reg [23:0] pix_s;
    reg        show_s, in_txt_s, in_ban_s;
    reg [23:0] pix_d;
    reg [4:0] gx_d;
    reg show_d,in_txt_d,in_ban_d,hs_s,vs_s,de_s;

    // Decode absolute cell_no boundaries in parallel. Window subtraction must
    // not precede the cell_no selector and a second subtraction on the same path.
    wire [8:0] cell_hit;
    wire [4:0] cell_x[0:8];
    wire [4:0] cell_glyph[0:8];
    genvar cell_no;
    generate for(cell_no=0;cell_no<9;cell_no=cell_no+1) begin:diagnostic_cell
        localparam [10:0] START=TEXT_X+cell_no*18;
        localparam [10:0] STOP=TEXT_X+(cell_no+1)*18;
        assign cell_hit[cell_no]=(x_cnt>=START && x_cnt<STOP);
        assign cell_x[cell_no]=x_cnt[4:0]-START[4:0];
        assign cell_glyph[cell_no]=diagnostic_glyph(cell_no,code);
    end endgenerate
    reg [4:0] rem_x_a,glyph_a;
    integer cell_index;
    always @* begin
        rem_x_a=0;glyph_a=0;
        for(cell_index=0;cell_index<9;cell_index=cell_index+1) begin
            rem_x_a=rem_x_a | (cell_x[cell_index] & {5{cell_hit[cell_index]}});
            glyph_a=glyph_a | (cell_glyph[cell_index] & {5{cell_hit[cell_index]}});
        end
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            gx_s     <= 0;glyph_s<=0;
            dy_s     <= 11'd0;
            pix_s    <= 24'd0;
            pix_d<=0;gx_d<=0;show_d<=0;in_txt_d<=0;in_ban_d<=0;hs_s<=0;vs_s<=0;de_s<=0;
            show_s   <= 1'b0;
            in_txt_s <= 1'b0;
            in_ban_s <= 1'b0;
            hs_out   <= 1'b0;
            vs_out   <= 1'b0;
            de_out   <= 1'b0;
        end else begin
            gx_s     <= rem_x_a[4:0];
            glyph_s <= glyph_a;
            dy_s     <= dy;
            pix_s    <= pix_in;
            show_s   <= show;
            in_txt_s <= in_txt_x && in_txt_y;
            in_ban_s <= in_ban;
            pix_d<=pix_s;gx_d<=gx_s;show_d<=show_s;in_txt_d<=in_txt_s;in_ban_d<=in_ban_s;
            hs_s<=hs;vs_s<=vs;de_s<=de;
            hs_out   <= hs_s;
            vs_out   <= vs_s;
            de_out   <= de_s;
        end
    end

    `include "../ui/font_diag_rows.vh"
    `include "../ui/font_blend.vh"
    wire [1:0] coverage=gx_d<15 ? diagnostic_word[{gx_d[2:0],1'b0} +: 2]:2'd0;

    always @(*) begin
        if (show_d && in_txt_d)
            pix_out = font_blend(24'hF5_F7_FA,24'h14_17_1B,coverage);
        else if (show_d && in_ban_d)
            pix_out = 24'h14_17_1B;
        else
            pix_out = pix_d;
    end

    //=========================================================================
    // 整帧全黑检测
    //=========================================================================
    reg [19:0] nz_cnt;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            nz_cnt      <= 20'd0;
            frame_black <= 1'b0;
        end else if (vs & ~vs_d) begin
            frame_black <= (nz_cnt == 20'd0);
            nz_cnt      <= 20'd0;
        end else if (de && (pix_in != 24'd0) && (nz_cnt != 20'hFFFFF)) begin
            nz_cnt <= nz_cnt + 20'd1;
        end
    end

    // Character selection is independent of outline rasterization.
    function [4:0] diagnostic_glyph;
        input [3:0] ci,dv;
        begin
            diagnostic_glyph=DIAG_SPACE;
            if(dv==13) case(ci)
                0:diagnostic_glyph=DIAG_W;1,6,8:diagnostic_glyph=DIAG_A;
                2:diagnostic_glyph=DIAG_I;3,7:diagnostic_glyph=DIAG_T;
                5:diagnostic_glyph=DIAG_D;default:diagnostic_glyph=DIAG_SPACE;
            endcase
            else if(dv==14) case(ci)
                0:diagnostic_glyph=DIAG_L;1:diagnostic_glyph=DIAG_I;
                2,8:diagnostic_glyph=DIAG_N;3:diagnostic_glyph=DIAG_K;
                5:diagnostic_glyph=DIAG_D;6:diagnostic_glyph=DIAG_O;
                7:diagnostic_glyph=DIAG_W;default:diagnostic_glyph=DIAG_SPACE;
            endcase
            else case(ci)
                0:diagnostic_glyph=DIAG_E;1,2,4:diagnostic_glyph=DIAG_R;
                3:diagnostic_glyph=DIAG_O;
                6:diagnostic_glyph=dv<=9 ? DIAG_0+dv:DIAG_SPACE;
                default:diagnostic_glyph=DIAG_SPACE;
            endcase
        end
    endfunction
endmodule
