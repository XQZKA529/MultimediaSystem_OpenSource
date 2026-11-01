# 频谱条圆头（2026-10-31）

底部 80 根 12 px 玻璃频谱条的顶端原来是 2 行切角（8 → 10 → 12 px），实机上是一个明显的两级台阶，弧线不成立。本次只改顶端几何：按半圆取宽做成 4 行弧顶，顶部两行保留亮白高光。柱高来源、12 带插值、16 px 节距、条身玻璃调色、暂停语义和两拍流延迟全部不变。

## 形状

| 距柱顶行 | 左边界 | 右边界 | 宽度 | 墨色 |
|---|---:|---:|---:|---|
| 0 | 6 | 9 | 4 px | `OSD_INK_HEAD`（75% 白） |
| 1 | 4 | 11 | 8 px | `OSD_INK_HEAD`（75% 白） |
| 2 | 3 | 12 | 10 px | `OSD_INK_FILL`（50% 白）/ 暂停 `DIM` |
| 3 | 3 | 12 | 10 px | `OSD_INK_FILL` / `DIM` |
| ≥4 | 2 | 13 | 12 px | `OSD_INK_FILL` / `DIM` |

这是 12 px 条宽能做出的最圆顶端（半径 = 半宽 6 px）。墨色代码沿用现有语义，`audio_osd_overlay.v` 的调色板与合成表达式无需改动。

## 实现

改动只在 [osd_paint_anim.v](../../render/rtl/ui/osd_paint_anim.v) 的顶端判定：

- `top_y = 88 − 4h` 永远是 4 的倍数，所以「距柱顶行号」的低两位就是 `py[1:0]`，4 行弧顶只可能落在唯一一条 4 px 行带 `py[6:2] == MAX_HEIGHT − h` 内；
- 由 `py[1:0]` 直接解码内缩 4 / 2 / 1 / 1，不需要 7 bit 减法，也不存在 `py < top_y` 的回绕问题；
- 原来两个 7 bit 比较（`py==top_y`、`py==top_y+1`）换成一次 5 bit 行带比较，组合深度与面积预期持平或略优；
- `draw`/`ink` 仍是组合输出，`REGISTERED` 选择级与父模块寄存级不变，端到端仍是两拍延迟。

## 验证

- `render/sim/run.ps1 -Test tb_audio_osd_layout`：**PASS**，6,451,329 项全帧像素与几何检查。探针从只取单元中心 1 个位置扩展为单元内 16 个位置，弧宽首次被真正覆盖；新增 4 px 最低柱（level 1）用例，验证此时条身只剩弧顶 4 行 4/8/10/10。
- 回归：`tb_image_contrast`、`tb_text_osd_pipeline`、`tb_text_osd_frame_ppm` 通过（三者在频谱高度为 0 的配置下覆盖 overlay 合成链路）。
- 视觉证据（真实 RTL 720p 帧，底部区域）：[全宽 2×](evidence/audio-spectrum-cap-2026-10-31.png)、[8× 局部](evidence/audio-spectrum-cap-zoom-2026-10-31.png)。

## 资源与时序

综合结果比签核版略小：LUT 13,071（签核版 13,078）、DFF 12,523（12,524）、MACRO_ADD 1,207（1,209）、MACRO_EQ 579（580）。但 render 已占 98% Slice，重新布局后时序没有复现签核版的 +0.052 ns。

按签核配置（`area_prior`、`infer_fsm off`、area effort high、physical effort medium）扫 seed 4–11 的结果：

| seed | Setup WNS | Setup 违例端点 | Hold WNS | Slice |
|---|---:|---:|---:|---:|
| 4 | −1.566 | 50 | +0.022 | 9,640 |
| 5 | −0.360 | 14 | +0.022 | 9,635 |
| 6 | −0.689 | 15 | +0.022 | 9,633 |
| 7 | −0.439 | 9 | −0.044 | 9,562 |
| 8 | −0.739 | 32 | +0.024 | 9,600 |
| 9 | −1.128 | 37 | +0.022 | 9,565 |
| 10 | −0.679 | 59 | +0.022 | 9,584 |
| 11 | −2.893 | 209 | +0.022 | 9,663 |

PhysicalEffort high 再试 seed 5/7/4：−0.792 / −0.465 / **−0.318**。最优结果是 high effort + seed 4，违例路径为 `u_link/byte_count_reg → tx_header_word_reg.ce`（mem_tx_clk 125 MHz，数据路径 7.966 ns，其中 74% 为线延迟），与频谱逻辑无关；之前各 seed 的最差路径也分散在 `u_shared_font`、`u_link/peer_age` 等既有临界路径上，属于 98% Slice 下的布局布线波动。

结论：**本次改动没有拿到签核 bit**。签核版 +0.052 ns 本身已贴着零，换网表后需要更多种子才可能复现零违例。

## 试板 bit（未签核）

为了先确认视觉效果，用 `high physical effort + seed 4` 生成了一颗旁路签核门槛的试板 bit：

| 项目 | 值 |
|---|---|
| 路径 | `render/Runs/phy_trial/MultimediaSystem_render.bit` |
| SHA256 | `cf5667be3346ca7575300b19b14dc1b056eb9ef7c401a36c2feb75edecbe5bb4` |
| Setup WNS / TNS | **−0.318 ns / −2.211 ns**（15 个端点） |
| Hold WNS / TNS | +0.022 ns / 0（0 个端点） |
| Slice | 9,610 / 9,800（98.06%） |
| 报告 | `render/Runs/phy_trial/final.qor`、`route.qor`、`final_timing.rpt` |

生成方式：临时把 `render/build/MyFlow.tcl` 里 `bitgen_fun` 的签核拒绝改成告警（`TRIAL BIT: qualification bypassed ...`），跑 `render/build/run.ps1 -Stage all -RunTag trial -PhysicalEffort high -PlaceSeed 4`，构建结束后已把 `MyFlow.tcl` 恢复原样（`git diff` 为空）。`check-reports.ps1` 对这颗 bit 仍返回 UNQUALIFIED，这是预期。

风险：Setup 违例集中在 `u_link` 的 125 MHz 发送路径，室温下大概率能跑，但链路（图像/音频）在电压、温度波动下可能出现偶发错误。**只用于视觉验收，不能作为交付 bit**；media 侧继续使用签核版 bit 不受影响。

> 注：这颗试板 bit 是在后续 [链路 CE 预寄存](render-link-ce-timing-2026-10-31.md) 之前生成的，不包含该时序优化。2026-11-01 已用 CE 修正后的网表 + seed 6 完成签核：`render/Runs/phy_ce_s6/MultimediaSystem_render.bit`（Setup +0.104 ns / Hold +0.022 ns / 0 违例 / Slice 9,605，SHA256 `57ecdeae…`），该 bit 包含本次圆头改动，可直接上板。

实板检查项：80 根条顶端是否为 4 级圆弧、顶部两行是否偏亮、最低柱（4 px）是否呈小圆头、暂停时是否仍冻结并压暗、面板/字幕/时钟区域是否有误画。
