//=============================================================================
// module : sd_card_sdio
// 文件名 : rtl/sd/sd_card_sdio.v
// 功  能 : 【SD 子系统顶层】整个工程中**唯一**持有 SD 物理引脚的地方。
//
//  ★ 这是解耦的落点 ★
//    改造前：SD 控制器被塞在图像层里（sd_card_bmp 内部例化 sd_card_top 并直接
//    持有 SD_CLK/CMD/DAT 引脚），于是"读图"和"SD 硬件"绑死在一起，视频/音乐
//    想复用 SD 卡就没有入口。
//    改造后：SD 卡在这里被抽象成一份**可被多路消费的"授权式突发读"资源**：
//      请求方        ch*_req(1拍) + ch*_sector + ch*_count
//      资源方回      ch*_grant（持有一段时间）→ ch*_data/valid → ch*_end
//    通道 0 = 图像（当前唯一使用者）
//    通道 1 = 预留（视频播放 / 音乐读取），接口已就位，接上即可用，
//             不需要再动 sdio_core、phy、命令层，也不需要再碰 SD 引脚。
//
//  仲裁策略：轮询（round-robin），**不抢占** —— 一旦授权，该通道的整段突发
//            跑完（ch*_end）才换人。这样每条通道拿到的都是连续字节流，
//            适合"扫扇区"（图像）和"长连读"（视频/音乐）两种形态。
//
//  引脚方向（对应 constr/hdmi_colorbar.adc 的说明）：
//    SD_CLK  输出
//    SD_CMD  双向（inout，由 cmd_oe 控制；本设计只读卡，oe 仅在发命令时为 1）
//    SD_DAT0..3 输入（本设计不做写卡，DAT 恒为输入）
//=============================================================================
module sd_card_sdio #(
    parameter integer CLK_FREQ_HZ     = 100_000_000,
    parameter integer SD_CLK_DIV_INIT = 125,          // 400 kHz
    parameter integer SD_CLK_DIV_FAST = 2,            // 25 MHz 默认速度
    parameter integer SD_CLK_DIV_HS   = 1,            // 50 MHz 高速
    parameter integer SAMPLE_DLY      = 0,
    parameter integer SPEED_TARGET    = 1             // 1=尝试切到 50MHz High Speed
)(
    input  wire        clk,             // sd_card_clk = 100 MHz
    input  wire        rst,             // 高有效

    //====================== SD 物理引脚 ======================
    output wire        SD_CLK,
    inout  wire        SD_CMD,
    input  wire        SD_DAT0,
    input  wire        SD_DAT1,
    input  wire        SD_DAT2,
    input  wire        SD_DAT3,

    //====================== 状态（供上层判断与调试）======================
    output wire        sd_init_done,
    output wire        sd_init_error,
    output wire [7:0]  sd_init_err_code,   // 1=CMD8无响应 ... 8=CMD7 busy 9=CMD8坏响应
    output wire        sd_high_speed,      // 1 = 已切到 50MHz High Speed
    output wire [1:0]  sd_bus_width,       // 1 = 4-bit
    output wire        sd_is_sdhc,
    output wire [15:0] sd_card_rca,

    //====================== 通道 0：图像 ======================
    input  wire        ch0_req,
    input  wire [31:0] ch0_sector,
    input  wire [15:0] ch0_count,
    output wire        ch0_grant,
    output wire [7:0]  ch0_data,
    output wire        ch0_data_valid,
    output wire        ch0_end,
    output wire        ch0_error,

    //====================== 通道 1：预留（视频 / 音乐）======================
    input  wire        ch1_req,
    input  wire [31:0] ch1_sector,
    input  wire [15:0] ch1_count,
    output wire        ch1_grant,
    output wire [7:0]  ch1_data,
    output wire        ch1_data_valid,
    output wire        ch1_end,
    output wire        ch1_error,

    //====================== 调试 ======================
    output wire [4:0]  dbg_state,
    output wire [5:0]  dbg_resp_cmd,
    output wire [31:0] dbg_resp_arg,
    output wire [7:0]  dbg_switch_fn,
    output wire [15:0] dbg_clk_div
);

    //--------------------------------------------------------------------------
    // SD 引脚三态与输入
    //--------------------------------------------------------------------------
    wire cmd_oe, cmd_out;
    wire cmd_in;
    wire [3:0] dat_in;

    assign SD_CMD  = cmd_oe ? cmd_out : 1'bz;
    assign cmd_in  = SD_CMD;
    assign dat_in  = {SD_DAT3, SD_DAT2, SD_DAT1, SD_DAT0};   // DAT3 是 nibble 的 MSB

    // 本设计不做写卡：DAT 恒为输入
    wire _unused_dat_oe = 1'b0;

    //--------------------------------------------------------------------------
    // SDIO 引擎
    //--------------------------------------------------------------------------
    wire        rd_start;
    wire [31:0] rd_sector;
    wire [15:0] rd_count;
    wire        rd_busy;
    wire [7:0]  rd_data;
    wire        rd_data_valid;
    wire        rd_end;
    wire        rd_error;

    sdio_core #(
        .CLK_FREQ_HZ    (CLK_FREQ_HZ),
        .SD_CLK_DIV_INIT(SD_CLK_DIV_INIT),
        .SD_CLK_DIV_FAST(SD_CLK_DIV_FAST),
        .SD_CLK_DIV_HS  (SD_CLK_DIV_HS),
        .SAMPLE_DLY     (SAMPLE_DLY),
        .SPEED_TARGET   (SPEED_TARGET)
    ) u_core (
        .clk(clk), .rst(rst),
        .SD_CLK(SD_CLK), .cmd_oe(cmd_oe), .cmd_out(cmd_out),
        .cmd_in(cmd_in), .dat_in(dat_in),
        .init_done(sd_init_done), .init_error(sd_init_error),
        .is_sdhc(sd_is_sdhc), .high_speed(sd_high_speed),
        .bus_width(sd_bus_width), .card_rca(sd_card_rca),
        .init_err_code(sd_init_err_code),
        .rd_start(rd_start), .rd_sector(rd_sector), .rd_count(rd_count),
        .rd_busy(rd_busy), .rd_data(rd_data), .rd_data_valid(rd_data_valid),
        .rd_end(rd_end), .rd_error(rd_error),
        .dbg_state(dbg_state), .dbg_phy_state(),
        .dbg_resp_cmd(dbg_resp_cmd), .dbg_resp_arg(dbg_resp_arg),
        .dbg_crc_err_cnt(), .dbg_no_resp_cnt(),
        .dbg_switch_fn(dbg_switch_fn), .dbg_clk_div(dbg_clk_div)
    );

    //--------------------------------------------------------------------------
    // 通道仲裁：轮询 + 不抢占
    //   grant0/grant1 从发起一直保持到 rd_end
    //--------------------------------------------------------------------------
    reg  grant0, grant1;
    reg  last;                       // 上次授权给谁：0=ch0 1=ch1
    reg  [31:0] rd_sector_r;
    reg  [15:0] rd_count_r;
    reg         rd_start_r;

    assign ch0_grant = grant0;
    assign ch1_grant = grant1;

    wire any_req = ch0_req | ch1_req;
    // 两条同时请求时，选"不是上次刚给过"的那条；只有一条请求时就给它
    wire pick1   = ch1_req & (ch0_req ? last : 1'b1);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            grant0     <= 1'b0;
            grant1     <= 1'b0;
            last       <= 1'b0;
            rd_start_r <= 1'b0;
            rd_sector_r<= 32'd0;
            rd_count_r <= 16'd0;
        end else begin
            rd_start_r <= 1'b0;

            // 空闲且有请求 → 授权并发起一次突发读
            if (!grant0 && !grant1 && any_req) begin
                if (pick1) begin
                    rd_sector_r <= ch1_sector;
                    rd_count_r  <= (ch1_count == 16'd0) ? 16'd1 : ch1_count;
                    grant1      <= 1'b1;
                    last        <= 1'b1;
                end else begin
                    rd_sector_r <= ch0_sector;
                    rd_count_r  <= (ch0_count == 16'd0) ? 16'd1 : ch0_count;
                    grant0      <= 1'b1;
                    last        <= 1'b0;
                end
                rd_start_r <= 1'b1;
            end

            // 突发结束 → 释放通道
            if (rd_end) begin
                grant0 <= 1'b0;
                grant1 <= 1'b0;
            end
        end
    end

    assign rd_start  = rd_start_r;
    assign rd_sector = rd_sector_r;
    assign rd_count  = rd_count_r;

    //--------------------------------------------------------------------------
    // 数据解复用：字节流只送给当前被授权的通道
    //--------------------------------------------------------------------------
    assign ch0_data       = rd_data;
    assign ch0_data_valid = grant0 & rd_data_valid;
    assign ch0_end        = grant0 & rd_end;
    assign ch0_error      = grant0 & rd_error;

    assign ch1_data       = rd_data;
    assign ch1_data_valid = grant1 & rd_data_valid;
    assign ch1_end        = grant1 & rd_end;
    assign ch1_error      = grant1 & rd_error;

endmodule
