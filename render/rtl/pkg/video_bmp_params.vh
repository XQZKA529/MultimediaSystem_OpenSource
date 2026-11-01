//=============================================================================
// video_bmp_params.vh — 720p BMP 播放几何 / 地址的唯一参数头
//
// 顶层与 glue 模块通过 `include` 取值；各子模块的 parameter 默认值仅供
// 单模块 TB 覆盖，生产路径的数字只允许出现在本文件。
//=============================================================================
`ifndef VIDEO_BMP_PARAMS_VH
`define VIDEO_BMP_PARAMS_VH

// ---- 720p60 时序（与 hdmi_audio_driver / video_timing_data 一致）----
`define VBP_H_ACTIVE       1280
`define VBP_H_FRONT        110
`define VBP_H_SYNC         40
`define VBP_H_BACK         220
`define VBP_V_ACTIVE       720
`define VBP_V_FRONT        5
`define VBP_V_SYNC         5
`define VBP_V_BACK         20

// ---- RGB888 4:3 打包 → SDRAM 字布局 ----
`define VBP_LINE_WORDS     960          // (H_ACTIVE * 3) / 4
`define VBP_FRAME_PIXELS   921600       // H_ACTIVE * V_ACTIVE
`define VBP_FRAME_WORDS    691200       // LINE_WORDS * V_ACTIVE = 0xA8C00
`define VBP_BUF0_ADDR      21'h000000
`define VBP_BUF1_ADDR      21'h0A8C00

// ---- BMP 像素几何与写侧垂直翻转 ----
`define VBP_BMP_W          16'd1280
`define VBP_BMP_H          16'd720
`define VBP_WRITE_V_FLIP   1

// ---- 时钟频率（顶层例化 / 超时换算的唯一来源）----
`define VBP_SD_CLK_HZ      100_000_000  // sd_card_clk
`define VBP_PIX_CLK_HZ     75_000_000   // video_clk（720p60）

// ---- 叠加层原点 ----
`define VBP_WIN_X0         446          // 浏览器窗口外框左上角
`define VBP_WIN_Y0         286
`define VBP_TEXT_X         578          // ERROR n 文本左上角
`define VBP_TEXT_Y         349

// ---- fat_chain_map bank 归属（唯一出处）----
//   图像链用 bank0，WAV 播放链用 bank1；walker 写口与两个 lba_stream
//   的读口都必须引用这里的宏，禁止再写裸 0/1 字面量。
`define VBP_MAP_BANK_IMG   1'b0
`define VBP_MAP_BANK_WAV   1'b1

// ---- 音频播放 OSD 卡片（左上日期时钟下方）----
//   y=64 字幕行结束后留 8 px 空隙；卡片与日期时钟底板同为 136×52。
`define VBP_OSD_X0         8       // 面板左上角
`define VBP_OSD_Y0         88
`define VBP_OSD_W          136
`define VBP_OSD_H          52
`define VBP_OSD_BORDER     2       // 面板边框厚度
`define VBP_OSD_TXT_X      16
`define VBP_OSD_TXT_Y      100
`define VBP_OSD_TXT_SCALE  1
`define VBP_OSD_BAR_X0     16
`define VBP_OSD_BAR_Y0     122
`define VBP_OSD_BAR_W      120
`define VBP_OSD_BAR_H      16
// ---- 底部频谱（80 根显示条，仍由 12 个 Goertzel 频带驱动）----
//   每 16 px 单元放置 12 px 白色玻璃条，左右各留 2 px；最大高度 88 px。
`define VBP_OSD_BANDS      12      // 实际分析频带数
`define VBP_OSD_BAND_W     4       // 兼容原接口；新 painter 使用固定 16 px 单元
`define VBP_OSD_BAND_SH    2
`define VBP_OSD_ANIM_X0    0
`define VBP_OSD_ANIM_Y0    624
`define VBP_OSD_ANIM_W     1280
`define VBP_OSD_ANIM_H     88
`define VBP_OSD_ICON_X0    108
`define VBP_OSD_ICON_Y0    92
`define VBP_OSD_ICON_W     28
`define VBP_OSD_ICON_H     28

// Neutral glass UI geometry. All coordinates refer to input active pixels.
`define VBP_UI_PANEL_X 28
`define VBP_UI_PANEL_Y 192
`define VBP_UI_PANEL_W 1224
`define VBP_UI_PANEL_H 316
`define VBP_UI_CARD_X 44
`define VBP_UI_CARD_Y 260
`define VBP_UI_CARD_W 160
`define VBP_UI_CARD_H 216
`define VBP_UI_CARD_STEP 172
`define VBP_UI_SMOKE 8'd20
`define VBP_UI_WHITE 8'd255
`define VBP_UI_EDGE 8'd148
`endif // VIDEO_BMP_PARAMS_VH
