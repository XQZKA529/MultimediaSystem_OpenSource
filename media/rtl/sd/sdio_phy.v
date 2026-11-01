//=============================================================================
// module : sdio_phy
// 文件名 : rtl/sd/sdio_phy.v
// 功  能 : 【SDIO 物理层】生成本地 SD_CLK 并给协议层提供"边沿节拍"
//
//          设计要点：
//          1) 整个 SD 控制器只用一个时钟域（clk，即 sd_card_clk = 100 MHz）。
//             SD_CLK 由 clk 整数分频得到，不引入任何新的时钟域/CDC。
//          2) SD 规范规定：主机与卡都在 SD_CLK 的**下降沿**改数据、
//             在**上升沿**采样。本模块把这两个时刻各自标成 1 个 clk 拍的
//             strobe（ck_fall / ck_rise），协议层只需按 strobe 动作即可，
//             不必关心分频比。
//          3) 采样点可在半周期内再往后挪 SAMPLE_DLY 个 clk（默认 0）。
//             这是留给上板调相位的旋钮：50 MHz 时半周期只有 10 ns，
//             板级往返延迟可能吃掉大部分建立余量，必要时靠它错开采样点。
//
//          参数与频率（clk = 100 MHz 时）：
//             SD_CLK_DIV_INIT = 125 → SD_CLK = 100M/(2*125) = 400 kHz（初始化）
//             SD_CLK_DIV_FAST = 2   → 25 MHz（默认速度 Default Speed）
//             SD_CLK_DIV_HS   = 1   → 50 MHz（高速 High Speed）
//          SD_CLK = clk / (2 * DIV)
//=============================================================================
module sdio_phy #(
    parameter integer SD_CLK_DIV_INIT = 125,
    parameter integer SD_CLK_DIV_FAST = 2,
    parameter integer SD_CLK_DIV_HS   = 1,
    parameter integer SAMPLE_DLY      = 0      // 采样点后移的 clk 数，须 < 当前 DIV
)(
    input  wire        clk,
    input  wire        rst,          // 异步复位，高有效
    input  wire [1:0]  clk_sel,      // 0=INIT  1=FAST(默认速度)  2=HS(高速)
    output reg         sdclk,        // 送 SD_CLK 引脚（由寄存器直接输出，无毛刺）
    output reg         ck_rise,      // 1 拍：SD_CLK 上升沿之后那一拍 → 采样卡输出
    output reg         ck_fall,      // 1 拍：SD_CLK 下降沿之后那一拍 → 驱动主机输出
    output wire [15:0] clk_div_dbg   // 当前半周期 clk 数（调试）
);

    localparam [15:0] DIV_INIT = SD_CLK_DIV_INIT[15:0];
    localparam [15:0] DIV_FAST = SD_CLK_DIV_FAST[15:0];
    localparam [15:0] DIV_HS   = SD_CLK_DIV_HS[15:0];

    reg  [15:0] div_r;
    reg  [15:0] ck_cnt;
    reg  [1:0]  clk_sel_d;

    wire        div_chg = (clk_sel_d != clk_sel);

    assign clk_div_dbg = div_r;

    always @(*) begin
        case (clk_sel)
            2'd0:    div_r = DIV_INIT;
            2'd1:    div_r = DIV_FAST;
            default: div_r = DIV_HS;
        endcase
    end

    // 分频计数器：0 ~ 2*div_r-1，全部在 clk 域
    // 换档时强制把计数器清零，避免出现窄脉冲
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            clk_sel_d <= 2'd0;
            ck_cnt    <= 16'd0;
            sdclk     <= 1'b0;
        end else begin
            clk_sel_d <= clk_sel;
            if (div_chg) begin
                ck_cnt <= 16'd0;
                sdclk  <= 1'b0;
            end else begin
                if (ck_cnt >= (div_r << 1) - 16'd1)
                    ck_cnt <= 16'd0;
                else
                    ck_cnt <= ck_cnt + 16'd1;

                sdclk <= (ck_cnt >= div_r) ? 1'b1 : 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 边沿节拍
    //   sdclk 和两个 strobe 都是寄存器，协议层在下一个 clk 沿看到 strobe，
    //   因而必须提前一拍产生：
    //     sdclk 上升发生在旧 ck_cnt==div_r；
    //       → ck_rise 在旧 ck_cnt==div_r-1 时置起。
    //     sdclk 下降发生在计数回卷后的旧 ck_cnt==0；
    //       → ck_fall 在回卷前旧 ck_cnt==2*div_r-1 时置起。
    //   旧实现用 ck_cnt==0 / div_r 产生 strobe，在 div>1 时会变成
    //   "下降沿后 1 个系统时钟采样、上升沿后 1 个系统时钟驱动"。
    //   仿真卡零延迟输出时看不出问题，实卡的 CMD/DAT Tco 却会导致 CMD8
    //   起始位被漏采。SAMPLE_DLY 只能取 0..div_r-1，默认 0 即上升沿采样。
    //--------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ck_rise <= 1'b0;
            ck_fall <= 1'b0;
        end else if (div_chg) begin
            ck_rise <= 1'b0;
            ck_fall <= 1'b0;
        end else begin
            ck_rise <= (ck_cnt == (div_r - 16'd1 + SAMPLE_DLY[15:0])) ? 1'b1 : 1'b0;
            ck_fall <= (ck_cnt == ((div_r << 1) - 16'd1))              ? 1'b1 : 1'b0;
        end
    end

endmodule
