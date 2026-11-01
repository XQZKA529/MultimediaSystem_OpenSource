//=============================================================================
// module : startup_pulse
// 文件名 : rtl/driver/startup_pulse.v
// 功  能 : 【驱动层辅助】上电后延迟产生一个单时钟周期脉冲
//          来源：赛题包 lab_ex5_i2s 参考设计同名文件，
//          来源：官方 HDMI 1.4b 参考设计。
//          本文件仅补充注释，逻辑一致（CNT_MAX 默认值一致）。
//
// 用途：本工程中接 HDMI 协议核的 I_edid_read_trig —— 上电稳定后自动触发
//       一次 EDID 读取（DDC/I2C 读显示器能力描述）。
//
// 注意：EDID 读取是"可选服务"（官方设计里用按键触发）：
//   - 读失败（线插在另一个 HDMI 口 / 显示器不应答）只影响 EDID 内容获取，
//     不影响视频/音频的正常发送；
//   - CNT_MAX = 100000 @ 25MHz ≈ 4ms，等 PLL 与显示器 HPD 稳定后再读。
//=============================================================================
module startup_pulse #(
    parameter [19:0] CNT_MAX = 20'd100000    // 脉冲前的等待周期数（@25MHz≈4ms）
)(
    input  wire I_clk,
    input  wire I_rst,          // 高电平有效（官方接口约定）
    output reg  O_pulse         // 单周期脉冲，只产生一次
);

reg [19:0] S_cnt;
reg        S_done;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_cnt   <= 20'd0;
        S_done  <= 1'b0;
        O_pulse <= 1'b0;
    end
    else begin
        O_pulse <= 1'b0;    // 默认无脉冲

        if (!S_done) begin
            if (S_cnt == CNT_MAX - 1'b1) begin
                S_cnt   <= S_cnt;
                S_done  <= 1'b1;    // 只触发一次，之后永久静默
                O_pulse <= 1'b1;
            end
            else begin
                S_cnt <= S_cnt + 1'b1;
            end
        end
    end
end

endmodule
