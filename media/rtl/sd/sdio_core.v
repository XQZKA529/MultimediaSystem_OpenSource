//=============================================================================
// module : sdio_core
// 文件名 : rtl/sd/sdio_core.v
// 功  能 : 【SDIO 引擎】SD 模式（非 SPI）4-bit 初始化 + 数据读
//
//  一、为什么是 SD 模式而不是 SPI
//      SPI 模式只有 1 根数据线、25 MHz，实测有效吞吐 ≈3.06 MB/s，这是
//      "图片能显示但视频不可能" 的根因。SD 模式 4-bit 在默认速度(25MHz)
//      就是 4 倍，高速(50MHz)是 8 倍。
//
//  二、初始化序列（SD 物理层规范）
//      CMD0 (无响应)              → 进 IDLE
//      CMD8 arg=0x1AA (R7)        → 电压/版本查询；无响应 = v1.x 卡，本设计不支持
//      CMD55 + ACMD41 (R3)        → 轮询 OCR，直到 busy/ready(bit31)=1；
//                                   CCS(bit30)=1 表示 SDHC/SDXC
//      CMD2 (R2)                  → 取 CID（只收不解析）
//      CMD3 (R6)                  → 取 RCA
//      CMD7 arg=RCA<<16 (R1)      → 选中卡
//      CMD55 + ACMD6 arg=2 (R1)   → ★ 切到 4-bit 总线
//      CMD6 arg=0x80FFFFF1 (R1+64B)→ ★ 切到 High Speed（SPEED_TARGET=1 时）
//      CMD16 arg=512 (R1)         → 设定块长
//      之后进入 READY，接受读请求。
//
//  三、4-bit 数据包格式（关键，最容易写错的地方）
//      一个数据块在 DAT[3:0] 上按"每时钟 4 bit"传送，数据位序为
//        DAT3 先发（= 字节的 bit7）… DAT0 最后（= bit0）
//      整块时序（以 512 字节为例）：
//        第 1 个 SD 时钟 : 起始位 —— DAT[3:0]=4'b0000
//                          注意这一拍**不承载数据**
//        接着 1024 个时钟 : 512 字节数据，每时钟一个 nibble，高 nibble 先
//        接着 16 个时钟  : DAT0..3 每根线各自的 CRC16，MSB 先
//        最后 1 个时钟   : 结束位 —— DAT[3:0]=4'b1111
//      合计 1 + 1024 + 16 + 1 = 1042 个 SD 时钟。
//
//  四、读通道（对外契约，故意做成"突发式"以便视频/音乐复用）
//      rd_start 1 拍 → 锁存 rd_sector/rd_count，rd_busy 拉高
//      → rd_data/rd_data_valid 逐字节流出（rd_count 个扇区连续）
//      → rd_end 1 拍脉冲结束；出错时 rd_error 同时置起
//      rd_count==1 用 CMD17（单块读，无需停止命令）
//      rd_count>1  用 CMD18（多块读）+ CMD12（停止）
//
//  五、时钟切换节奏（与规范一致）
//      初始化阶段 400 kHz → CMD7 之后切默认速度 25 MHz
//      → CMD6 成功之后再切 50 MHz（High Speed）
//=============================================================================
module sdio_core #(
    parameter integer CLK_FREQ_HZ    = 100_000_000,
    parameter integer SD_CLK_DIV_INIT= 125,           // 400 kHz
    parameter integer SD_CLK_DIV_FAST= 2,             // 25 MHz  默认速度
    parameter integer SD_CLK_DIV_HS  = 1,             // 50 MHz  高速
    parameter integer SAMPLE_DLY     = 0,             // 采样点后移 clk 数（调相位旋钮）
    parameter [15:0]  NCR_TIMEOUT    = 16'd4000,      // 命令响应超时（SD 时钟数）
    parameter [23:0]  DATA_TIMEOUT   = 24'd6_000_000, // 等数据起始令牌超时（clk 拍，100MHz 下 60ms）
    parameter [15:0]  ACMD41_RETRY   = 16'd4000,      // ACMD41 轮询上限
    parameter integer SPEED_TARGET   = 1              // 1=尝试 High Speed(50MHz)
)(
    input  wire        clk,
    input  wire        rst,             // 异步复位，高有效

    // ---- SD 引脚侧（父模块负责接 pad / 三态）----
    output wire        SD_CLK,
    output wire        cmd_oe,
    output wire        cmd_out,
    input  wire        cmd_in,
    input  wire [3:0]  dat_in,

    // ---- 初始化状态 ----
    output reg         init_done,
    output reg         init_error,
    output reg         is_sdhc,
    output reg         high_speed,      // 卡已切到 High Speed
    output reg  [1:0]  bus_width,       // 0=1bit 1=4bit
    output reg  [15:0] card_rca,
    output reg  [7:0]  init_err_code,   // 1=CMD8无响应 2=非SDHC 3=ACMD41 4=CMD6 5=ACMD6 6=CMD3/RCA 7=CMD7 8=CMD7 busy 9=CMD8坏响应

    // ---- 读通道（突发）----
    input  wire        rd_start,
    input  wire [31:0] rd_sector,
    input  wire [15:0] rd_count,
    output reg         rd_busy,
    output reg  [7:0]  rd_data,
    output reg         rd_data_valid,
    output reg         rd_end,
    output reg         rd_error,

    // ---- 调试 ----
    output wire [4:0]  dbg_state,
    output wire [3:0]  dbg_phy_state,
    output wire [5:0]  dbg_resp_cmd,
    output wire [31:0] dbg_resp_arg,
    output wire [15:0] dbg_crc_err_cnt,
    output wire [15:0] dbg_no_resp_cnt,
    output wire [7:0]  dbg_switch_fn,         // CMD6 返回块的第 16 字节（访问模式）
    output wire [15:0] dbg_clk_div            // 当前 SD_CLK 半周期 clk 数
);

    //=========================================================================
    // 状态编码
    //=========================================================================
    localparam integer I_S_PWR=0;    // 上电时钟
    localparam integer I_S_CMD0=1;
    localparam integer I_S_CMD8=2;
    localparam integer I_S_ACMD41_55=3;
    localparam integer I_S_ACMD41=4;
    localparam integer I_S_CMD2=5;
    localparam integer I_S_CMD3=6;
    localparam integer I_S_CMD7=7;
    localparam integer I_S_ACMD6_55=8;
    localparam integer I_S_ACMD6=9;
    localparam integer I_S_HS_CMD6=10;
    localparam integer I_S_CMD16=11;
    localparam integer I_S_READY=12;
    localparam integer I_S_RD_CMD=13;
    localparam integer I_S_CMD7_BUSY=14;
    localparam integer I_S_RD_STOP=15;
    localparam integer I_S_RD_DONE=16;
    localparam integer I_S_ERR=17;
    // 数据相位（CMD6 的 64 字节块与数据块共用）
    localparam integer I_S_D_WAIT=18;
    localparam integer I_S_D_DATA=19;
    localparam integer I_S_D_CRC=20;
    localparam integer I_S_D_END=21;
    localparam integer I_S_RD_STOP_BUSY=22;
    // 多块读异常收尾：只补一条 CMD12（不判对错），把卡从 data state 拉出来。
    // ★ 没有这一拍时：CMD18 之后中途放弃读取而不发 CMD12，卡会继续把剩余数据块
    //   吐完，此后任何命令都得不到响应 ⇒ 整条 SD 链路"卡死到断电"，上层重试也白搭。
    localparam integer I_S_RD_ABORT=23;

    localparam [23:0] S_PWR=24'b1 << I_S_PWR,S_CMD0=24'b1 << I_S_CMD0,S_CMD8=24'b1 << I_S_CMD8,S_ACMD41_55=24'b1 << I_S_ACMD41_55,S_ACMD41=24'b1 << I_S_ACMD41,S_CMD2=24'b1 << I_S_CMD2,S_CMD3=24'b1 << I_S_CMD3,S_CMD7=24'b1 << I_S_CMD7,S_ACMD6_55=24'b1 << I_S_ACMD6_55,S_ACMD6=24'b1 << I_S_ACMD6,S_HS_CMD6=24'b1 << I_S_HS_CMD6,S_CMD16=24'b1 << I_S_CMD16,S_READY=24'b1 << I_S_READY,S_RD_CMD=24'b1 << I_S_RD_CMD,S_CMD7_BUSY=24'b1 << I_S_CMD7_BUSY,S_RD_STOP=24'b1 << I_S_RD_STOP,S_RD_DONE=24'b1 << I_S_RD_DONE,S_ERR=24'b1 << I_S_ERR,S_D_WAIT=24'b1 << I_S_D_WAIT,S_D_DATA=24'b1 << I_S_D_DATA,S_D_CRC=24'b1 << I_S_D_CRC,S_D_END=24'b1 << I_S_D_END,S_RD_STOP_BUSY=24'b1 << I_S_RD_STOP_BUSY,S_RD_ABORT=24'b1 << I_S_RD_ABORT;
    reg [23:0] state;
    // The state vector is one-hot. Encode the debug bus with parallel bit
    // groups instead of a priority loop so SD input paths do not pass through
    // a multi-level priority encoder merely to reach DBG_SD_STATE.
    wire [4:0] state_dbg = {
        |state[23:16],
        |state[15:8],
        (|state[23:20]) | (|state[15:12]) | (|state[7:4]),
        (|state[23:22]) | (|state[19:18]) | (|state[15:14]) |
        (|state[11:10]) | (|state[7:6]) | (|state[3:2]),
        state[23] | state[21] | state[19] | state[17] | state[15] | state[13] |
        state[11] | state[9] | state[7] | state[5] | state[3] | state[1]
    };
    reg [1:0]  clk_sel;

    //=========================================================================
    // 子模块：物理层 + 命令层
    //=========================================================================
    wire ck_rise, ck_fall;
    wire [15:0] clk_div_dbg;

    sdio_phy #(
        .SD_CLK_DIV_INIT(SD_CLK_DIV_INIT),
        .SD_CLK_DIV_FAST(SD_CLK_DIV_FAST),
        .SD_CLK_DIV_HS  (SD_CLK_DIV_HS),
        .SAMPLE_DLY     (SAMPLE_DLY)
    ) u_phy (
        .clk(clk), .rst(rst), .clk_sel(clk_sel),
        .sdclk(SD_CLK), .ck_rise(ck_rise), .ck_fall(ck_fall),
        .clk_div_dbg(clk_div_dbg)
    );

    reg         cmd_issue;
    reg  [5:0]  c_idx;
    reg  [31:0] c_arg;
    reg  [1:0]  c_type;
    wire        cmd_busy, cmd_done, cmd_no_resp, cmd_crc_err, cmd_end_bad;
    wire [5:0]  resp_cmd;
    wire [31:0] resp_arg;
    wire [135:0] resp_r2;
    wire [3:0]  cmd_dbg_state;

    sdio_cmd u_cmd (
        .clk(clk), .rst(rst), .ck_rise(ck_rise), .ck_fall(ck_fall),
        .issue(cmd_issue), .cmd_idx(c_idx), .cmd_arg(c_arg),
        .resp_type(c_type), .resp_timeout(NCR_TIMEOUT),
        .busy(cmd_busy), .done(cmd_done), .no_resp(cmd_no_resp),
        .crc_err(cmd_crc_err), .end_bad(cmd_end_bad),
        .resp_cmd(resp_cmd), .resp_arg(resp_arg), .resp_r2(resp_r2),
        .cmd_oe(cmd_oe), .cmd_out(cmd_out), .cmd_in(cmd_in),
        .dbg_state(cmd_dbg_state), .dbg_tmo_clk()
    );

    //=========================================================================
    // 响应类型常量
    //=========================================================================
    localparam R_NONE = 2'd0;
    localparam R_R1   = 2'd1;   // 48bit，校验 CRC7
    localparam R_R37  = 2'd2;   // 48bit，不校验
    localparam R_R2   = 2'd3;   // 136bit

    //=========================================================================
    // 内部寄存器
    //=========================================================================
    reg         cmd_fired;          // 本状态是否已发起命令
    reg  [15:0] pwr_cnt;
    reg  [15:0] acmd41_cnt;
    reg  [15:0] rd_blk_left;        // 剩余扇区数
    reg  [31:0] rd_sec_lat;         // 起始扇区
    reg  [15:0] rd_cnt_lat;

    // 数据相位上下文
    reg  [11:0] blk_nib_total;      // 本块 nibble 总数 = 2 * 字节数
    reg  [11:0] nib_cnt;
    reg  [3:0]  hi_nib;
    reg  [3:0]  crc_nib;
    reg  [23:0] d_tmo;
    reg         d_tmo_en;
    reg  [7:0]  switch_fn;
    reg  [5:0]  byte_in_blk;        // CMD6 块里抓第 16 字节用

    reg  [15:0] crc_err_cnt;
    reg  [15:0] no_resp_cnt;
    reg         d_crc_bad;          // 数据块 CRC16 校验失败

    // CRC16（数据块）
    reg         crc16_clr, crc16_en;
    reg  [3:0]  crc16_nib;
    wire [15:0] crc16_dat0;
    wire [15:0] crc16_dat1;
    wire [15:0] crc16_dat2;
    wire [15:0] crc16_dat3;

    sd_crc16 u_crc16 (
        .clk(clk), .rst(rst), .clr(crc16_clr), .en(crc16_en),
        .dat_in(crc16_nib),
        .crc_dat0(crc16_dat0), .crc_dat1(crc16_dat1),
        .crc_dat2(crc16_dat2), .crc_dat3(crc16_dat3)
    );

    assign dbg_state       = state_dbg;
    assign dbg_phy_state   = cmd_dbg_state;
    assign dbg_resp_cmd    = resp_cmd;
    assign dbg_resp_arg    = resp_arg;
    assign dbg_crc_err_cnt = crc_err_cnt;
    assign dbg_no_resp_cnt = no_resp_cnt;
    assign dbg_switch_fn   = switch_fn;
    assign dbg_clk_div     = clk_div_dbg;

    // 本拍从 DAT 上取到的 nibble（DAT3 是首发的 bit = 字节 bit7）
    wire [3:0] dat_nib = dat_in;
    wire [3:0] crc16_expect = {
        crc16_dat3[4'd15 - crc_nib], crc16_dat2[4'd15 - crc_nib],
        crc16_dat1[4'd15 - crc_nib], crc16_dat0[4'd15 - crc_nib]
    };

    // 数据相位是否属于 CMD6 的 64 字节响应块
    reg        is_switch_blk;

    //=========================================================================
    // 主状态机
    //=========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= S_PWR;
            clk_sel          <= 2'd0;
            cmd_issue        <= 1'b0;
            c_idx            <= 6'd0;
            c_arg            <= 32'd0;
            c_type           <= R_NONE;
            cmd_fired        <= 1'b0;
            pwr_cnt          <= 16'd0;
            acmd41_cnt       <= 16'd0;
            rd_blk_left      <= 16'd0;
            rd_sec_lat       <= 32'd0;
            rd_cnt_lat       <= 16'd0;
            rd_busy          <= 1'b0;
            rd_data          <= 8'd0;
            rd_data_valid    <= 1'b0;
            rd_end           <= 1'b0;
            init_done        <= 1'b0;
            init_error       <= 1'b0;
            init_err_code    <= 8'd0;
            is_sdhc          <= 1'b0;
            high_speed       <= 1'b0;
            bus_width        <= 2'd0;
            card_rca         <= 16'd0;
            blk_nib_total    <= 12'd0;
            nib_cnt          <= 12'd0;
            hi_nib           <= 4'd0;
            crc_nib          <= 4'd0;
            d_tmo            <= 24'd0;
            d_tmo_en         <= 1'b0;
            switch_fn        <= 8'd0;
            byte_in_blk      <= 6'd0;
            crc_err_cnt      <= 16'd0;
            no_resp_cnt      <= 16'd0;
            crc16_clr        <= 1'b0;
            crc16_en         <= 1'b0;
            crc16_nib        <= 4'd0;
            is_switch_blk    <= 1'b0;
            d_crc_bad        <= 1'b0;
        end else begin
            // 默认电平
            cmd_issue     <= 1'b0;
            rd_data_valid <= 1'b0;
            rd_end        <= 1'b0;
            crc16_clr     <= 1'b0;
            crc16_en      <= 1'b0;

            // 错误计数（只做观察）
            if (cmd_done && cmd_crc_err)  crc_err_cnt  <= crc_err_cnt  + 16'd1;
            if (cmd_done && cmd_no_resp)  no_resp_cnt  <= no_resp_cnt  + 16'd1;

            // 数据相位超时计数
            if (d_tmo_en && (d_tmo < DATA_TIMEOUT))
                d_tmo <= d_tmo + 24'd1;

            case (1'b1)

            //---------------------------------------------------------------
            // 上电：给 ≥74 个 SD 时钟（CMD 由 sdio_cmd 的空闲态主动驱高）
            state[I_S_PWR]: if (ck_fall) begin
                cmd_fired <= 1'b0;
                if (pwr_cnt >= 16'd200) begin
                    state <= S_CMD0;
                end else begin
                    pwr_cnt <= pwr_cnt + 16'd1;
                end
            end

            //---------------------------------------------------------------
            // CMD0：GO_IDLE_STATE，无响应
            state[I_S_CMD0]: begin
                if (!cmd_fired) begin
                    c_idx     <= 6'd0;
                    c_arg     <= 32'd0;
                    c_type    <= R_NONE;
                    cmd_issue <= 1'b1;
                    cmd_fired <= 1'b1;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    state     <= S_CMD8;
                end
            end

            //---------------------------------------------------------------
            // CMD8：SEND_IF_COND，arg=0x1AA，期望回显；无响应=v1.x 卡
            state[I_S_CMD8]: begin
                if (!cmd_fired) begin
                    c_idx     <= 6'd8;
                    c_arg     <= 32'h0000_01AA;
                    c_type    <= R_R1;       // R7 带有效 CRC7
                    cmd_issue <= 1'b1;
                    cmd_fired <= 1'b1;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    if (cmd_no_resp) begin
                        // v1.x 卡：本设计只支持块寻址（SDHC/SDXC），直接报错
                        init_err_code <= 8'd1;
                        state         <= S_ERR;
                    end else if (cmd_crc_err || cmd_end_bad ||
                                 (resp_cmd != 6'd8) || (resp_arg[11:0] != 12'h1AA)) begin
                        // 已看到响应，但 CRC7/结束位/命令号/0x1AA 回显不正确。
                        init_err_code <= 8'd9;
                        state         <= S_ERR;
                    end else begin
                        acmd41_cnt <= 16'd0;
                        state      <= S_ACMD41_55;
                    end
                end
            end

            //---------------------------------------------------------------
            // CMD55：APP_CMD 前导
            state[I_S_ACMD41_55]: begin
                if (!cmd_fired) begin
                    c_idx     <= 6'd55;
                    c_arg     <= 32'd0;
                    c_type    <= R_R1;
                    cmd_issue <= 1'b1;
                    cmd_fired <= 1'b1;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    state     <= S_ACMD41;
                end
            end

            //---------------------------------------------------------------
            // ACMD41：SD_SEND_OP_COND，arg 带 HCS(bit30) + 3.3V 电压窗口；
            // 轮询到 OCR busy/ready(bit31)=1（初始化完成）。
            //   电压窗口 bits[23:0] 必须给全（0x00FF8000 = 2.7~3.6V）。
            //   只给 HCS 而把窗口留 0，部分卡会认为"主机不支持任何电压"而永远 busy。
            state[I_S_ACMD41]: begin
                if (!cmd_fired) begin
                    c_idx     <= 6'd41;
                    c_arg     <= 32'h40FF_8000;   // HCS=1 + 电压窗口 2.7~3.6V
                    c_type    <= R_R37;
                    cmd_issue <= 1'b1;
                    cmd_fired <= 1'b1;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    if (cmd_no_resp) begin
                        // 无响应：回 CMD55 重试
                        if (acmd41_cnt >= ACMD41_RETRY) begin
                            init_err_code <= 8'd3;
                            state         <= S_ERR;
                        end else begin
                            acmd41_cnt <= acmd41_cnt + 16'd1;
                            state      <= S_ACMD41_55;
                        end
                    end else if (!resp_arg[31]) begin
                        // bit31=0：卡仍在上电初始化，继续轮询
                        if (acmd41_cnt >= ACMD41_RETRY) begin
                            init_err_code <= 8'd3;
                            state         <= S_ERR;
                        end else begin
                            acmd41_cnt <= acmd41_cnt + 16'd1;
                            state      <= S_ACMD41_55;
                        end
                    end else begin
                        // bit31=1：初始化完成，此时 CCS 才有效。
                        // CCS(bit30)=1 → SDHC/SDXC（扇区寻址）
                        is_sdhc <= resp_arg[30];
                        if (!resp_arg[30]) begin
                            init_err_code <= 8'd2;   // 非 SDHC，字节寻址，不支持
                            state         <= S_ERR;
                        end else begin
                            state <= S_CMD2;
                        end
                    end
                end
            end

            //---------------------------------------------------------------
            // CMD2：ALL_SEND_CID（R2，136bit，只收不解析）
            state[I_S_CMD2]: begin
                if (!cmd_fired) begin
                    c_idx     <= 6'd2;
                    c_arg     <= 32'd0;
                    c_type    <= R_R2;
                    cmd_issue <= 1'b1;
                    cmd_fired <= 1'b1;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    state     <= S_CMD3;
                end
            end

            //---------------------------------------------------------------
            // CMD3：SEND_RELATIVE_ADDR（R6，取 RCA）
            state[I_S_CMD3]: begin
                if (!cmd_fired) begin
                    c_idx     <= 6'd3;
                    c_arg     <= 32'd0;
                    c_type    <= R_R1;
                    cmd_issue <= 1'b1;
                    cmd_fired <= 1'b1;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    card_rca  <= resp_arg[31:16];
                    // RCA=0 表示"未寻址"，用它发 CMD7 会把卡取消选中，
                    // 后续命令全部无响应 —— 这里直接判定初始化失败，别让它静默变黑屏。
                    if (cmd_no_resp || (resp_arg[31:16] == 16'd0)) begin
                        init_err_code <= 8'd6;
                        state         <= S_ERR;
                    end else begin
                        state <= S_CMD7;
                    end
                end
            end

            //---------------------------------------------------------------
            // CMD7：SELECT_CARD，之后可以提速到默认速度
            state[I_S_CMD7]: begin
                if (!cmd_fired) begin
                    c_idx     <= 6'd7;
                    c_arg     <= {card_rca, 16'h0000};
                    c_type    <= R_R1;
                    cmd_issue <= 1'b1;
                    cmd_fired <= 1'b1;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    if (cmd_no_resp || cmd_crc_err || cmd_end_bad) begin
                        init_err_code <= 8'd7;
                        state         <= S_ERR;
                    end else begin
                        // CMD7 是 R1b；必须等 DAT0 busy 释放后才能发下一条命令。
                        d_tmo    <= 24'd0;
                        d_tmo_en <= 1'b1;
                        state    <= S_CMD7_BUSY;
                    end
                end
            end

            state[I_S_CMD7_BUSY]: if (ck_rise) begin
                if (dat_in[0]) begin
                    d_tmo_en <= 1'b0;
                    clk_sel  <= 2'd1;        // 400kHz → 25MHz 默认速度
                    state    <= S_ACMD6_55;
                end else if (d_tmo >= DATA_TIMEOUT) begin
                    d_tmo_en      <= 1'b0;
                    init_err_code <= 8'd8;
                    state         <= S_ERR;
                end
            end

            //---------------------------------------------------------------
            // CMD55（APP_CMD）
            state[I_S_ACMD6_55]: begin
                if (!cmd_fired) begin
                    c_idx     <= 6'd55;
                    c_arg     <= {card_rca, 16'h0000};
                    c_type    <= R_R1;
                    cmd_issue <= 1'b1;
                    cmd_fired <= 1'b1;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    state     <= S_ACMD6;
                end
            end

            //---------------------------------------------------------------
            // ACMD6：SET_BUS_WIDTH，arg=2 → ★ 4-bit 总线生效
            state[I_S_ACMD6]: begin
                if (!cmd_fired) begin
                    c_idx     <= 6'd6;
                    c_arg     <= 32'd2;
                    c_type    <= R_R1;
                    cmd_issue <= 1'b1;
                    cmd_fired <= 1'b1;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    if (cmd_no_resp) begin
                        // 切 4-bit 失败：后面的数据相位全都不成立，直接判初始化失败
                        init_err_code <= 8'd5;
                        state         <= S_ERR;
                    end else begin
                        bus_width <= 2'd1;            // 4-bit
                        if (SPEED_TARGET != 0)
                            state <= S_HS_CMD6;
                        else
                            state <= S_CMD16;
                    end
                end
            end

            //---------------------------------------------------------------
            // CMD6：SWITCH_FUNC → 切 High Speed
            //   ★ arg 必须把"访问模式"这一组(group 1)设成 1(High Speed)：
            //     function group 1（Access Mode）位于 bits[3:0]，1=High Speed；
            //     其余组保持 0xF(= 不改变)。所以参数是 0x80FFFFF1。
            //   响应 = R1 + 512bit(64 字节) 数据块
            state[I_S_HS_CMD6]: begin
                if (!cmd_fired) begin
                    c_idx         <= 6'd6;
                    c_arg         <= 32'h80FF_FFF1;
                    c_type        <= R_R1;
                    cmd_issue     <= 1'b1;
                    cmd_fired     <= 1'b1;
                    is_switch_blk <= 1'b1;
                end else if (cmd_done && !cmd_busy) begin
                    cmd_fired     <= 1'b0;
                    if (cmd_no_resp || cmd_crc_err) begin
                        // CMD6 没有有效响应：不要等数据块（会白等 60ms），
                        // 记错误码后按"没切成高速"继续跑完初始化
                        init_err_code <= 8'd4;
                        state         <= S_CMD16;
                    end else begin
                        // 收 64 字节响应块
                        blk_nib_total <= 12'd128;     // 2 * 64
                        nib_cnt       <= 12'd0;
                        byte_in_blk   <= 6'd0;
                        is_switch_blk <= 1'b1;
                        crc16_clr     <= 1'b1;
                        d_crc_bad     <= 1'b0;
                        d_tmo         <= 24'd0;
                        d_tmo_en      <= 1'b1;
                        state         <= S_D_WAIT;
                    end
                end
            end

            //---------------------------------------------------------------
            // CMD16：SET_BLOCKLEN = 512
            state[I_S_CMD16]: begin
                if (!cmd_fired) begin
                    c_idx         <= 6'd16;
                    c_arg         <= 32'd512;
                    c_type        <= R_R1;
                    cmd_issue     <= 1'b1;
                    cmd_fired     <= 1'b1;
                    is_switch_blk <= 1'b0;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    // CMD6 响应块第 16 字节的低 nibble = 当前访问模式（1=High Speed）
                    if ((SPEED_TARGET != 0) && (switch_fn[3:0] == 4'h1)) begin
                        clk_sel    <= 2'd2;      // ★ 50 MHz High Speed
                        high_speed <= 1'b1;
                    end else begin
                        clk_sel    <= 2'd1;      // 停在 25 MHz 默认速度
                        high_speed <= 1'b0;
                    end
                    init_done  <= 1'b1;
                    state      <= S_READY;
                end
            end

            //---------------------------------------------------------------
            // READY：等待读请求
            state[I_S_READY]: begin
                d_tmo_en <= 1'b0;
                if (rd_start) begin
                    rd_sec_lat  <= rd_sector;
                    rd_cnt_lat  <= (rd_count == 16'd0) ? 16'd1 : rd_count;
                    rd_blk_left <= (rd_count == 16'd0) ? 16'd1 : rd_count;
                    rd_busy     <= 1'b1;
                    state       <= S_RD_CMD;
                end
            end

            //---------------------------------------------------------------
            // 发起读命令：count==1 用 CMD17，否则 CMD18
            state[I_S_RD_CMD]: begin
                if (!cmd_fired) begin
                    c_idx     <= (rd_cnt_lat == 16'd1) ? 6'd17 : 6'd18;
                    c_arg     <= rd_sec_lat;
                    c_type    <= R_R1;
                    cmd_issue <= 1'b1;
                    cmd_fired <= 1'b1;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    if (cmd_no_resp || cmd_crc_err) begin
                        // 命令没读成：多块读要么已被卡受理（CRC7 错但响应在），要么状态未知
                        // ⇒ 交给 S_RD_ABORT 补一条 CMD12 再上报失败（单块读无需停止命令）
                        if (rd_cnt_lat > 16'd1) begin
                            d_tmo_en <= 1'b0;
                            state    <= S_RD_ABORT;
                        end else begin
                            rd_busy  <= 1'b0;
                            rd_end   <= 1'b1;
                            state    <= S_READY;
                        end
                    end else begin
                        blk_nib_total <= 12'd1024;    // 2 * 512
                        nib_cnt       <= 12'd0;
                        byte_in_blk   <= 6'd0;
                        is_switch_blk <= 1'b0;
                        crc16_clr     <= 1'b1;
                        d_crc_bad     <= 1'b0;
                        d_tmo         <= 24'd0;
                        d_tmo_en      <= 1'b1;
                        state         <= S_D_WAIT;
                    end
                end
            end

            //---------------------------------------------------------------
            // 等数据起始令牌：宽总线的四根 DAT 起始位均为 0。
            // 检测 DAT0 即可锁定起始周期，该周期不承载数据。
            state[I_S_D_WAIT]: if (ck_rise) begin
                if (!dat_in[0]) begin
                    nib_cnt  <= 12'd0;
                    crc_nib  <= 4'd0;
                    d_tmo_en <= 1'b0;
                    state    <= S_D_DATA;
                end else if (d_tmo >= DATA_TIMEOUT) begin
                    d_tmo_en <= 1'b0;
                    if (is_switch_blk) begin
                        // CMD6 的 64 字节响应块没等到。
                        // ★ 这里绝不能跳 S_READY：那会让 FSM 跳过 CMD16、
                        //   init_done 永远为 0，图像层被门控死 → 整屏黑。
                        //   改为记一个错误码后按"没切成高速"继续跑完初始化。
                        init_err_code <= 8'd4;
                        state         <= S_CMD16;
                    end else if (rd_cnt_lat > 16'd1) begin
                        // 多块读：卡多半正在吐数据，必须先 CMD12 收尾（见 S_RD_ABORT）
                        state <= S_RD_ABORT;
                    end else begin
                        rd_busy  <= 1'b0;
                        rd_end   <= 1'b1;
                        state    <= S_READY;
                    end
                end
            end

            //---------------------------------------------------------------
            // 收数据：每拍一个 nibble，高 nibble 先
            state[I_S_D_DATA]: if (ck_rise) begin
                crc16_en  <= 1'b1;
                crc16_nib <= dat_nib;
                if (nib_cnt[0] == 1'b0) begin
                    hi_nib <= dat_nib;                     // 高 nibble
                end else begin
                    rd_data <= {hi_nib, dat_nib};          // 低 nibble → 凑成 1 字节
                    if (!is_switch_blk) begin
                        rd_data_valid <= 1'b1;
                    end else if (byte_in_blk == 6'd16) begin
                        switch_fn <= {hi_nib, dat_nib};    // 抓 CMD6 响应第 16 字节
                    end
                    if (is_switch_blk)
                        byte_in_blk <= byte_in_blk + 6'd1;
                end
                if (nib_cnt == blk_nib_total - 12'd1) begin
                    crc_nib  <= 2'd0;
                    state    <= S_D_CRC;
                end else begin
                    nib_cnt <= nib_cnt + 12'd1;
                end
            end

            //---------------------------------------------------------------
            // 收 CRC16：宽总线上每根 DAT 线各有 16 bit CRC，
            // 因此尾部占 16 个 SD 时钟，每拍同时比对四根线的一位。
            state[I_S_D_CRC]: if (ck_rise) begin
                if (dat_nib != crc16_expect)
                    d_crc_bad <= 1'b1;
                if (crc_nib == 4'd15) begin
                    state <= S_D_END;
                end else begin
                    crc_nib <= crc_nib + 4'd1;
                end
            end

            //---------------------------------------------------------------
            // 结束位（DAT0=1）
            state[I_S_D_END]: if (ck_rise) begin
                // 结束位应为 1
                if (dat_in != 4'b1111)
                    d_crc_bad <= 1'b1;

                // 数据块收完：判断是 CMD6 的 64 字节块，还是读数据
                if (is_switch_blk) begin
                    if (d_crc_bad || (dat_in != 4'b1111)) begin
                        switch_fn       <= 8'd0;
                        init_err_code   <= 8'd4;
                    end
                    state <= S_CMD16;
                end else if (rd_blk_left > 16'd1) begin
                    rd_blk_left   <= rd_blk_left - 16'd1;
                    crc16_clr     <= 1'b1;
                    d_tmo         <= 24'd0;
                    d_tmo_en      <= 1'b1;
                    state         <= S_D_WAIT;
                end else begin
                    rd_blk_left <= 16'd0;
                    if (rd_cnt_lat == 16'd1) begin
                        rd_busy  <= 1'b0;
                        rd_end   <= 1'b1;
                        state    <= S_READY;
                    end else begin
                        state <= S_RD_STOP;      // 多块读要发 CMD12 停止
                    end
                end
            end

            //---------------------------------------------------------------
            // CMD12：STOP_TRANSMISSION
            state[I_S_RD_STOP]: begin
                if (!cmd_fired) begin
                    c_idx     <= 6'd12;
                    c_arg     <= 32'd0;
                    c_type    <= R_R1;
                    cmd_issue <= 1'b1;
                    cmd_fired <= 1'b1;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    if (cmd_no_resp || cmd_crc_err || cmd_end_bad) begin
                        // CMD12 没被确认：卡可能仍在 data state → 再补一次（S_RD_ABORT
                        // 无论成败都收尾，不会打转），别把卡留在那里
                        d_tmo_en <= 1'b0;
                        state    <= S_RD_ABORT;
                    end else begin
                        // CMD12 也是 R1b，等 DAT0 上的 busy 释放。
                        d_tmo    <= 24'd0;
                        d_tmo_en <= 1'b1;
                        state    <= S_RD_STOP_BUSY;
                    end
                end
            end

            state[I_S_RD_STOP_BUSY]: if (ck_rise) begin
                if (dat_in[0] || (d_tmo >= DATA_TIMEOUT)) begin
                    d_tmo_en <= 1'b0;
                    rd_busy  <= 1'b0;
                    rd_end   <= 1'b1;
                    state    <= S_READY;
                end
            end

            //---------------------------------------------------------------
            // 多块读异常收尾：只补一条 CMD12，不判对错（响应好坏都收 job），
            // 出状态时统一上报 rd_error=1（本来就是因为读失败才进来的）。
            // 为什么要单独一拍：CMD18 之后中途放弃读取而不发 CMD12，卡会继续把
            // 剩余数据块吐完，此后任何命令都得不到响应 ⇒ 整条 SD 链路卡死到断电。
            state[I_S_RD_ABORT]: begin
                if (!cmd_fired) begin
                    c_idx     <= 6'd12;
                    c_arg     <= 32'd0;
                    c_type    <= R_R1;
                    cmd_issue <= 1'b1;
                    cmd_fired <= 1'b1;
                end else if (cmd_done) begin
                    cmd_fired <= 1'b0;
                    d_tmo_en  <= 1'b0;
                    rd_busy   <= 1'b0;
                    rd_end    <= 1'b1;
                    state     <= S_READY;
                end
            end

            //---------------------------------------------------------------
            state[I_S_ERR]: begin
                init_error <= 1'b1;
                init_done  <= 1'b0;
                clk_sel    <= 2'd0;
            end

            default: state <= S_PWR;
            endcase
        end
    end

    // Keep the SD_DAT end-token check on a short, dedicated error path. The
    // main FSM also updates initialization status and data controls in these
    // states; sharing its wide next-state mux added several LUT levels from
    // SD_DAT2 to rd_error. This independent pulse register preserves the
    // existing cycle and conditions while isolating the critical input cone.
    wire rd_error_cmd = state[I_S_RD_CMD] && cmd_fired && cmd_done &&
                        (cmd_no_resp || cmd_crc_err) && rd_cnt_lat<=16'd1;
    wire rd_error_wait = state[I_S_D_WAIT] && ck_rise && dat_in[0] &&
                         d_tmo>=DATA_TIMEOUT && !is_switch_blk && rd_cnt_lat<=16'd1;
    wire rd_error_end = state[I_S_D_END] && ck_rise && !is_switch_blk &&
                        rd_blk_left<=16'd1 && rd_cnt_lat==16'd1;
    wire rd_error_stop = state[I_S_RD_STOP_BUSY] && ck_rise &&
                         (dat_in[0] || d_tmo>=DATA_TIMEOUT);
    wire rd_error_abort = state[I_S_RD_ABORT] && cmd_fired && cmd_done;
    wire rd_end_bad = dat_in!=4'b1111;
    always @(posedge clk or posedge rst) begin
        if (rst) rd_error <= 1'b0;
        else rd_error <= rd_error_cmd || rd_error_wait || rd_error_abort ||
                         (rd_error_end && (d_crc_bad || rd_end_bad)) ||
                         (rd_error_stop && (d_crc_bad || d_tmo>=DATA_TIMEOUT));
    end

endmodule
