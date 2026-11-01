//=============================================================================
// module : audio_arc_calculate
// 文件名 : rtl/driver/audio_arc_calculate.v
// 功  能 : 【驱动层辅助】音频时钟再生包（ACR, Audio Clock Regeneration）参数生成
//          来源：安路官方 APUG092 HDMI1.4b Transmitter 参考设计同名文件，
//          来源：官方 HDMI 1.4b 参考设计。
//          本文件仅补充注释，逻辑与官方完全一致。
//
// 为什么需要 ACR（HDMI 1.4b 规范第 7 章）：
//   HDMI 里没有独立的音频时钟线。接收端只能从 TMDS 时钟（像素时钟的串行
//   副本）里恢复参考频率，再按 发送端告知的 CTS/N 比例 折算出音频主时钟：
//       f_audio = f_pixel × (N / CTS)
//   发送端周期性地把 CTS（本工程像素时钟数）和 N（音频样本时钟关系常数）
//   打包成 ACR 包发出去，接收端据此用自己的 PLL 再生音频时钟。
//
// 本模块做什么：
//   把输入的 48kHz 音频样本有效脉冲分频（每 AUDIO_DIV 个样本一次），
//   在分频点用像素时钟**实测**两次分频点之间经过的周期数作为 CTS 发出。
//   这样不管像素时钟是 25.000MHz 还是标准的 25.175MHz，CTS 都自动正确，
//   音频源轻微的速率抖动也被平均值吸收。
//
// 数值（640×480@60 / 48kHz）：
//   ACR_N    = 6144（48kHz 家族在 HDMI 规范中的标准 N 值）
//   AUDIO_DIV= 6144 >> 7 = 48 → 每 48 个样本（=1ms）发一个 ACR 包
//   实测 CTS ≈ 25000000 × 1ms = 25000（±1 的量化抖动，符合规范容差）
//=============================================================================
module audio_arc_calculate #(
    parameter ACR_N = 6144    // 32K:4096 / 44.1K:6272 / 48K:6144 / 96K:12288 ...
    )(
    input  wire       I_clk,          // 像素时钟域
    input  wire       I_rst,          // 复位，高电平有效（官方接口约定）

    input  wire       I_audio_valid,  // 音频样本有效脉冲（契约 2，平均速率 = 采样率）

    output reg        O_acr_valid,    // ACR 包参数有效（1 拍，随分频点发出）
    output reg[19:0]  O_acr_cts,      // CTS：两次 ACR 之间实测的像素时钟数
    output reg[19:0]  O_acr_n         // N ：音频时钟关系常数（直通 ACR_N）
);


    // 每 AUDIO_DIV 个样本发一个 ACR 包：N=6144 → 48 个样本 = 1ms
    localparam AUDIO_DIV = ACR_N >> 7;

    reg[7:0]  S_audio_div_cnt;    // 样本分频计数（0 ~ AUDIO_DIV-1）
    wire      S_audio_valid_div;  // 分频点脉冲（每 1ms 一拍）
    reg[19:0] S_acr_cts_cnt;      // 像素时钟计数器（实测 CTS）

    //--------------------------------------------------------------------------
    // ① 样本分频：数够 AUDIO_DIV 个音频样本产生一个 1ms 节拍
    //--------------------------------------------------------------------------
    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)
            S_audio_div_cnt <= 'd0;
        else
            if(I_audio_valid)
                begin
                    if(S_audio_div_cnt >= AUDIO_DIV-1)
                        S_audio_div_cnt <= 'd0;
                    else
                        S_audio_div_cnt <= S_audio_div_cnt + 'd1;
                end
            else
                S_audio_div_cnt <= S_audio_div_cnt;
    end


    assign S_audio_valid_div = I_audio_valid && (S_audio_div_cnt == AUDIO_DIV-1) ? 1'b1 : 1'b0;

    //--------------------------------------------------------------------------
    // ② CTS 实测：1ms 节拍之间数像素时钟。节拍到来时清零，并把"数到的
    //    周期数 + 1"作为 CTS 锁存输出（+1 补偿清零拍本身的周期）。
    //--------------------------------------------------------------------------
    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)
            S_acr_cts_cnt <= 'd0;
        else
            if(S_audio_valid_div)
                S_acr_cts_cnt <= 'd0;
            else
                S_acr_cts_cnt <= S_acr_cts_cnt + 'd1;
    end


    always @(posedge I_clk) begin
        if(S_audio_valid_div)
            begin
                O_acr_valid <= 1'b1;
                O_acr_cts   <= S_acr_cts_cnt + 'd1;
                O_acr_n     <= ACR_N;
            end
        else
            begin
                O_acr_valid <= 1'b0;
                O_acr_cts   <= 'd0;
                O_acr_n     <= 'd0;
            end
    end


endmodule
