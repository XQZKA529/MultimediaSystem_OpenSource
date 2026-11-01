//=============================================================================
// module : file_browser
// 文件名 : rtl/ui/file_browser.v
// 功  能 : SD 卡根目录文件浏览器的"业务逻辑"（100 MHz sd_card_clk 域）
//
//  ★ 本文件必须加入 TD 工程源文件清单（Project → Add Source Files）。
//
//  职责（做什么）：
//    ① 向 fat32_ro 申请一次目录枚举，把条目流抓成"名字 + 簇号 + 大小 + 是否目录"
//    ② 维护光标 / 分页，把当前页和状态行渲染进 ui_text_overlay 的文本 RAM
//    ③ KEY3 设置菜单、KEY2 延迟单击/双击返回、KEY4 确认；关窗长按切轮播
//    ④ 向 fat_bmp_controller 发 ext_load_req 并处理 ack / rejected
//
//  明确不做（不做什么和做什么一样重要）：
//    - 不碰像素流（像素叠加全在 ui_text_overlay 里）
//    - 不持有 SD 引脚、不直接读扇区（只用 fat32_ro 的字符流接口）
//    - 不解析 BMP 头（那是 fat_bmp_controller 的事）
//
//  ── 与 error_overlay / ui_text_overlay 的关系 ───────────────────────────
//    本模块只在 sd_card_clk 域活动，通过两块内存把结果交给 video 域：
//      · 文本 RAM（在 ui_text_overlay 内部）：本模块用 ui_wr_* 写
//      · cursor_row / ui_active：准静态电平
//    全部内容只在按键时刻整页重写（≤ 576 拍 ≈ 6 µs），ui_text_overlay 在
//    vs 帧界采样 ui_active / cursor_row，所以不会出现"半帧半新半旧"的撕裂。
//
//  ── 资源账（为什么这么写）────────────────────────────────────────────
//    浏览器只缓存当前页 8 个条目；跨页时重新枚举根目录并跳过前面的
//    条目。这样目录容量不再由片上名字 RAM 决定：
//      name_ram 8×32 B = 256 B
//      meta_ram 8×72 bit = 576 bit
//    两块存储仍标记 force_ram，给后续扩大 PAGE_LINES 留出实现余量。
//
//  ── 目录口归属 ────────────────────────────────────────────────────────
//    fat32_ro 只有一组 dir_* 端口，图像层（开机枚举一次）和本模块共用，
//    storage_service 做 req/gnt 仲裁（本模块优先）：
//      ① 只有在 img_idle 时才申请，避免与图像层枚举撞车；
//      ② dir_req 从"决定要枚举"一直保持到 dir_done，中途关窗也不立刻
//         放开（否则图像层可能拿到半截响应）。关窗走 S_ABORT_WAIT 等它自然结束。
//      ③ dir_start 仅在 dir_gnt 有效时发一拍。
//=============================================================================
`include "../pkg/fat_dir_bus.vh"
module file_browser #(
    parameter integer CLK_FREQ_HZ  = 100_000_000,
    parameter integer DEBOUNCE_MS  = 50,
    parameter integer HOLD_MS      = 2000,
    parameter integer PAGE_LINES   = 8,      // 每页显示的文件行数
    parameter integer COLS         = 32,     // 每行字符数
    parameter integer LINES        = 9       // 8 行列表 + 1 行状态
)(
    input  wire        clk,
    input  wire        rst,
    input wire force_close,input_block,

    // ---- 按键（低有效，内部 50 ms 消抖）----
    input wire ev_ok_press,ev_ok_release,ev_ok_hold,
    output wire legacy_next_pulse,
    input wire action_open,action_back,action_up,action_down,action_left,action_right,action_confirm,
    output wire [3:0] ui_page,output wire ui_navigable,
    output reg text_osd_page, // lifecycle only; OSD configuration belongs to render
    input  wire        key_open,             // KEY3：开/关窗口
    input  wire        key_sel,              // KEY2：光标下移；关窗时长按 2s 切轮播
    input wire [1:0] brightness_mode,
    output reg [3:0] brightness_level,
    output reg [4:0] contrast_level,output reg [4:0] saturation_level,
    input wire subtitle_display,subtitle_auto,input wire [3:0] subtitle_status,
    output reg subtitle_display_toggle,subtitle_auto_toggle,subtitle_clear,
    output reg ext_txt_req,output wire [31:0] ext_txt_cluster,ext_txt_size,
    input wire ext_txt_ack,ext_txt_rejected,
    input wire [4:0] volume_level,
    output reg volume_increase,volume_decrease,
    output reg [1:0] transition_mode,
    output reg [5:0] auto_interval_steps,
    output reg auto_interval_changed,
    input  wire        key_ok,               // KEY4：确认

    // ---- 图像层空闲契约（C_READY/C_ERROR 等价于 img_idle；勿再依赖 FSM 编码）----
    input  wire        img_idle,            // 1 = 可占用目录口
    input  wire        img_ready,           // 1 = 仅图像层完全就绪（自动轮播开关）
    input  wire        fat_busy,

    // ---- fat32_ro 目录口（经 storage_service 仲裁；req/gnt）----
    // 数据面捆绑（E1）：位分配见 pkg/fat_dir_bus.vh，下方 unpack 成原信号名
    output wire        dir_req,             // 申请目录口，持有到 dir_done
    input  wire        dir_gnt,
    output reg         dir_start,
    input  wire [`VDIR_DBUS_W-1:0] dir_dat,

    // ---- 显示层（ui_text_overlay）----
    output reg         ui_active,
    output reg         ui_commit_toggle,
    output wire [3:0]  cursor_row,
    output wire        cursor_en,
    output reg         ui_wr_en,
    output reg [8:0]   ui_wr_addr,
    output reg [7:0]   ui_wr_data,

    // ---- 加载请求（→ fat_bmp_controller）----
    output reg         ext_load_req,
    output reg [31:0]  ext_load_cluster,
    output reg [31:0]  ext_load_size,
    input  wire        ext_load_ack,
    input  wire        ext_load_rejected,

    // ---- WAV 播放请求（→ fat_wav_controller，C4）----
    output reg         ext_play_req,
    output reg [31:0]  ext_play_cluster,
    output reg [31:0]  ext_play_size,
    input  wire        ext_play_ack,
    input  wire        ext_play_rejected,

    // ---- 自动轮播开关（→ fat_bmp_controller.auto_toggle）----
    output reg         auto_toggle_pulse,

    // ---- 观察点 ----
    output wire [3:0]  dbg_browser_state,
    output wire [6:0]  dbg_entry_count,
    output wire [5:0]  dbg_cursor
);

    // E1: dir_dat 捆绑 unpack —— 原信号名保持，FSM 体零改动
    wire        dir_entry_start         = dir_dat[`VDIR_D_ESTART];
    wire        dir_name_valid          = dir_dat[`VDIR_D_NVLD];
    wire [7:0]  dir_name_char           = dir_dat[`VDIR_D_CHAR];
    wire [7:0]  dir_name_index          = dir_dat[`VDIR_D_INDEX];
    wire        dir_entry_end           = dir_dat[`VDIR_D_EEND];
    wire [31:0] dir_entry_first_cluster = dir_dat[`VDIR_D_FCLUST];
    wire [31:0] dir_entry_size          = dir_dat[`VDIR_D_SIZE];
    wire        dir_entry_is_dir        = dir_dat[`VDIR_D_ISDIR];
    wire        dir_done                = dir_dat[`VDIR_D_DONE];
    wire        dir_ok                  = dir_dat[`VDIR_D_OK];

    //=========================================================================
    // 状态编码
    //=========================================================================
    localparam S_CLOSED     = 4'd0;   // 窗口关闭
    localparam S_OPEN_INIT  = 4'd1;   // 开窗：清列表 + 状态 "SCANNING..."
    localparam S_WAIT_IDLE  = 4'd2;   // 等图像层空闲
    localparam S_REQ_DIR    = 4'd3;   // 拉 dir_start 一拍
    localparam S_CAPTURE    = 4'd4;   // 抓目录条目
    localparam S_DRAW       = 4'd5;   // 渲染（文本 RAM 写入）
    localparam S_OPEN       = 4'd6;   // 窗口已显示，等按键
    localparam S_LOAD_RD    = 4'd7;   // 读选中条目的元数据
    localparam S_LOAD_REQ   = 4'd8;   // 拉 ext_load_req 一拍
    localparam S_LOAD_WAIT  = 4'd9;   // 等 ext_load_ack / ext_load_rejected
    localparam S_ABORT_WAIT = 4'd10;  // 关窗后等目录操作自然收尾
    localparam S_LOAD_W     = 4'd11;  // 等 meta_ram 读出口（BRAM 1 拍延迟）

    // Top-level pages share the existing text RAM and write/commit interface.
    localparam S_SETTINGS=4'd12, S_BRIGHTNESS=4'd13, S_MENU_DRAW=4'd14, S_CONTRAST=4'd15;
    reg [3:0] page; // 8 = slideshow interval
    reg [3:0] settings_sel;
    reg [1:0] transition_sel;
    reg [4:0] volume_drawn;
    reg [8:0] menu_addr;
    reg [1:0] mode_drawn;
    reg gesture_cancel;
    reg scan_inflight,load_inflight;
    // Directory scans and submitted loads are mutually exclusive.
    reg [30:0] drain_count;

    // 渲染子状态
    //  ★ D_META_W / D_CHAR_WAIT 是"等 BRAM 读出口"的空拍，不能省：
    //    同步读的语义是"本拍给地址、下一拍出数据"，而地址又是在本拍末尾才
    //    寄存的，所以真正能用的数据在**给地址之后第 2 拍**。少了这两个空拍，
    //    读回来的一律是上一个地址的数据（TB 里表现为整行字符右移一格、
    //    状态行串位）。这里刻意写成显式空状态，避免以后有人"优化掉"。
    localparam D_IDLE=3'd0, D_META_W=3'd1, D_META=3'd2,
               D_CHAR_RD=3'd3, D_CHAR_WAIT=3'd4, D_CHAR_WR=3'd5, D_NEXT=3'd6;

    // 状态行内容
    localparam [2:0] ST_BLANK  = 3'd0;
    localparam [2:0] ST_SCAN   = 3'd1;   // SCANNING...
    localparam [2:0] ST_NOTBMP = 3'd2;   // NOT A BMP
    localparam [2:0] ST_OVF    = 3'd3;   // ... +N
    localparam [2:0] ST_DIRERR = 3'd4;   // DIR ERROR
    localparam [2:0] ST_LOAD   = 3'd5;   // LOADING...
    localparam [2:0] ST_BUSY   = 3'd6;   // IMAGE BUSY
    localparam [3:0] ST_NOTTXT=4'd8;
    localparam [2:0] ST_NOTWAV = 3'd7;   // NOT A WAV

    //=========================================================================
    // 片上存储
    //=========================================================================
    reg [7:0]  name_ram [0:255] /* fehdl force_ram=1, ram_style="bram" */; // 当前页 8 条 × 32 字符
    reg [71:0] meta_ram [0:7]   /* fehdl force_ram=1, ram_style="bram" */; // 当前页元数据
    reg [7:0]  name_q;
    reg [71:0] meta_q;
    // The synchronous metadata RAM output remains stable through the TXT
    // request/acknowledgement window; its cluster/size can feed storage_service
    // directly. BMP and WAV retain descriptor registers at their consumer
    // boundaries to avoid longer downstream compare paths.
    assign ext_txt_cluster=meta_q[31:0];
    assign ext_txt_size=meta_q[63:32];

    //-------------------------------------------------------------------------
    // 捕获侧写口
    //-------------------------------------------------------------------------
    reg        name_wr_en;
    reg [7:0]  name_wr_addr;
    reg [7:0]  name_wr_data;
    reg        meta_wr_en;
    reg [2:0]  meta_wr_addr;
    reg [71:0] meta_wr_data;
    // 渲染侧读口
    reg [7:0]  name_rd_addr;
    reg [2:0]  meta_rd_addr;

    always @(posedge clk) begin
        if (name_wr_en) name_ram[name_wr_addr] <= name_wr_data;
        name_q <= name_ram[name_rd_addr];
        if (meta_wr_en) meta_ram[meta_wr_addr] <= meta_wr_data;
        meta_q <= meta_ram[meta_rd_addr];
    end

    wire meta_is_txt=meta_q[71:70]==2'b11;
    wire        meta_is_dir  = meta_q[71:70]==2'b01;
    wire        meta_is_wav  = meta_q[71:70]==2'b10;
    wire [5:0]  meta_name_len= meta_q[69:64];
    wire [31:0] meta_size    = meta_q[63:32];
    wire [31:0] meta_cluster = meta_q[31:0];

    //=========================================================================
    // 按键消抖 / 长按检测
    //=========================================================================
    wire key_open_pulse,key_sel_press,key_sel_release,key_sel_hold;
    wire key_sel_pulse,key_sel_double;
    wire ok_raw_press,ok_raw_release,ok_raw_hold;
    wire key_ok_press=ok_raw_press || ev_ok_press;
    wire key_ok_release=ok_raw_release || ev_ok_release;
    wire key_ok_hold=ok_raw_hold || ev_ok_hold;
    reg key_ok_down,key_ok_long;
    wire key_ok_pulse=key_ok_release && key_ok_down && !key_ok_long && !gesture_cancel;
    key_click_decode #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_key_click (
        .clk(clk),.rst(rst),.enable(ui_active),.cancel(key_open_pulse || gesture_cancel),
        .ev_press(key_sel_press),.ev_release(key_sel_release),.ev_hold(key_sel_hold),
        .single_pulse(key_sel_pulse),.double_pulse(key_sel_double));
    always @(posedge clk or posedge rst)
        if(rst) begin key_ok_down<=0;key_ok_long<=0;end
        else if(key_open_pulse || gesture_cancel || !ui_active) begin key_ok_down<=0;key_ok_long<=0;end
        else begin
            if(key_ok_press) begin key_ok_down<=1;key_ok_long<=0;end
            if(key_ok_hold) key_ok_long<=1;
            if(key_ok_release) key_ok_down<=0;
        end

    key_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .HOLD_MS(HOLD_MS))
    u_key_open (.clk(clk), .rst(rst), .button_in(key_open),
                .press_pulse(key_open_pulse), .hold_pulse());
    key_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .HOLD_MS(HOLD_MS))
    u_key_sel  (.clk(clk), .rst(rst), .button_in(key_sel),
                .press_pulse(key_sel_press), .release_pulse(key_sel_release), .hold_pulse(key_sel_hold));
    key_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .HOLD_MS(HOLD_MS))
    u_key_ok   (.clk(clk), .rst(rst), .button_in(key_ok),
                .press_pulse(ok_raw_press), .release_pulse(ok_raw_release), .hold_pulse(ok_raw_hold));

    //=========================================================================
    // 状态
    //=========================================================================
    reg [15:0] state_hot;
    // Two-cycle metadata load: latch the kind first, then drive the wide
    // register enables from local flags instead of the meta_q decode.
    reg [1:0] load_kind;
    reg [31:0] load_cluster,load_size;
    reg load_apply_q;
    wire [3:0] state;
    // Numeric state remains available to diagnostics; control uses one-hot bits.
    assign state = ({4{state_hot[1]}} & 4'd1) | ({4{state_hot[2]}} & 4'd2) |
                   ({4{state_hot[3]}} & 4'd3) | ({4{state_hot[4]}} & 4'd4) |
                   ({4{state_hot[5]}} & 4'd5) | ({4{state_hot[6]}} & 4'd6) |
                   ({4{state_hot[7]}} & 4'd7) | ({4{state_hot[8]}} & 4'd8) |
                   ({4{state_hot[9]}} & 4'd9) | ({4{state_hot[10]}} & 4'd10) |
                   ({4{state_hot[11]}} & 4'd11) | ({4{state_hot[12]}} & 4'd12) |
                   ({4{state_hot[13]}} & 4'd13) | ({4{state_hot[14]}} & 4'd14) |
                   ({4{state_hot[15]}} & 4'd15);
    reg        dir_own_r;
    reg [15:0] ent_cnt;                 // 本次枚举得到的目录总条目数
    reg [15:0] cur;                     // 全局光标条目序号
    reg [15:0] scan_count;              // 当前重扫已经经过的条目数
    reg [15:0] scan_page_base;          // 本次重扫要缓存的页首序号
    reg [15:0] cache_page_base;         // 当前 8 项缓存对应的页首序号
    reg [3:0]  status_kind;
    reg [7:0]  cur_name_len;            // 当前条目名长度（抓取中）
    reg [7:0]  name_c0, name_c1, name_c2, name_c3;  // 滚动末 4 字符
    reg overlay_match;
    reg [7:0] overlay_name_len;
    function [7:0] fold_overlay_char;
        input [7:0] c;
        begin fold_overlay_char=(c[7:6]==2'b01 && c[5] && c[4:0]!=0 && c[4:0]<=5'd26)?{c[7:6],1'b0,c[4:0]}:c;end
    endfunction
    function [7:0] overlay_expected_char;
        input [3:0] i;
        begin case(i)
            0:overlay_expected_char="O";1:overlay_expected_char="V";2:overlay_expected_char="E";
            3:overlay_expected_char="R";4:overlay_expected_char="L";5:overlay_expected_char="A";
            6:overlay_expected_char="Y";7:overlay_expected_char=".";8:overlay_expected_char="B";
            9:overlay_expected_char="M";10:overlay_expected_char="P";default:overlay_expected_char=0;
        endcase end
    endfunction
    reg pending_txt;
    reg [1:0] subtitle_sel;
    reg [5:0] subtitle_drawn;
    reg        pending_play;            // 1=等 ext_play_*；0=等 ext_load_*

    // 扩展名 .WAV（大小写不敏感）：末 4 字符为 ".wav"
    function is_dotwav;
        input [7:0] a, b, c, d;
        begin
            is_dotwav = (a == 8'h2E) &&
                        ((b == "W") || (b == "w")) &&
                        ((c == "A") || (c == "a")) &&
                        ((d == "V") || (d == "v"));
        end
    endfunction

    function is_dottxt;
        input [7:0] a,b,c,d;
        begin is_dottxt=a==46 && (b==84 || b==116) && (c==88 || c==120) && (d==84 || d==116);end
    endfunction

    // 渲染状态
    reg [2:0]  dphase;
    reg [3:0]  draw_row;
    reg [5:0]  draw_i;
    reg [2:0]  draw_ent;
    reg [15:0] draw_return_hot;
    reg        draw_status_only;
    reg        line_blank, line_is_status;
    reg [3:0]  prefix_len;
    reg [5:0]  name_len_l;

    // 超时
    reg [30:0] wait_cnt;
    localparam [30:0] TIMEOUT_1S   = CLK_FREQ_HZ;          // 约 1 s（等 ack 的兜底）
    localparam [30:0] TIMEOUT_DIR  = CLK_FREQ_HZ * 15;     // 大目录完整重扫上限 15 s
    localparam [5:0]  COLS_C6     = COLS;

    assign dir_req     = dir_own_r;
    assign cursor_row  = (page==5) ? (4'd2+{2'd0,subtitle_sel}):(page==1) ? (4'd2+settings_sel):(page==6) ? (4'd2+{2'd0,transition_sel}):(page==8) ? 4'd2:{1'b0,cur[2:0]};
    assign cursor_en   = ui_active && ((page==1) || page==5 || page==6 || ((page==8) && state_hot[S_CONTRAST]) || ((page==0) && ent_cnt!=0));
    assign dbg_browser_state = state;
    assign dbg_entry_count   = (ent_cnt > 16'd127) ? 7'd127 : ent_cnt[6:0];
    assign dbg_cursor        = cur[5:0];

    //=========================================================================
    // 状态行 / 前缀字符
    //=========================================================================
    function [7:0] status_char;
        input [3:0] kind;
        input [4:0] i;
        input [3:0] d2, d1, d0;
        begin
            case (kind)
            ST_SCAN: begin
                case (i)
                5'd0 : status_char = "S"; 5'd1 : status_char = "C"; 5'd2 : status_char = "A";
                5'd3 : status_char = "N"; 5'd4 : status_char = "N"; 5'd5 : status_char = "I";
                5'd6 : status_char = "N"; 5'd7 : status_char = "G"; 5'd8 : status_char = ".";
                5'd9 : status_char = "."; 5'd10: status_char = ".";
                default: status_char = " ";
                endcase
            end
            ST_NOTBMP: begin
                case (i)
                5'd0 : status_char = "N"; 5'd1 : status_char = "O"; 5'd2 : status_char = "T";
                5'd3 : status_char = " "; 5'd4 : status_char = "A"; 5'd5 : status_char = " ";
                5'd6 : status_char = "B"; 5'd7 : status_char = "M"; 5'd8 : status_char = "P";
                default: status_char = " ";
                endcase
            end
            ST_NOTTXT:begin
                status_char=" "; // The shared synchronous menu ROM supplies TXT status.
            end
            ST_NOTWAV: begin
                case (i)
                5'd0 : status_char = "N"; 5'd1 : status_char = "O"; 5'd2 : status_char = "T";
                5'd3 : status_char = " "; 5'd4 : status_char = "A"; 5'd5 : status_char = " ";
                5'd6 : status_char = "W"; 5'd7 : status_char = "A"; 5'd8 : status_char = "V";
                default: status_char = " ";
                endcase
            end
            ST_DIRERR: begin
                case (i)
                5'd0 : status_char = "D"; 5'd1 : status_char = "I"; 5'd2 : status_char = "R";
                5'd3 : status_char = " "; 5'd4 : status_char = "E"; 5'd5 : status_char = "R";
                5'd6 : status_char = "R"; 5'd7 : status_char = "O"; 5'd8 : status_char = "R";
                default: status_char = " ";
                endcase
            end
            ST_LOAD: begin
                case (i)
                5'd0 : status_char = "L"; 5'd1 : status_char = "O"; 5'd2 : status_char = "A";
                5'd3 : status_char = "D"; 5'd4 : status_char = "I"; 5'd5 : status_char = "N";
                5'd6 : status_char = "G"; 5'd7 : status_char = "."; 5'd8 : status_char = ".";
                5'd9 : status_char = ".";
                default: status_char = " ";
                endcase
            end
            ST_BUSY: begin
                case (i)
                5'd0 : status_char = "I"; 5'd1 : status_char = "M"; 5'd2 : status_char = "A";
                5'd3 : status_char = "G"; 5'd4 : status_char = "E"; 5'd5 : status_char = " ";
                5'd6 : status_char = "B"; 5'd7 : status_char = "U"; 5'd8 : status_char = "S";
                5'd9 : status_char = "Y";
                default: status_char = " ";
                endcase
            end
            ST_OVF: begin
                // "... +N"：N 的位数不定，所以每一位都要单独限定，不能用 default
                if ((i == 5'd0) || (i == 5'd1) || (i == 5'd2)) status_char = ".";
                else if (i == 5'd3)                          status_char = " ";
                else if (i == 5'd4)                          status_char = "+";
                else if (d2 != 4'd0) begin
                    if      (i == 5'd5) status_char = 8'h30 + {4'd0, d2};
                    else if (i == 5'd6) status_char = 8'h30 + {4'd0, d1};
                    else if (i == 5'd7) status_char = 8'h30 + {4'd0, d0};
                    else                status_char = " ";
                end else if (d1 != 4'd0) begin
                    if      (i == 5'd5) status_char = 8'h30 + {4'd0, d1};
                    else if (i == 5'd6) status_char = 8'h30 + {4'd0, d0};
                    else                status_char = " ";
                end else begin
                    if      (i == 5'd5) status_char = 8'h30 + {4'd0, d0};
                    else                status_char = " ";
                end
            end
            default: status_char = " ";
            endcase
        end
    endfunction

    // "[DIR] " 前缀
    function [7:0] prefix_char;
        input [4:0] i;
        begin
            case (i)
            5'd0: prefix_char = "[";
            5'd1: prefix_char = "D";
            5'd2: prefix_char = "I";
            5'd3: prefix_char = "R";
            5'd4: prefix_char = "]";
            default: prefix_char = " ";
            endcase
        end
    endfunction

    wire [7:0] menu_rom_char;
    reg [1:0] menu_read_phase;
    wire menu_status=state_hot[S_MENU_DRAW] && page==5 && menu_addr[8:5]==6;
    wire browser_txt_status=state_hot[S_DRAW] && line_is_status && status_kind==ST_NOTTXT;
    settings_menu_text_rom u_menu_text(.clk(clk),.page((menu_status || browser_txt_status) ? 4'd6:page),.status_bank(menu_status || browser_txt_status),.mode(mode_drawn),
        .row(menu_status ? subtitle_drawn[3:0]:browser_txt_status ? subtitle_status:menu_addr[8:5]),
        .col(browser_txt_status ? draw_i[4:0]:menu_addr[4:0]),.data(menu_rom_char));
    function [7:0] menu_char;
        input [3:0] which;
        input [3:0] row;
        input [4:0] col;
        input [4:0] level;
        input [1:0] mode;
        input [7:0] static_char;
        begin
            menu_char=static_char;
            if((which==2 || which==3 || which==4 || which==9) && row==2) begin
                if(which==4) begin
                    if(col==7) menu_char=level==20 ? "1":" ";
                    if(col==8) menu_char="0"+(level==20 ? 0:(level>>1));
                    if(col==9) menu_char=level[0] ? "5":"0";
                end else begin
                if(col==7) menu_char=(level>=20) ? "2":((level>=10) ? "1":" ");
                if(col==8) menu_char="0"+((level>=20) ? (level-20):((level>=10) ? (level-10):level));
                if(col==9) menu_char="0";
                end
            end
            if(which==2 && row==4 && col>=1 && col<=10)
                menu_char=(col<=level) ? "=":"-";
            if((which==3 || which==4 || which==9) && row==4 && col>=1 && col<=20)
                menu_char=(col<=level) ? "=":"-";
            if(which==8 && row==2) begin
                if(col==7) menu_char=auto_interval_steps>=60 ? "3":auto_interval_steps>=40 ? "2":auto_interval_steps>=20 ? "1":"0";
                if(col==8) menu_char="0"+(auto_interval_steps==60 ? 0:
                    ((auto_interval_steps>=40 ? auto_interval_steps-40:
                    auto_interval_steps>=20 ? auto_interval_steps-20:auto_interval_steps)>>1));
                if(col==9) menu_char=auto_interval_steps[0] ? "5":"0";
            end
        end
    endfunction

    // 本拍要写进文本 RAM 的字符（组合）
    reg [7:0] line_byte;
    reg       line_attr;

    always @(*) begin
        if (line_is_status) begin
            line_byte = status_kind==ST_NOTTXT ? menu_rom_char:status_char(status_kind, draw_i[4:0], 4'd0, 4'd0, 4'd0);
            line_attr = (line_byte != " ") && (line_byte != 8'h00);
        end else if (line_blank) begin
            line_byte = " ";
            line_attr = 1'b0;
        end else if (draw_i < {2'd0, prefix_len}) begin
            line_byte = prefix_char(draw_i[4:0]);
            line_attr = 1'b1;                               // [DIR] 使用统一白色属性
        end else if ((draw_i - {2'd0, prefix_len}) < {2'd0, name_len_l}) begin
            line_byte = name_q;
            line_attr = 1'b0;
        end else begin
            line_byte = " ";
            line_attr = 1'b0;
        end
    end

    //=========================================================================
    // 主状态机
    //=========================================================================
    assign legacy_next_pulse=key_sel_press && !ui_active;
    assign ui_page=page;
    // Keep submenu navigation live while its text buffer is being refreshed.
    // The transition selection is a cursor-only overlay, so it does not need
    // to wait for S_MENU_DRAW to finish before responding to arrow keys.
    assign ui_navigable=!text_osd_page && page!=7 &&
        (state_hot[S_SETTINGS] || state_hot[S_OPEN] || state_hot[S_BRIGHTNESS] ||
         state_hot[S_CONTRAST] || (page==6 && state_hot[S_MENU_DRAW]));
    wire idle_ok = img_idle && !fat_busy;

    // 光标：仅 cur 一个寄存器，行列都从它派生。
    // cur_next/page_chg 预寄存（100 MHz setup 收口）：原组合链
    // 「cur+1≥ent_cnt 比较 → cur_next → 页基比较」直达 cur.ce /
    // scan_page_base.ce / state 次态。cur 只在 key_sel_pulse 时变、
    // 两次按键间隔 ≥50 ms 消抖，预寄存值在使用点必然新鲜。
    reg  [15:0] cur_next_r;
    reg         page_chg_r;
    reg [15:0] cur_prev_r;reg prev_page_chg_r;
    wire [15:0] cur_prev_w=cur==0 ? (ent_cnt==0 ? 16'd0:ent_cnt-1'b1):cur-1'b1;
    wire [15:0] selected_cur=action_up ? cur_prev_r:cur_next_r;
    wire selected_page_chg=action_up ? prev_page_chg_r:page_chg_r;
    wire [15:0] cur_next_w  = (cur + 16'd1 >= ent_cnt) ? 16'd0 : (cur + 16'd1);
    wire        page_chg_w  = ({cur_next_w[15:3],3'b000} != cache_page_base);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cur_next_r <= 16'd0;
            page_chg_r <= 1'b0;cur_prev_r<=0;prev_page_chg_r<=0;
        end else begin
            cur_prev_r<=cur_prev_w;prev_page_chg_r<=({cur_prev_w[15:3],3'b000}!=cache_page_base);
            cur_next_r <= cur_next_w;
            page_chg_r <= page_chg_w;
        end
    end
    wire [15:0] scan_slot = scan_count - scan_page_base;
    // Default pages are aligned to eight entries. Avoid a carry chain followed
    // by two range comparators on the metadata/name write enables.
    wire        capture_this_entry = PAGE_LINES==8 ?
                                     (scan_count[15:3]==scan_page_base[15:3]) :
                                     ((scan_count >= scan_page_base) &&
                                      (scan_count < scan_page_base + PAGE_LINES));

    integer k;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state_hot <= (16'b1 << S_MENU_DRAW);page<=1;draw_return_hot <= (16'b1 << S_CLOSED);menu_addr<=0;menu_read_phase<=0;
            subtitle_sel<=0;subtitle_drawn<=0;subtitle_display_toggle<=0;subtitle_auto_toggle<=0;subtitle_clear<=0;pending_txt<=0;ext_txt_req<=0;
            settings_sel<=0;transition_sel<=0;transition_mode<=0;auto_interval_steps<=1;auto_interval_changed<=0;text_osd_page<=0;volume_drawn<=20;volume_increase<=0;volume_decrease<=0;contrast_level<=10;saturation_level<=10;brightness_level<=10;mode_drawn<=0;gesture_cancel<=0;
            scan_inflight<=0;load_inflight<=0;drain_count<=0;
            load_kind<=0;load_cluster<=0;load_size<=0;load_apply_q<=0;
            dir_own_r<=0; dir_start<=0;
            ent_cnt<=0; cur<=0; scan_count<=0; scan_page_base<=0; cache_page_base<=0;
            status_kind<=ST_BLANK;
            cur_name_len<=0;
            overlay_match<=1;overlay_name_len<=0;
            ui_active<=0; ui_commit_toggle<=0; ui_wr_en<=0; ui_wr_addr<=0; ui_wr_data<=0;
            ext_load_req<=0; ext_load_cluster<=0; ext_load_size<=0; auto_toggle_pulse<=0;
            ext_play_req<=0; ext_play_cluster<=0; ext_play_size<=0; pending_play<=0;
            name_c0<=0; name_c1<=0; name_c2<=0; name_c3<=0;
            dphase<=D_IDLE; draw_row<=0; draw_i<=0; draw_ent<=0; draw_return_hot <= (16'b1 << S_CLOSED);
            draw_status_only<=0; line_blank<=0; line_is_status<=0;
            prefix_len<=0; name_len_l<=0;
            name_wr_en<=0; name_wr_addr<=0; name_wr_data<=0;
            meta_wr_en<=0; meta_wr_addr<=0; meta_wr_data<=0;
            name_rd_addr<=0; meta_rd_addr<=0; wait_cnt<=0;
        end else begin
            gesture_cancel<=0;
            auto_interval_changed<=0;
            // Closed/returned menus still drain directory and submitted load transactions.
            if(scan_inflight) begin
                if(dir_done || drain_count>=TIMEOUT_DIR) begin scan_inflight<=0;dir_own_r<=0;drain_count<=0;end
                else drain_count<=drain_count+1'b1;
            end
            else if(load_inflight) begin
                if(ext_load_ack || ext_load_rejected || ext_play_ack || ext_play_rejected || ext_txt_ack || ext_txt_rejected || drain_count>=(pending_txt ? TIMEOUT_DIR:TIMEOUT_1S)) begin
                    load_inflight<=0;drain_count<=0;
                end else drain_count<=drain_count+1'b1;
            end
            // 默认电平
            dir_start<=0; ui_wr_en<=0; name_wr_en<=0; meta_wr_en<=0;
            ext_txt_req<=0;subtitle_display_toggle<=0;subtitle_auto_toggle<=0;subtitle_clear<=0;
            ext_load_req<=0; ext_play_req<=0; auto_toggle_pulse<=0;volume_increase<=0;volume_decrease<=0;

            // Transition rows only move the cursor. Handle them independently
            // of the draw-state FSM so the first arrow press is not lost while
            // the submenu text is still being written.
            if(input_block!==1'b1 && ui_active && page==6) begin
                if(action_up) transition_sel<=transition_sel==0 ? 2'd3:transition_sel-1'b1;
                else if(action_down || key_sel_pulse) transition_sel<=transition_sel==3 ? 2'd0:transition_sel+1'b1;
            end

            //-----------------------------------------------------------------
            // 目录条目捕获（只在 S_CAPTURE 生效，避免和图像层互相串）
            //-----------------------------------------------------------------
            if (state_hot[S_CAPTURE]) begin
                if (dir_entry_start) begin
                    cur_name_len<=0;
                    name_c0<=0; name_c1<=0; name_c2<=0; name_c3<=0;
                    overlay_match<=1;
                    overlay_name_len<=0;
                end
                if(dir_name_valid) begin
                    overlay_name_len<=dir_name_index+8'd1;
                    if(dir_name_index>=11 || fold_overlay_char(dir_name_char)!=overlay_expected_char(dir_name_index[3:0]))
                        overlay_match<=0;
                end
                if (dir_name_valid && capture_this_entry) begin
                    // 末 4 字符滚动窗口对**整个名字**生效（长名扩展名可落在 32 之后）
                    name_c0 <= name_c1;
                    name_c1 <= name_c2;
                    name_c2 <= name_c3;
                    name_c3 <= dir_name_char;
                    cur_name_len <= dir_name_index + 8'd1;
                    if (dir_name_index < COLS) begin
                        name_wr_en   <= 1'b1;
                        name_wr_addr <= {scan_slot[2:0], dir_name_index[4:0]};
                        name_wr_data <= dir_name_char;
                    end
                end
                if (dir_entry_end) begin
                    // Root-only browser: directories cannot be opened and must
                    // not consume a list slot (e.g. System Volume Information).
                    if (capture_this_entry && !dir_entry_is_dir && !(overlay_match && overlay_name_len==11)) begin
                        meta_wr_en   <= 1'b1;
                        meta_wr_addr <= scan_slot[2:0];
                        // Two-bit kind preserves the 72-bit metadata RAM:
                        // 00 image/other, 01 directory, 10 WAV, 11 TXT.
                        meta_wr_data <= {dir_entry_is_dir ? 2'b01:
                                         (cur_name_len>=4 && is_dotwav(name_c0,name_c1,name_c2,name_c3)) ? 2'b10:
                                         (cur_name_len>=4 && is_dottxt(name_c0,name_c1,name_c2,name_c3)) ? 2'b11:2'b00,
                                         (cur_name_len > COLS_C6) ? COLS_C6 : cur_name_len[5:0],
                                         dir_entry_size, dir_entry_first_cluster};
                    end
                    if (!dir_entry_is_dir && !(overlay_match && overlay_name_len==11) && scan_count != 16'hffff)
                        scan_count <= scan_count + 16'd1;
                end
            end

            //-----------------------------------------------------------------
            // 关窗时长按 KEY2：切换自动轮播（打开状态下的长按不触发）
            //-----------------------------------------------------------------
            // Do not interpret a long/repeated KEY2 during an image transfer as
            // an auto-play command.  Auto-play can only be toggled from the
            // fully idle, closed-window state.
            if (input_block!==1'b1 && key_sel_hold && (state_hot[S_CLOSED]) && !ui_active &&
                img_ready && !fat_busy)
                auto_toggle_pulse <= 1'b1;

            //-----------------------------------------------------------------
            // 主状态
            //-----------------------------------------------------------------
            // Global gestures outrank every browser/render substate.
            if(force_close===1'b1) begin
                ui_active<=0;text_osd_page<=0;page<=1;gesture_cancel<=1;
                dphase<=D_IDLE;menu_addr<=0;menu_read_phase<=0;
                if(!scan_inflight) dir_own_r<=0;
                state_hot <= (16'b1 << S_CLOSED);ui_commit_toggle<=~ui_commit_toggle;
            end else if(input_block===1'b1) begin
                gesture_cancel<=1;
            end else if(key_open_pulse || action_open || (action_back && ui_active && page==1 && !text_osd_page)) begin
                text_osd_page<=0;
                gesture_cancel<=1;dphase<=D_IDLE;menu_addr<=0;menu_read_phase<=0;
                if(!scan_inflight) dir_own_r<=0;
                if(ui_active) begin ui_active<=0;page<=1;draw_return_hot <= (16'b1 << S_CLOSED);state_hot <= (16'b1 << S_MENU_DRAW);end
                else begin ui_active<=1;page<=1;draw_return_hot <= (16'b1 << S_SETTINGS);state_hot <= (16'b1 << S_MENU_DRAW);end
            end else if((key_sel_double || action_back) && ui_active && (page!=1 || text_osd_page)) begin
                text_osd_page<=0;
                gesture_cancel<=1;dphase<=D_IDLE;menu_addr<=0;menu_read_phase<=0;
                if(!scan_inflight) dir_own_r<=0;
                page<=1;draw_return_hot <= (16'b1 << S_SETTINGS);state_hot <= (16'b1 << S_MENU_DRAW);
            end else case (1'b1) // synthesis parallel_case
            state_hot[S_SETTINGS]:begin
                if(!text_osd_page && (key_ok_pulse || action_confirm)) begin
                    gesture_cancel<=1;
                    if(settings_sel==9) begin page<=8;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);end
                    else if(settings_sel==8) begin page<=6;transition_sel<=transition_mode;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);end
                    else if(settings_sel==7) begin page<=7;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);end
                    else if(settings_sel==6) begin page<=5;subtitle_sel<=0;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);end
                    else if(settings_sel==5) begin page<=4;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);end
                    else if(settings_sel==4) text_osd_page<=1;
                    else if(settings_sel==3) begin page<=9;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);end
                    else if(settings_sel==2) begin page<=3;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);end
                    else if(settings_sel==1) begin page<=2;menu_addr<=0;draw_return_hot <= (16'b1 << S_BRIGHTNESS);state_hot <= (16'b1 << S_MENU_DRAW);end
                    else if(!scan_inflight && !load_inflight) begin
                        page<=0;ent_cnt<=0;cur<=0;scan_page_base<=0;cache_page_base<=0;
                        status_kind<=idle_ok ? ST_SCAN:ST_BUSY;state_hot <= (16'b1 << S_OPEN_INIT);
                    end
                end else if(!text_osd_page && action_up) settings_sel<=settings_sel==0 ? 4'd9:settings_sel-1'b1;
                else if(!text_osd_page && (key_sel_pulse || action_down)) settings_sel<=settings_sel==9 ? 4'd0:settings_sel+1'b1;
            end
            state_hot[S_BRIGHTNESS]:begin
                if((action_left || (key_ok_pulse && !action_right)) && brightness_level>1) begin
                    brightness_level<=brightness_level-1'b1;menu_addr<=0;draw_return_hot <= (16'b1 << S_BRIGHTNESS);state_hot <= (16'b1 << S_MENU_DRAW);
                end else if((action_right || (key_sel_pulse && !action_left)) && brightness_level<10) begin
                    brightness_level<=brightness_level+1'b1;menu_addr<=0;draw_return_hot <= (16'b1 << S_BRIGHTNESS);state_hot <= (16'b1 << S_MENU_DRAW);
                end else if(mode_drawn!=brightness_mode) begin
                    menu_addr<=0;draw_return_hot <= (16'b1 << S_BRIGHTNESS);state_hot <= (16'b1 << S_MENU_DRAW);
                end
            end
            state_hot[S_CONTRAST]:begin
                if(page==7) begin
                    // The local render editor owns values and matrix events.
                    // Only the global return/close gestures above act here.
                end else if(page==6) begin
                    if(action_confirm || key_ok_pulse) begin
                        transition_mode<=transition_sel;menu_addr<=0;
                        draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);
                    end
                end else if(page==8) begin
                    if((action_left || (key_ok_pulse && !action_right)) && auto_interval_steps>1) begin
                        auto_interval_steps<=auto_interval_steps-1'b1;auto_interval_changed<=1;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);
                    end else if((action_right || (key_sel_pulse && !action_left)) && auto_interval_steps<60) begin
                        auto_interval_steps<=auto_interval_steps+1'b1;auto_interval_changed<=1;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);
                    end
                end else if(page==5) begin
                    if(action_up) subtitle_sel<=subtitle_sel==0 ? 2'd2:subtitle_sel-1'b1;
                    else if(action_down || key_sel_pulse) subtitle_sel<=subtitle_sel==2 ? 2'd0:subtitle_sel+1'b1;
                    if(action_confirm || key_ok_pulse) begin
                        case(subtitle_sel) 0:subtitle_display_toggle<=1;1:subtitle_auto_toggle<=1;2:subtitle_clear<=1;endcase
                    end
                    if(subtitle_drawn!={subtitle_display,subtitle_auto,subtitle_status}) begin menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);end
                end else if(page==4) begin
                    if(action_left || (key_ok_pulse && !action_right)) volume_decrease<=1;
                    else if(action_right || (key_sel_pulse && !action_left)) volume_increase<=1;
                    if(volume_drawn!=volume_level) begin menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);end
                end else if(page==9) begin
                    if((action_left || (key_ok_pulse && !action_right)) && saturation_level>0) begin
                        saturation_level<=saturation_level-1'b1;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);
                    end else if((action_right || (key_sel_pulse && !action_left)) && saturation_level<20) begin
                        saturation_level<=saturation_level+1'b1;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);
                    end
                end else if((action_left || (key_ok_pulse && !action_right)) && contrast_level>0) begin
                    contrast_level<=contrast_level-1'b1;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);
                end else if((action_right || (key_sel_pulse && !action_left)) && contrast_level<20) begin
                    contrast_level<=contrast_level+1'b1;menu_addr<=0;draw_return_hot <= (16'b1 << S_CONTRAST);state_hot <= (16'b1 << S_MENU_DRAW);
                end
            end
            state_hot[S_MENU_DRAW]:begin
                if(menu_addr==0) begin subtitle_drawn<={subtitle_display,subtitle_auto,subtitle_status};mode_drawn<=brightness_mode;volume_drawn<=volume_level;end
                if(menu_addr<LINES*COLS) begin
                  if(menu_read_phase<2) menu_read_phase<=menu_read_phase+1'b1;
                  else begin
                    menu_read_phase<=0;
                    ui_wr_en<=1;ui_wr_addr<=menu_addr;
                    if(page==5 && menu_addr[8:5]==6) ui_wr_data<=menu_rom_char;
                    else if(page==6 && menu_addr[8:5]>=2 && menu_addr[8:5]<=5 && menu_addr[4:0]==15)
                        ui_wr_data<=(transition_mode==menu_addr[8:5]-5'd2) ? 8'h2a:8'h20;
                    else if(page==5 && (menu_addr[8:5]==2 || menu_addr[8:5]==3) && menu_addr[4:0]>=12 && menu_addr[4:0]<15)
                        ui_wr_data<=(menu_addr[4:0]==12) ? "O":(menu_addr[4:0]==13) ? ((menu_addr[8:5]==2 ? subtitle_drawn[5]:subtitle_drawn[4]) ? "N":"F"):
                        ((menu_addr[8:5]==2 ? subtitle_drawn[5]:subtitle_drawn[4]) ? " ":"F");
                    else ui_wr_data<=menu_char(page,menu_addr[8:5],menu_addr[4:0],(page==4) ? volume_drawn:(page==3) ? contrast_level:(page==9) ? saturation_level:{1'b0,brightness_level},mode_drawn,menu_rom_char);
                    menu_addr<=menu_addr+1'b1;
                  end
                end else begin
                    // Last registered write was consumed on the preceding edge.
                    ui_commit_toggle<=~ui_commit_toggle;
                    menu_addr<=0;menu_read_phase<=0;state_hot <= draw_return_hot;
                end
            end
            //-----------------------------------------------------------------
            state_hot[S_CLOSED]: begin
                if(!scan_inflight) dir_own_r<=1'b0;
            end
            //-----------------------------------------------------------------
            state_hot[S_OPEN_INIT]: begin
                // 画"空列表 + SCANNING..."，画完去等图像层空闲
                if (dphase==D_IDLE) begin
                    dphase        <= D_IDLE;
                    draw_row      <= 4'd0;
                    draw_ent      <= 7'd0;
                    draw_status_only <= 1'b0;
                    draw_return_hot <= (16'b1 << S_WAIT_IDLE);
                    state_hot <= (16'b1 << S_DRAW);
                end
            end
            //-----------------------------------------------------------------
            state_hot[S_WAIT_IDLE]: begin
                if (key_open_pulse) begin                 // 还没枚举就关窗
                    ui_active <= 1'b0;
                    state_hot <= (16'b1 << S_CLOSED);
                end else if (idle_ok) begin
                    // Only call it SCANNING once the directory service can
                    // actually be acquired.  Before this point the window
                    // explicitly reports IMAGE BUSY.
                    dir_own_r       <= 1'b1;
                    status_kind    <= ST_SCAN;
                    draw_status_only<=1'b1;
                    draw_return_hot <= (16'b1 << S_REQ_DIR);
                    draw_row       <= 4'd0;
                    dphase         <= D_IDLE;
                    state_hot <= (16'b1 << S_DRAW);
                end
            end
            //-----------------------------------------------------------------
            state_hot[S_REQ_DIR]: begin
                // 等目录口授权后再发启动脉冲，避免与图像层争用时被吞
                if (dir_gnt) begin
                    dir_start <= 1'b1;scan_inflight<=1'b1;drain_count<=0;
                    scan_count<= 16'd0;
                    state_hot <= (16'b1 << S_CAPTURE);
                end
            end
            //-----------------------------------------------------------------
            state_hot[S_CAPTURE]: begin
                if (dir_done) begin
                    dir_own_r <= 1'b0;                    // 目录口用完即还
                    status_kind <= dir_ok ? ST_BLANK : ST_DIRERR;
                    ent_cnt      <= dir_ok ? scan_count : 16'd0;
                    cache_page_base <= scan_page_base;
                    if (!dir_ok || scan_count==0) cur <= 16'd0;
                    draw_status_only <= 1'b0;
                    draw_return_hot <= (16'b1 << S_OPEN);
                    state_hot <= (16'b1 << S_DRAW);
                end else if (key_open_pulse) begin         // 枚举中关窗：等它自然收尾
                    ui_active <= 1'b0;
                    wait_cnt  <= 0;
                    state_hot <= (16'b1 << S_ABORT_WAIT);
                end
            end
            //-----------------------------------------------------------------
            state_hot[S_DRAW]: begin
                case (dphase)
                D_IDLE: begin
                    if (draw_status_only) begin
                        line_blank<=1'b0; line_is_status<=1'b1;
                        draw_row<=LINES-1; draw_i<=6'd0;
                        dphase<=D_CHAR_RD;
                    end else if (draw_row < PAGE_LINES) begin
                        draw_ent <= draw_row[2:0];
                        // Default pages are eight-aligned; valid rows need no wide adder.
                        if ((PAGE_LINES==8 ? {cache_page_base[15:3],draw_row[2:0]}:(cache_page_base + draw_row)) < ent_cnt) begin
                            meta_rd_addr<= draw_row[2:0];
                            dphase<=D_META_W;                    // 给地址
                        end else begin
                            line_blank<=1'b1; line_is_status<=1'b0;
                            draw_i<=6'd0; dphase<=D_CHAR_RD;
                        end
                    end else begin
                        line_blank<=1'b0; line_is_status<=1'b1;
                        draw_i<=6'd0; dphase<=D_CHAR_RD;
                    end
                end
                D_META_W: dphase<=D_META;                        // 等读出口
                D_META: begin
                    // meta_q 本拍有效
                    line_blank<=1'b0; line_is_status<=1'b0;
                    prefix_len <= meta_is_dir ? 4'd6 : 4'd0;
                    name_len_l <= meta_name_len;
                    draw_i<=6'd0; dphase<=D_CHAR_RD;
                end
                D_CHAR_RD: begin
                    name_rd_addr <= {draw_ent[2:0], 5'd0} +
                                    ((draw_i >= {2'd0, prefix_len}) ?
                                     (draw_i - {2'd0, prefix_len}) : 6'd0);
                    dphase<=D_CHAR_WAIT;                         // 给地址
                end
                D_CHAR_WAIT: dphase<=D_CHAR_WR;                  // 等读出口
                D_CHAR_WR: begin
                    ui_wr_en   <= 1'b1;
                    ui_wr_addr <= {draw_row, draw_i[4:0]};
                    ui_wr_data <= {line_attr, line_byte[6:0]};
                    if (draw_i == COLS-1) dphase<=D_NEXT;
                    else begin draw_i<=draw_i+6'd1; dphase<=D_CHAR_RD; end
                end
                D_NEXT: begin
                    if (draw_row == LINES-1) begin
                        ui_commit_toggle <= ~ui_commit_toggle;
                        draw_row <= 4'd0;            // 下一轮整页重画从第 0 行开始
                        dphase   <= D_IDLE;
                        state_hot <= draw_return_hot;
                    end else begin
                        draw_row <= draw_row + 4'd1;
                        dphase   <= D_IDLE;
                    end
                end
                default: dphase<=D_IDLE;
                endcase
            end
            //-----------------------------------------------------------------
            state_hot[S_OPEN]: begin
                if (key_open_pulse) begin
                    ui_active <= 1'b0;
                    state_hot <= (16'b1 << S_CLOSED);
                end else if ((key_sel_pulse || action_down || action_up) && !(key_ok_pulse || action_confirm) && (ent_cnt != 16'd0)) begin
                    cur <= selected_cur;
                    if (status_kind != ST_SCAN)
                        status_kind <= ST_BLANK;
                    if (selected_page_chg) begin
                        scan_page_base   <= {selected_cur[15:3],3'b000};
                        status_kind      <= ST_SCAN;
                        state_hot <= (16'b1 << S_WAIT_IDLE);
                    end
                end else if ((key_ok_pulse || action_confirm) && (ent_cnt != 16'd0)) begin
                    meta_rd_addr <= cur[2:0];
                    state_hot <= (16'b1 << S_LOAD_W);      // 先给地址，等一拍再取 meta_q
                end
            end
            //-----------------------------------------------------------------
            state_hot[S_LOAD_W]: state_hot <= (16'b1 << S_LOAD_RD);          // 等 meta_ram 读出口
            //-----------------------------------------------------------------
            state_hot[S_LOAD_RD]: begin
                if (!load_apply_q) begin
                    load_kind    <= meta_is_dir ? 2'd0 : meta_is_txt ? 2'd1 : meta_is_wav ? 2'd2 : 2'd3;
                    load_cluster <= meta_cluster;
                    load_size    <= meta_size;
                    load_apply_q <= 1'b1;
                end else begin
                    load_apply_q <= 1'b0;
                    if (load_kind == 2'd0) begin
                        // 目录项不可选：直接当"不是 BMP"处理，不发请求
                        status_kind      <= ST_NOTBMP;
                        draw_status_only <= 1'b1;
                        draw_return_hot <= (16'b1 << S_OPEN);
                        state_hot <= (16'b1 << S_DRAW);
                    end else if (load_kind == 2'd1) begin
                        pending_txt<=1;pending_play<=0;
                        status_kind<=ST_LOAD;draw_status_only<=1;draw_return_hot <= (16'b1 << S_LOAD_REQ);state_hot <= (16'b1 << S_DRAW);
                    end else if (load_kind == 2'd2) begin
                        // .WAV：走播放握手，绝不发 ext_load_req
                        ext_play_cluster <= load_cluster;
                        ext_play_size    <= load_size;
                        pending_txt<=0;pending_play     <= 1'b1;
                        status_kind      <= ST_LOAD;
                        draw_status_only <= 1'b1;
                        draw_return_hot <= (16'b1 << S_LOAD_REQ);
                        state_hot <= (16'b1 << S_DRAW);
                    end else begin
                        ext_load_cluster <= load_cluster;
                        ext_load_size    <= load_size;
                        pending_txt<=0;pending_play     <= 1'b0;
                        status_kind      <= ST_LOAD;
                        draw_status_only <= 1'b1;
                        draw_return_hot <= (16'b1 << S_LOAD_REQ);
                        state_hot <= (16'b1 << S_DRAW);
                    end
                end
            end
            //-----------------------------------------------------------------
            state_hot[S_LOAD_REQ]: begin
                load_inflight<=1;drain_count<=0;
                if(pending_txt) ext_txt_req<=1;
                else if (pending_play) ext_play_req <= 1'b1;   // 正好一拍
                else              ext_load_req <= 1'b1;   // 正好一拍
                wait_cnt     <= 0;
                state_hot <= (16'b1 << S_LOAD_WAIT);
            end
            //-----------------------------------------------------------------
            state_hot[S_LOAD_WAIT]: begin
                if(pending_txt) begin
                    if(ext_txt_ack) begin ui_active<=0;state_hot <= (16'b1 << S_CLOSED);end
                    else if(ext_txt_rejected || wait_cnt>=TIMEOUT_DIR) begin status_kind<=ST_NOTTXT;draw_status_only<=1;draw_return_hot <= (16'b1 << S_OPEN);state_hot <= (16'b1 << S_DRAW);end
                    else wait_cnt<=wait_cnt+1'b1;
                end else if (pending_play) begin
                    if (ext_play_ack) begin
                        ui_active <= 1'b0;                // 头合法：关窗，继续播
                        state_hot <= (16'b1 << S_CLOSED);
                    end else if (ext_play_rejected) begin
                        status_kind      <= ST_NOTWAV;
                        draw_status_only <= 1'b1;
                        draw_return_hot <= (16'b1 << S_OPEN);
                        state_hot <= (16'b1 << S_DRAW);
                    end else if (wait_cnt >= TIMEOUT_1S) begin
                        status_kind      <= ST_NOTWAV;
                        draw_status_only <= 1'b1;
                        draw_return_hot <= (16'b1 << S_OPEN);
                        state_hot <= (16'b1 << S_DRAW);
                    end else wait_cnt <= wait_cnt + 31'd1;
                end else begin
                    if (ext_load_ack) begin
                        ui_active <= 1'b0;                // 确认成功：关窗，让图显示
                        state_hot <= (16'b1 << S_CLOSED);
                    end else if (ext_load_rejected) begin
                        // ★ 软错误：窗口不关、光标不动，只在状态行提示，绝不进死锁
                        status_kind      <= ST_NOTBMP;
                        draw_status_only <= 1'b1;
                        draw_return_hot <= (16'b1 << S_OPEN);
                        state_hot <= (16'b1 << S_DRAW);
                    end else if (wait_cnt >= TIMEOUT_1S) begin
                        // 图像层久久不回应（例如 SD 掉卡）也按"不是 BMP"处理
                        status_kind      <= ST_NOTBMP;
                        draw_status_only <= 1'b1;
                        draw_return_hot <= (16'b1 << S_OPEN);
                        state_hot <= (16'b1 << S_DRAW);
                    end else wait_cnt <= wait_cnt + 31'd1;
                end
            end
            //-----------------------------------------------------------------
            state_hot[S_ABORT_WAIT]: begin
                if (dir_done) begin
                    dir_own_r <= 1'b0;
                    state_hot <= (16'b1 << S_CLOSED);
                end else if (wait_cnt >= TIMEOUT_DIR) begin
                    dir_own_r <= 1'b0;                    // 兜底：超时强行放口
                    state_hot <= (16'b1 << S_CLOSED);
                end else wait_cnt <= wait_cnt + 31'd1;
            end
            //-----------------------------------------------------------------
            default: state_hot <= (16'b1 << S_CLOSED);
            endcase
        end
    end

endmodule

