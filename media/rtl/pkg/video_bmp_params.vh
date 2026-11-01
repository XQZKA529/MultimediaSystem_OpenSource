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
// 2026-10-30：bus_clk 100 MHz -> 50 MHz（board_sys_pll: REFCLK_DIV=1,
// FBCLK_DIV=1, CLKC0_DIV=20；VCO 仍 1000 MHz，CLKC1..3 仍 125 MHz）。
// 降频路线实测：100（布线发散）-> 83.333（Phase 6 崩 -3.15）-> 76.923（-3.06）
// -> 50 MHz（**只剩 1 个端点 -0.244**）-> 45.455（+7.6 ns 余量，但被 SD 的
// set_max_delay 例外路径和工具崩溃挡住，说明瓶颈不在周期）-> 回到 50 MHz。
// 关键：SD 分频同步为 DIV_FAST=1、SAMPLE_DLY=0（见 media_core.v），
// 于是 SD_CLK = 50/(2*1) = 25 MHz **与 100 MHz 版本完全相同**，
// 读卡带宽、采样点（上升沿后 20 ns = 位眼中心）都不变。
`define VBP_SD_CLK_HZ      50_000_000  // sd_card_clk / bus_clk
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

// ---- 音频播放 OSD 面板（右下角）----
//   面板内容（上行）时间文本 · 节拍动画 · 播放/暂停图标；（下行）横向进度条
//   右边距 = 1280-(X0+W) = 16；下边距 = 720-(Y0+H) = 16
//   面板内边距：左/右 8，上 16(到图标顶 632)、下 16(条底 685 → 内框底 701)
`define VBP_OSD_X0         904     // 面板左上角
`define VBP_OSD_Y0         616
`define VBP_OSD_W          360
`define VBP_OSD_H          88
`define VBP_OSD_BORDER     2       // 面板边框厚度（内框 = 906..1261 × 618..701）
`define VBP_OSD_TXT_X      914     // 时间文本左上角（13 字符 × 12 px = 156 px → 914..1069）
`define VBP_OSD_TXT_Y      638     // 与 28 px 高的图标区垂直居中（632 + (28-16)/2）
`define VBP_OSD_TXT_SCALE  2       // 5×7 点阵放大倍数 ⇒ 字符格 12×16
`define VBP_OSD_BAR_X0     914     // 进度条槽左上角（右端 1253，两侧内边距各 8）
`define VBP_OSD_BAR_Y0     670
`define VBP_OSD_BAR_W      340
`define VBP_OSD_BAR_H      16
// ---- 频谱柱（原「4 根节拍竖条」区已被真实频谱取代）----
//   ★ 扩展频点的唯一入口就在这里 + rtl/fft/audio_fft_osd.v 的 band_coef() 表。
//   约束：`VBP_OSD_ANIM_W 必须 = `VBP_OSD_BANDS × `VBP_OSD_BAND_W，
//         `VBP_OSD_BAND_W 必须是 2 的幂，`VBP_OSD_BAND_SH = log2(BAND_W)。
//   柱数 ≤16 时 `OSD_M_SPEC（80 bit）已预留，不用动 osd_model_bus.vh；
//   超过 16 柱才需要整体加宽 `OSD_M_W 与 `OSD_M_SPEC_W。
//   若要改 ANIM_W，必须同步挪 ANIM_X0 / ICON_X0，别让面板元素撞车。
`define VBP_OSD_BANDS      12      // 频谱柱数
`define VBP_OSD_BAND_W     4       // 每柱占用的像素列（其中最后 1 列留作间隔）
`define VBP_OSD_BAND_SH    2       // = log2(`VBP_OSD_BAND_W)
`define VBP_OSD_ANIM_X0    1082
`define VBP_OSD_ANIM_Y0    632
`define VBP_OSD_ANIM_W     48      // = `VBP_OSD_BANDS * `VBP_OSD_BAND_W
`define VBP_OSD_ANIM_H     22
`define VBP_OSD_ICON_X0    1222    // 播放/暂停图标 28×28
`define VBP_OSD_ICON_Y0    632
`define VBP_OSD_ICON_W     28
`define VBP_OSD_ICON_H     28

`endif // VIDEO_BMP_PARAMS_VH
