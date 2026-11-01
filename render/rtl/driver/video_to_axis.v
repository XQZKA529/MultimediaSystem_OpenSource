//=============================================================================
// module : video_to_axis
// 文件名 : rtl/driver/video_to_axis.v
// 功  能 : 【驱动层内部适配】把显示层的并行视频总线 (rgb, hs, vs, de)
//          转换成 HDMI 1.4b 协议核要求的 AXI-Stream 风格视频接口
//          (user = 帧起始 SOF, valid = 像素有效, last = 行末, data = 像素)。
//          来源：赛题包 lab_ex5_i2s 参考设计的 video_rgb_to_axis_640x480.v，
//          来源：官方 HDMI 1.4b 参考设计的视频流适配模块。
//          本文件改名为 video_to_axis、行宽参数化（H_ACTIVE）、复位改为
//          本工程统一的 rst_n（低有效），核心逻辑与官方一致。
//
// 接口约定（来自 APUG092 用户手册）：
//   O_video_user  ：帧起始（SOF）。任一次 vsync 跳变后的第一个有效像素置位 1 拍
//   O_video_valid ：像素有效（= de 寄存一拍）
//   O_video_last  ：行末标志
//   O_video_data  ：24bit RGB 像素
//   注意：协议核要求一行数据必须连续输入（valid 之间不允许断流），
//   显示时序的 de 天然满足（一行 H_ACTIVE 个连续 de 拍）。
//   行末比较已修正官方参考代码的一拍滞后，last 与最后一个有效像素同拍。
//=============================================================================
`include "../pkg/video_bmp_params.vh"
module video_to_axis #(
    parameter H_ACTIVE = `VBP_H_ACTIVE    // 行有效像素数，必须与显示层/协议核一致
)(
    input  wire        clk,          // 像素时钟
    input  wire        rst_n,        // 低电平有效复位（本工程统一约定）

    // ---- 并行视频总线输入（契约 1，同拍对齐）----
    input  wire        vs,           // 场同步
    input  wire        de,           // 数据有效
    input  wire [23:0] rgb,          // 像素 {R,G,B}

    // ---- AXI-Stream 风格视频输出（协议核输入约定）----
    output reg         O_video_user,   // 帧起始 SOF（1 拍）
    output reg         O_video_valid,  // 像素有效
    output reg         O_video_last,   // 行末
    output reg  [23:0] O_video_data    // 像素数据
);

    reg        S_vs_1d;       // vsync 打一拍（沿检测用）
    reg        S_de_1d;       // de 打一拍（行首检测用）
    reg        S_frame_arm;   // 帧起始武装标志：vsync 跳变后待发射
    reg [10:0] S_x_cnt;       // 行内像素计数

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            S_vs_1d       <= 1'b0;
            S_de_1d       <= 1'b0;
            S_frame_arm   <= 1'b1;    // 复位后武装，保证第一帧有 SOF
            S_x_cnt       <= 11'd0;
            O_video_user  <= 1'b0;
            O_video_valid <= 1'b0;
            O_video_last  <= 1'b0;
            O_video_data  <= 24'd0;
        end
        else begin
            S_vs_1d <= vs;
            S_de_1d <= de;

            // 默认直通：valid 跟随 de，数据跟随 rgb（同拍寄存，与契约 1 对齐）
            O_video_user  <= 1'b0;
            O_video_valid <= de;
            O_video_last  <= 1'b0;
            O_video_data  <= rgb;

            // 任意一次 VS 跳变后，把"下一次 active video 的首像素"当成 SOF
            if (S_vs_1d != vs)
                S_frame_arm <= 1'b1;

            if (de) begin
                if (!S_de_1d) begin
                    // 一行首像素
                    S_x_cnt <= 11'd0;
                    if (S_frame_arm) begin
                        O_video_user <= 1'b1;    // 本拍（即首个有效像素）发 SOF
                        S_frame_arm  <= 1'b0;
                    end
                end
                else begin
                    S_x_cnt <= S_x_cnt + 11'd1;
                end

                // S_x_cnt 在行首拍被清零，因此后续拍的旧值比实际 x 小 1。
                if ((!S_de_1d && (H_ACTIVE == 1)) ||
                    (S_de_1d && (S_x_cnt == H_ACTIVE - 2)))
                    O_video_last <= 1'b1;
            end
            else begin
                S_x_cnt <= 11'd0;
            end
        end
    end

endmodule
