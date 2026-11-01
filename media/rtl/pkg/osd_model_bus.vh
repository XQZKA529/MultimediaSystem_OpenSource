//=============================================================================
// osd_model_bus.vh — 音频 OSD「渲染模型」契约的捆绑位分配
//
// 语义层 audio_osd_status（唯一产生者）→ 渲染层 audio_osd_overlay（唯一消费者，
// 再由它转发给 4 个纯组合 painter）。用一条宽向量过端口，取代"每加一个节目就
// 加一排端口"，与 pkg/fat_dir_bus.vh 的既有习惯一致。
//
// 切片宏是位分配的**唯一出处**：
//
//   model[`OSD_M_FILLPX]  进度条应填充的像素列数（样本轴 DDA 结果；含钳位）
//   model[`OSD_M_BEAT]    节拍相位 0..3（4 根竖条动画用）
//   model[`OSD_M_TXT]     13 字符 × 8bit，固定格式 "MM:SS / MM:SS"（补零）
//   model[`OSD_M_SHOW]    显隐使能（1 = 画面右下角显示面板）
//   model[`OSD_M_PAUSED]  暂停态（图标画 ⏸ 并呼吸压暗、动画冻结）
//   model[`OSD_M_BLINK1]  1 Hz 方波电平（暂停呼吸/闪烁用；注意是电平不是脉冲）
//
// 另有墨色代码 OSD_INK_*（painter → 合成器），见文件末。
//
// ★ 宏内容是**裸索引范围**（不带方括号），使用处统一写
//   model[`OSD_M_XXX]——展开即 model[9:0] 等，与 fat_dir_bus.vh 同一写法。
//
// ★ 位分配冻结：下位 117 位一经发布不再改动（TB 与综合产物依赖）。
//   新字段一律从 OSD_M_W 尾部追加并同步加宽 OSD_M_W。
//
// ★ 解耦纪律（可静态核对，见 doc/audio-osd-implementation-plan.md）：
//   进度相关字段（FILLPX）与动画相关字段（BEAT/TICK1/PAUSED）**互不重叠**，
//   对应 painter 只允许引用自己那一组 —— 两个 painter 之间没有任何信号，
//   也互不知道对方存在。换动画只需重写 osd_paint_anim.v。
//
// include 路径约定：rtl/ 子目录内用 `include "../pkg/osd_model_bus.vh"；
// 顶层用 `include "pkg/osd_model_bus.vh"（与 fat_dir_bus.vh 一致）。
//=============================================================================
`ifndef OSD_MODEL_BUS_VH
`define OSD_MODEL_BUS_VH

`define OSD_M_W        208

`define OSD_M_FILLPX   9:0        // [9:0]   已播像素列数（0..BAR_W）
`define OSD_M_BEAT     11:10      // [11:10] 节拍相位 0..3
`define OSD_M_TXT      115:12     // [115:12] 13 字符：第 i 个字在 txt[i*8+7 : i*8]（低字节在前）
`define OSD_M_SHOW     116        // [116]   面板显隐
`define OSD_M_PAUSED   117        // [117]   暂停态
`define OSD_M_BLINK1   118        // [118]   1 Hz 方波电平（暂停呼吸/闪烁用；不是单拍脉冲）
// [127:119] 保留
//
// ★ 频谱柱字段已按 **16 柱 × 5 bit = 80 bit** 预留（2026-09-28）。
//   当前只用到低 60 bit（12 柱，见 `VBP_OSD_BANDS）。
//   扩展频点到 16 柱以内**不用改这里**；超过 16 柱才同步加宽
//   `OSD_M_W 与 `OSD_M_SPEC_W，并把 OSD_M_SPEC 一起往后挪。
`define OSD_M_SPEC_W   80        // 16 柱 × 5 bit
`define OSD_M_SPEC     207:128   // 柱高，lane b 占用 bits[b*5 +: 5]，高度 0..22

// 文本缓冲规格（与 osd_paint_text / audio_osd_status 共用，禁止再写裸数字）
`define OSD_TXT_CHARS  13
`define OSD_TXT_W      104        // OSD_TXT_CHARS * 8

// ---- 墨色代码：painter → 合成器 ----
// painter 只报"这一像素要上什么语义的墨"（3 bit），RGB 由 audio_osd_overlay
// 统一查表。这样调色板只有一处、干净利落；换/加一个 painter 不会牵动配色，
// 也不会因为某个 painter 自带颜色而与面板底色打架。
// 0 保留（= 不画，由 draw=0 表达）。
`define OSD_INK_BORDER   3'd1      // 面板边框         #808490
`define OSD_INK_TEXT     3'd2      // 正文             #E0E0E0
`define OSD_INK_TEXTDIM  3'd3      // 次要正文（" / "） #8A8A85
`define OSD_INK_TRACK    3'd4      // 进度条虚线轨道    #5F5E5A
`define OSD_INK_FILL     3'd5      // 已播实心 / ▶ / 节拍条  白色
`define OSD_INK_HEAD     3'd6      // 播放头           #E0E0E0
`define OSD_INK_DIM      3'd7      // 压暗色（暂停时的节拍条/⏸） #A06A18

`endif // OSD_MODEL_BUS_VH
