//=============================================================================
// module : audio_wav_pcm
// 文件名 : rtl/audio/audio_wav_pcm.v
// 功  能 : 【音频源层】WAV PCM 播放器 —— 与 audio_tone_pcm 严格相同的契约 2
//          （O_audio_valid / O_audio_left_data / O_audio_right_data），
//          顶层 AUDIO_SOURCE="WAV" 时直接替换 tone 实例，驱动层零改动。
//
// 设计要点：
//   1) 48kHz 节拍复用 audio_tone_pcm 的 Bresenham 分数分频：
//          acc += SAMPLE_RATE_HZ；acc >= CLK_FREQ_HZ 时出一对样本并扣周期。
//      平均速率严格 48000 Hz，由 HDMI ACR 实测 CTS 吸收逐拍抖动。
//   2) 输入侧为极简样本流（由 audio_ring_bram pop 或胶水驱动）：
//          in_valid / in_left[23:0] / in_right[23:0]  —— 组合/同拍有效
//          in_ready                                   —— 本拍消费
//      内部 hold 一级预取：空闲时提前吃一对，节拍到再吐出。
//   3) 欠载 / 未开播 / 停止时的策略（已选定并固定）：
//          **仍然每 48kHz 发 O_audio_valid=1，样本填 0（静音）**。
//      原因：ACR / 协议核需要连续 48k 有效节拍；欠载只应短暂静音，
//      不得停 valid 造成接收端采样率状态机卡死。规格 2.5「环空且文件未完
//      → 短暂静音不卡死」与此一致。
//   4) 16bit 源经 unpack 扩到 24bit 有符号后进入本模块；本模块不再做位深转换。
//
// 可选 start/stop：
//   I_run=0 时不消费输入、输出静音但仍出 48k valid（见上）。
//   I_valid_en=1 时才拉高 O_audio_valid；默认 0 与 tone 行为一致（tone 总为 1）。
//   本轮 TB 将 I_valid_en=1，验证 48k 连续节拍。
//=============================================================================
module audio_wav_pcm #(
    parameter CLK_FREQ_HZ    = 75_000_000,  // 像素时钟（video_clk）
    parameter SAMPLE_RATE_HZ = 48_000
)(
    input  wire        I_clk,
    input  wire        I_rst_n,

    // ---- 契约 2：与 audio_tone_pcm 完全一致 ----
    output reg         O_audio_valid,
    output reg  [23:0] O_audio_left_data,
    output reg  [23:0] O_audio_right_data,

    // ---- 控制 ----
    input  wire        I_run,          // 1=播放；0=静音但仍出 48k valid
    input  wire        stream_clear,   // flush prefetched sample without stopping the 48k clock
    output reg         sample_played,  // actual HDMI sample, excludes silence and prefetch
    input  wire        I_valid_en,     // 1=拉高 O_audio_valid；0=恒 0（不用 ACR 时）

    // ---- 样本流输入（FIFO show-ahead / 胶水）----
    input  wire        in_valid,       // 当前拍有一对样本可取
    input  wire [23:0] in_left,
    input  wire [23:0] in_right,
    output wire        in_ready        // 当前拍消费一对（接 FIFO rd_en）
);

    //--------------------------------------------------------------------------
    // Bresenham 48kHz 分数分频（与 audio_tone_pcm 同式）
    //--------------------------------------------------------------------------
    reg  [31:0] S_sample_acc;
    wire [31:0] W_acc_next    = S_sample_acc + SAMPLE_RATE_HZ;
    wire        W_sample_tick = (W_acc_next >= CLK_FREQ_HZ);

    //--------------------------------------------------------------------------
    // 预取 hold：空且有货就吃一对；节拍到则吐出（或静音）
    //--------------------------------------------------------------------------
    reg [23:0] hold_left, hold_right;
    reg        hold_valid;

    // ready/valid：hold 空且开播即可收一对（不依赖 in_valid，避免组合环）
    assign in_ready = I_run && !hold_valid;
    wire   in_take  = in_ready && in_valid;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_sample_acc       <= 32'd0;
            O_audio_valid      <= 1'b0;
            O_audio_left_data  <= 24'd0;
            O_audio_right_data <= 24'd0;
            hold_left          <= 24'd0;
            hold_right         <= 24'd0;
            hold_valid         <= 1'b0;
            sample_played      <= 1'b0;
        end else begin
            O_audio_valid <= 1'b0;
            sample_played <= 1'b0;

            // ---- 预取 / 取样 ----
            if (W_sample_tick) begin
                S_sample_acc <= W_acc_next - CLK_FREQ_HZ;
                if (I_valid_en)
                    O_audio_valid <= 1'b1;

                if (I_run && hold_valid && !stream_clear) begin
                    sample_played <= 1'b1;
                    O_audio_left_data  <= hold_left;
                    O_audio_right_data <= hold_right;
                    // hold 被吐出；若同拍还能收新样本则直接进 hold
                    if (in_take) begin
                        hold_left  <= in_left;
                        hold_right <= in_right;
                        hold_valid <= 1'b1;
                    end else begin
                        hold_valid <= 1'b0;
                    end
                end else if (I_run && in_take && !stream_clear) begin
                    sample_played <= 1'b1;
                    // hold 空、本拍上游直接有货：直通
                    O_audio_left_data  <= in_left;
                    O_audio_right_data <= in_right;
                    hold_valid         <= 1'b0;
                end else begin
                    // 欠载 / 停止：静音，但 valid 仍出（见文件头策略）
                    O_audio_left_data  <= 24'd0;
                    O_audio_right_data <= 24'd0;
                    if (in_take) begin
                        hold_left  <= in_left;
                        hold_right <= in_right;
                        hold_valid <= 1'b1;
                    end
                end
            end else begin
                S_sample_acc <= W_acc_next;
                if (in_take) begin
                    hold_left  <= in_left;
                    hold_right <= in_right;
                    hold_valid <= 1'b1;
                end
            end
            if(stream_clear) hold_valid<=1'b0;
        end
    end

endmodule
