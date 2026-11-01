//=============================================================================
// module : hdmi_audio_driver
// 文件名 : rtl/driver/hdmi_audio_driver.v
// 功  能 : 【驱动层 · HDMI 1.4b 后端】带音频的 HDMI 发送封装
//
//          对外契约（与旧后端 hdmi_driver 对齐，仅多出音频/状态两组口）：
//            输入 1 —— 并行视频总线 (rgb, hs, vs, de)，同拍对齐（契约 1）
//            输入 2 —— 音频样本流 (audio_valid, audio_left/right[23:0])
//                      （契约 2：valid 一拍 = 一对采样率精确的立体声样本）
//            输出  —— 4 路 TMDS 差分正端 + DDC(I2C) + 视频锁定指示
//
//          对内结构（每一块都只干一件事，可单点替换）：
//            video_to_axis          视频总线 → 协议核 AXI-Stream 适配
//            audio_arc_calculate    由 audio_valid 实测生成 ACR 的 CTS/N
//            startup_pulse          上电触发一次 EDID 读取
//            hdmi_1_4b_transmitter_core_wrapper   安路官方加密协议核
//                                   （TMDS 编码 + 数据岛音频包 + InfoFrame）
//            hdmi_phy / lane_lvds_10_1            官方可读 10:1 串化物理层
//
//          为什么必须换核心（与旧后端的关系）：
//            旧后端 hdmi_driver 包装的 DVITransmitter 是纯 DVI 编码——消隐期
//            只发控制字符，规范上没有音频通道。HDMI 音频必须走"数据岛"
//            （消隐期发音频采样包 + ACR + InfoFrame），因此本后端整体
//            替换协议核；显示层与音频源两层完全不受影响。
//
//          替换协议核的预留位：
//            将来按 README 学习路线自写 TMDS/数据岛编码器时，只需重写本
//            文件内部例化（对外端口不变），显示层/音频源/顶层零改动。
//
// 时钟：pixel_clk（默认 75MHz 像素域，本模块全部并行逻辑都在这个域）
//       pixel_clk_5x（375MHz，仅供物理层串化使用）
// 复位：rst_n 低有效（本工程统一约定）；内部对官方模块统一转成高有效 I_rst
//=============================================================================
`include "../pkg/video_bmp_params.vh"
module hdmi_audio_driver #(
    // 器件族（决定物理层 ODDR 原语选择，EG4S20 = "EG"）
    parameter DEVICE = "EG",

    // 视频时序参数 —— 必须与显示层 display_layer 的同名参数一致！
    // （协议核要求外部视频时序与它的参数严格相同，O_video_locked 才会锁定）
    parameter H_ACTIVE = `VBP_H_ACTIVE,
    parameter H_FRONT  = `VBP_H_FRONT,
    parameter H_SYNC   = `VBP_H_SYNC,
    parameter H_BACK   = `VBP_H_BACK,
    parameter V_ACTIVE = `VBP_V_ACTIVE,
    parameter V_FRONT  = `VBP_V_FRONT,
    parameter V_SYNC   = `VBP_V_SYNC,
    parameter V_BACK   = `VBP_V_BACK,

    // 视频识别码（CTA-861）：1280x720p@60 = 4
    parameter VIDEO_VIC = 4,

    // 音频采样率（协议核参数）与 ACR 的 N 值（48kHz 家族标准值 6144）
    parameter AUDIO_SAMPLE_RATE = "48K",
    parameter ACR_N             = 6144,

    // EDID I2C 分频：f_scl = f_pixel / (2 × IIC_SCL_DIV) = 75M/1500 = 50kHz
    parameter IIC_SCL_DIV = 750
)(
    //====================== 时钟与复位 ======================
    input  wire        pixel_clk,      // 像素时钟（并行域，如 75MHz）
    input  wire        pixel_clk_5x,   // 5 倍像素时钟（串化域，如 375MHz）
    input  wire        rst_n,          // 低电平有效复位（本工程统一约定）

    //====================== 契约 1：来自显示层的并行视频 ======================
    input  wire        vga_hs,         // 行同步（本后端不使用：协议核用 SOF+
                                       //  连续 valid 自建时序，见 video_to_axis）
    input  wire        vga_vs,         // 场同步（用于生成帧起始 SOF）
    input  wire        vga_de,         // 数据有效
    input  wire [23:0] vga_rgb,        // 像素 {R[7:0],G[7:0],B[7:0]}

    //====================== 契约 2：音频样本流 ======================
    input  wire        audio_valid,    // 1 拍 = 一对立体声样本（平均速率=采样率）
    input  wire [23:0] audio_left,     // 左声道 24bit 有符号 PCM
    input  wire [23:0] audio_right,    // 右声道 24bit 有符号 PCM

    input wire [3:0] brightness_level,
    output wire [3:0] brightness_rgb_level,
    output wire [1:0] brightness_mode,

    //====================== HDMI DDC（EDID 读取通道）======================
    inout  wire        hdmi_ddc_scl,   // DDC I2C 时钟
    inout  wire        hdmi_ddc_sda,   // DDC I2C 数据（开漏，双向）

    //====================== HDMI 物理接口（正端，负端由 IO 约束自动生成）======
    output wire        hdmi_clk_p,     // TMDS 时钟通道 +
    output wire        hdmi_d2_p,      // TMDS 数据通道 2 +（红 R）
    output wire        hdmi_d1_p,      // TMDS 数据通道 1 +（绿 G）
    output wire        hdmi_d0_p,      // TMDS 数据通道 0 +（蓝 B + 同步/数据岛）

    //====================== 状态 ======================
    output wire        video_locked    // 协议核与外部视频时序对齐锁定指示
);

    //--------------------------------------------------------------------------
    // 复位极性转换：本工程 rst_n 低有效，官方模块 I_rst 高有效
    //--------------------------------------------------------------------------
    wire rst_tx = ~rst_n;

    //--------------------------------------------------------------------------
    // 内部互连线
    //--------------------------------------------------------------------------
    wire       axis_s_user;    // 视频帧起始
    wire       axis_s_valid;   // 视频有效
    wire       axis_s_last;    // 视频行末
    wire [23:0] axis_s_data;   // 视频数据
    wire       axis_s_ready;   // 协议核反压（本设计音视频源不可停顿，忽略）

    wire       acr_valid;      // ACR 包参数有效
    wire [19:0] acr_cts;       // 实测 CTS（≈75000 @ 75MHz/48kHz）
    wire [19:0] acr_n;         // N（6144）

    wire       edid_trig;      // 上电 EDID 读取触发
    wire       edid_valid;     // EDID 读出有效（本工程暂不使用，留观察）
    wire [7:0]  edid_data;     // EDID 读出数据（同上）

    wire [9:0]  tmds_ch0_data; // 通道 0 编码数据（蓝 + 同步/数据岛）
    wire [9:0]  tmds_ch1_data; // 通道 1 编码数据（绿）
    wire [9:0]  tmds_ch2_data; // 通道 2 编码数据（红）
    wire [9:0]  tmds_clk_data; // 时钟通道编码数据

    //--------------------------------------------------------------------------
    // ① 视频总线适配：(rgb, vs, de) → AXI-Stream（user/valid/last/data）
    //--------------------------------------------------------------------------
    video_to_axis #(
        .H_ACTIVE ( H_ACTIVE )
    ) u_video_to_axis (
        .clk           ( pixel_clk    ),
        .rst_n         ( rst_n        ),

        .vs            ( vga_vs       ),
        .de            ( vga_de       ),
        .rgb           ( vga_rgb      ),

        .O_video_user  ( axis_s_user  ),
        .O_video_valid ( axis_s_valid ),
        .O_video_last  ( axis_s_last  ),
        .O_video_data  ( axis_s_data  )
    );

    //--------------------------------------------------------------------------
    // ② ACR 生成：由音频采样脉冲实测 CTS（音频源无需感知 HDMI）
    //--------------------------------------------------------------------------
    audio_arc_calculate #(
        .ACR_N ( ACR_N )
    ) u_audio_arc_calculate (
        .I_clk         ( pixel_clk    ),
        .I_rst         ( rst_tx       ),

        .I_audio_valid ( audio_valid  ),

        .O_acr_valid   ( acr_valid    ),
        .O_acr_cts     ( acr_cts      ),
        .O_acr_n       ( acr_n        )
    );

    //--------------------------------------------------------------------------
    // ③ 上电 EDID 读取触发（读失败不影响出图出声，见 startup_pulse 注释）
    //--------------------------------------------------------------------------
    // Fixed 720p timings do not consume EDID. The encrypted EDID master has
    // no bus-release contract: isolate it and let DDC/CI exclusively own the pads.
    // Never connect the two masters to the same external pads.
    wire core_ddc_scl;
    tri1 core_ddc_sda;
    wire ddc_scl_low,ddc_sda_low;
    assign hdmi_ddc_scl=ddc_scl_low ? 1'b0:1'bz;
    assign hdmi_ddc_sda=ddc_sda_low ? 1'b0:1'bz;
    assign edid_trig=1'b0;
    ddcci_brightness u_brightness (
        .clk(pixel_clk),.rst(rst_tx),.level(brightness_level),
        .mode(brightness_mode),.rgb_level(brightness_rgb_level),
        .scl_in(hdmi_ddc_scl),.sda_in(hdmi_ddc_sda),.scl_low(ddc_scl_low),.sda_low(ddc_sda_low)
    );

    //--------------------------------------------------------------------------
    // ④ 协议核（安路官方加密 IP，端口声明可读，见 .enc.v 文件头）
    //    内部完成：TMDS 编码、视频相位对齐、数据岛音频采样包 + ACR +
    //    AVI InfoFrame、DDC/EDID 主机。
    //--------------------------------------------------------------------------
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE            ( DEVICE      ),

        // 视频时序：由显示层同款参数推导，保证两层永远一致
        .HTOTAL            ( H_ACTIVE + H_FRONT + H_SYNC + H_BACK ),
        .HSA               ( H_SYNC      ),
        .HFP               ( H_FRONT     ),
        .HBP               ( H_BACK      ),
        .HACTIVE           ( H_ACTIVE    ),
        .VTOTAL            ( V_ACTIVE + V_FRONT + V_SYNC + V_BACK ),
        .VSA               ( V_SYNC      ),
        .VFP               ( V_FRONT     ),
        .VBP               ( V_BACK      ),
        .VACTIVE           ( V_ACTIVE    ),

        .VIDEO_VIC         ( VIDEO_VIC         ),
        .VIDEO_TPG         ( "Disable"         ),  // 用外部视频（我们的显示层）
        .VIDEO_FORMAT      ( "RGB"             ),
        .AUDIO_SAMPLE_RATE ( AUDIO_SAMPLE_RATE ),
        .IIC_SCL_DIV       ( IIC_SCL_DIV       )
    ) u_hdmi_tx_core (
        .I_pixel_clk        ( pixel_clk      ),
        .I_rst              ( rst_tx         ),

        // EDID 接口
        .I_edid_read_trig   ( edid_trig      ),
        .O_edid_read_valid  ( edid_valid     ),
        .O_edid_read_data   ( edid_data      ),

        // 视频接口（AXI-Stream 风格）
        .I_axis_s_user      ( axis_s_user    ),
        .I_axis_s_valid     ( axis_s_valid   ),
        .I_axis_s_last      ( axis_s_last    ),
        .I_axis_s_data      ( axis_s_data    ),
        .O_axis_s_ready     ( axis_s_ready   ),   // 音视频源连续不断流，忽略

        // 音频接口（契约 2 直通）
        .I_audio_valid      ( audio_valid    ),
        .I_audio_left_data  ( audio_left     ),
        .I_audio_right_data ( audio_right    ),

        // ACR 接口
        .I_acr_valid        ( acr_valid      ),
        .I_acr_cts          ( acr_cts        ),
        .I_acr_n            ( acr_n          ),

        // 状态 / DDC
        .O_video_locked     ( video_locked   ),
        .O_ddc_scl          ( core_ddc_scl   ),
        .IO_ddc_sda         ( core_ddc_sda   ),

        // TMDS 编码数据输出（10bit/通道/像素周期）
        .O_ch0_tmds_data    ( tmds_ch0_data  ),
        .O_ch1_tmds_data    ( tmds_ch1_data  ),
        .O_ch2_tmds_data    ( tmds_ch2_data  ),
        .O_clk_tmds_data    ( tmds_clk_data  )
    );

    //--------------------------------------------------------------------------
    // ⑤ 物理层：4 路 10bit 字符 → 10:1 串化 → 差分正端
    //--------------------------------------------------------------------------
    hdmi_phy #(
        .DEVICE ( DEVICE )
    ) u_hdmi_phy (
        .I_pixel_clk        ( pixel_clk     ),
        .I_serial_clk       ( pixel_clk_5x  ),
        .I_rst              ( rst_tx        ),

        .I_tmds_channel_0   ( tmds_ch0_data ),
        .I_tmds_channel_1   ( tmds_ch1_data ),
        .I_tmds_channel_2   ( tmds_ch2_data ),
        .I_tmds_channel_clk ( tmds_clk_data ),

        .O_tmds_ch0_p       ( hdmi_d0_p     ),
        .O_tmds_ch1_p       ( hdmi_d1_p     ),
        .O_tmds_ch2_p       ( hdmi_d2_p     ),
        .O_tmds_clk_p       ( hdmi_clk_p    )
    );

    //--------------------------------------------------------------------------
    // vga_hs 本后端不使用（协议核不消费行同步），用与工程一致的方式吸收，
    // 避免综合告警；端口保留是为了维持契约 1 的完整性。
    // synthesis translate_off
    wire _unused_hs = &{1'b0, vga_hs, 1'b0};
    // synthesis translate_on

endmodule
