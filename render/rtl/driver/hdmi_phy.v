//=============================================================================
// module : hdmi_phy
// 文件名 : rtl/driver/hdmi_phy.v
// 功  能 : 【物理层】TMDS 四通道并串转换封装
//          来源：安路官方 APUG092 HDMI1.4b Transmitter 参考设计的
//          hdmi_phy_warpper.v（官方文件名拼写如此），
//          来源：官方 HDMI 1.4b 参考设计的物理层封装。
//          本文件改名为 hdmi_phy 并补充注释，逻辑与官方一致。
//
// 职责：把协议核输出的 4 路 10bit TMDS 字符（3 数据通道 + 1 时钟通道）
//       各经一个 lane_lvds_10_1 串化成 250 Mbps 串行流，送到差分引脚正端。
//
// 位序说明（学习要点）：
//   协议核的 O_chN_tmds_data[0] 是 TMDS 字符中**最先上线**的 bit。
//   lane_lvds_10_1 的移位寄存器是从最高位 [9:8] 开始送出的，
//   因此这里先把 10bit 总线**位序反转**：I[0] → S[9]。
//   这样装载后第一个送出的对就是 {I[1],I[0]}，实现 bit0 先行。
//
// 通道映射（DVI/HDMI 标准）：
//   channel 0（O_tmds_ch0_p）→ HDMI_D0_P：蓝 B + 消隐期控制/数据岛
//   channel 1（O_tmds_ch1_p）→ HDMI_D1_P：绿 G
//   channel 2（O_tmds_ch2_p）→ HDMI_D2_P：红 R
//   clock   （O_tmds_clk_p） → HDMI_CLK_P：TMDS 时钟（字符 10'b1111100000 之类
//                             的固定周期序列串化后的方波，供接收端恢复时钟）
//=============================================================================
module hdmi_phy #(
    parameter DEVICE = "EG"    // 器件族，直通给 lane_lvds_10_1 选择 ODDR 原语
    )(
    input  wire      I_pixel_clk,       // 像素时钟（并行域）
    input  wire      I_serial_clk,      // 串化时钟 = 5 × 像素时钟
    input  wire      I_rst,             // 复位，高电平有效（官方接口约定）

    input  wire[9:0] I_tmds_channel_0,  // 通道 0 编码数据（蓝 + 同步/数据岛）
    input  wire[9:0] I_tmds_channel_1,  // 通道 1 编码数据（绿）
    input  wire[9:0] I_tmds_channel_2,  // 通道 2 编码数据（红）
    input  wire[9:0] I_tmds_channel_clk,// 时钟通道编码数据

    output wire      O_tmds_ch0_p,      // 通道 0 差分正端
    output wire      O_tmds_ch1_p,      // 通道 1 差分正端
    output wire      O_tmds_ch2_p,      // 通道 2 差分正端
    output wire      O_tmds_clk_p       // 时钟通道差分正端
);

    //--------------------------------------------------------------------------
    // 位序反转：协议核 bit0 = 最先上线；移位寄存器高位先出 → I[0] 摆到 S[9]
    //--------------------------------------------------------------------------
    wire[9:0] S_tmds_data_ch0  = {I_tmds_channel_0[0],  I_tmds_channel_0[1],
                                  I_tmds_channel_0[2],  I_tmds_channel_0[3],
                                  I_tmds_channel_0[4],  I_tmds_channel_0[5],
                                  I_tmds_channel_0[6],  I_tmds_channel_0[7],
                                  I_tmds_channel_0[8],  I_tmds_channel_0[9]};

    wire[9:0] S_tmds_data_ch1  = {I_tmds_channel_1[0],  I_tmds_channel_1[1],
                                  I_tmds_channel_1[2],  I_tmds_channel_1[3],
                                  I_tmds_channel_1[4],  I_tmds_channel_1[5],
                                  I_tmds_channel_1[6],  I_tmds_channel_1[7],
                                  I_tmds_channel_1[8],  I_tmds_channel_1[9]};

    wire[9:0] S_tmds_data_ch2  = {I_tmds_channel_2[0],  I_tmds_channel_2[1],
                                  I_tmds_channel_2[2],  I_tmds_channel_2[3],
                                  I_tmds_channel_2[4],  I_tmds_channel_2[5],
                                  I_tmds_channel_2[6],  I_tmds_channel_2[7],
                                  I_tmds_channel_2[8],  I_tmds_channel_2[9]};

    wire[9:0] S_tmds_data_clk  = {I_tmds_channel_clk[0], I_tmds_channel_clk[1],
                                  I_tmds_channel_clk[2], I_tmds_channel_clk[3],
                                  I_tmds_channel_clk[4], I_tmds_channel_clk[5],
                                  I_tmds_channel_clk[6], I_tmds_channel_clk[7],
                                  I_tmds_channel_clk[8], I_tmds_channel_clk[9]};

    //--------------------------------------------------------------------------
    // 四个独立串化 lane（数据 ×3 + 时钟 ×1）
    //--------------------------------------------------------------------------
    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )
    ) u_lane_lvds_ch0 (
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_rst        ( I_rst           ),

        .I_data_in    ( S_tmds_data_ch0 ),
        .O_serial_out ( O_tmds_ch0_p    )
    );

    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )
    ) u_lane_lvds_ch1 (
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_rst        ( I_rst           ),

        .I_data_in    ( S_tmds_data_ch1 ),
        .O_serial_out ( O_tmds_ch1_p    )
    );

    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )
    ) u_lane_lvds_ch2 (
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_rst        ( I_rst           ),

        .I_data_in    ( S_tmds_data_ch2 ),
        .O_serial_out ( O_tmds_ch2_p    )
    );

    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )
    ) u_lane_lvds_clk (
        .I_pixel_clk  ( I_pixel_clk      ),
        .I_serial_clk ( I_serial_clk     ),
        .I_rst        ( I_rst            ),

        .I_data_in    ( S_tmds_data_clk  ),
        .O_serial_out ( O_tmds_clk_p     )
    );

endmodule
