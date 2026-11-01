# 双板工程开发与验证记录

本文件集中保存开发时间线、阶段性资源/时序结果、故障与修复记录。历史段落中的“当前”“本轮”“新增”均指原记录时点，不能用来判断工作树或选择烧录配对。日常使用见[系统 README](../../README.md)，发布文件按各自 release 清单核对。

## 专题记录索引
- [720p 全显示字库抗锯齿升级](aa-font-2026-10-09.md)
- [双板 Slice 面积优化记录（2026-10-22）](area-optimization-2026-10-22.md)
- [双板音频暂停、快进故障：本次独立代码分析与仿真](audio-pause-seek-audit-2026-10-07.md)
- [播放卡片与底部频谱调整（2026-10-22）](audio-playback-spectrum-2026-10-22.md)
- [播放卡片缩小与 80 根白色玻璃频谱（2026-10-22）](audio-playback-spectrum-compact80-2026-10-22.md)
- [音量控制（2026-10-09）](audio-volume-2026-10-09.md)
- [render 黑屏调查](black-screen-investigation-2026-10-09.md)
- [两板 BRAM 利用与资源优化评估](bram-optimization-evaluation-2026-10-09.md)
- [日期时钟（协议 1.9，2026-10-14）](calendar-clock-2026-10-14.md)
- [CLOCK 首图 ERROR 5：图片接收时序恢复试板](clock-rx-timing-fix-2026-10-14.md)
- [交叉淡化版本排障记录（2026-10-08）](crossfade-repair-2026-10-08.md)
- [当前两板资源与 media 后续优化评估](current-resource-assessment-2026-10-09.md)
- [GPIO 方向警报与 C 键警报（2026-10-14）](emergency-gpio-2026-10-14.md)
- [紧急触发时间记录（2026-10-14，协议 1.9）](emergency-time-2026-10-14.md)
- [B/C 应急接管首版（2026-10-13）](emergency-v1-2026-10-13.md)
- [render GUI 增量布线修复](gui-route-repair-2026-10-09.md)
- [移交说明：双板工程 media 时序收敛（2026-10-30）](handover-media-timing-2026-10-30.md)
- [图片配音与可调轮播评估（协议 1.13）](image-audio-interval-evaluation-2026-10-24.md)
- [图片对比度设置与独立像素模块（2026-10-08）](image-contrast-2026-10-08.md)
- [BMP 自动缩放（2026-10-09）](image-scaling-2026-10-09.md)
- [BMP ERROR 5 回归排查与修复（2026-10-09）](image-scaling-repair-2026-10-09.md)
- [图片切换 NOT A BMP / ERROR 4 排查（2026-10-24）](image-switch-investigation-2026-10-24.md)
- [RTL 与实际 TEMAC 网表独立排查（2026-10-07）](independent-link-sd-audit-2026-10-07.md)
- [Render 板 TM1650 矩阵键盘](matrix-keypad-2026-10-08.md)
- [media 零违例版本（V4）可行性分析（2026-10-30）](media-v4-closure-analysis-2026-10-30.md)
- [media 音量版GUI增量布线修复](media-volume-route-repair-2026-10-09.md)
- [BRAM 之外的器件资源核对](other-resource-evaluation-2026-10-09.md)
- [64×64 overlay 数据链根因修复（2026-10-22）](overlay64-data-path-fix-2026-10-22.md)
- [SD 64×64 小图叠加实现评估（2026-10-21）](overlay64-evaluation-2026-10-21.md)
- [render 链路发送 CE 预寄存（2026-10-31）](render-link-ce-timing-2026-10-31.md)
- [render Slice 与时序收敛（2026-10-25）](render-slice-timing-2026-10-25.md)
- [双板资源优化实验记录（已按用户要求收尾）](resource-optimization-2026-10-14.md)
- [SD 卡 TXT 静态字幕（2026-10-11）](sd-subtitle-2026-10-11.md)
- [设置菜单、DDC/CI 与全局亮度实现（2026-10-08）](settings-brightness-2026-10-08.md)
- [图片饱和度设置（2026-10-28，协议 v1.14）](settings-saturation-2026-10-28.md)
- [两板 Slice 优化实施与筛选](slice-optimization-2026-10-09.md)
- [两板 Slice 优化首轮实施（2026-10-12）](slice-optimization-2026-10-12.md)
- [两板 Slice 优化第二轮（2026-10-12）](slice-optimization-round2-2026-10-12.md)
- [两板 Slice 优化第三轮（2026-10-12）](slice-optimization-round3-2026-10-12.md)
- [两板 Slice 优化第四轮：等价算法替换（2026-10-12）](slice-optimization-round4-2026-10-12.md)
- [FAT32 挂载运算分步化实验（第五轮，2026-10-12）](slice-optimization-round5-2026-10-12.md)
- [media 字幕元数据存储实验（第六轮，2026-10-13）](slice-optimization-round6-2026-10-13.md)
- [频谱条圆头（2026-10-31）](spectrum-cap-2026-10-31.md)
- [256 字符字幕滚动实现评估（2026-10-22）](subtitle-scroll-evaluation-2026-10-22.md)
- [切图加载期间黑条与 HDMI 嗡嗡声排查](switch-artifacts-investigation-2026-10-09.md)
- [Render 本地 Text OSD](text-osd-2026-10-08.md)
- [Text OSD GUI烧录恢复记录](text-osd-gui-recovery-2026-10-09.md)
- [Text OSD 完整实现代码](text-osd-source-2026-10-08.md)
- [双板时序闭合优化（2026-10-22）](timing-closure-2026-10-22.md)
- [双板时序继续优化（2026-10-22）](timing-closure-followup-2026-10-22.md)
- [视频功能的资源可行性与取删方案（2026-10-29）](video-feasibility-2026-10-29.md)

其他 media 专题：[面积等价评估](../media-area95-equivalence-2026-10-26.md)、[时序/面积分析](../media-timing-slice-analysis-2026-10-26.md)、[优化记录](../media-zero-2026-10-28.md)。独立板级早期记录见 [media history](../../media/doc/history/)。

## 发布构建记录

- 首次完整签核：`8a46c85`；media 50 MHz、render 100 MHz，构建数据保存在 `release/First_Release_8a46c85/`。
- 第二次签核：`682b0ab`；对应频谱圆头、render 链路 CE 及 media 重传配置等工作，固化文件、校验和、输入指纹和最终 QoR 保存在 `release/Second_Release_682b0ab/`。这两套发布包各自成对，不混搭。

## 从 README 迁出的原始记录

下面按原文件保留开发记录原文，包含当时的判断、待办、资源数字与旧包路径。原文中的用法和状态可能已被后续实现替代；它们只作为历史证据。

### 原文件 `README.md`

````markdown
## 资源与时序现状

### 当前版本：两板首次完整签核版（提交 `8a46c854ec4fc0419b9fdffc7cf28bbcd088cb5b`，2026-10-30）

| 指标 | media（总线 50 MHz） | render（100 MHz） |
|---|---:|---:|
| Setup WNS / TNS / 违例端点 | **+0.081 ns / 0 / 0** | **+0.052 ns / 0 / 0** |
| Hold WNS / TNS / 违例端点 | **+0.024 ns / 0 / 0** | **+0.021 ns / 0 / 0** |
| Slice | 9,441 / 9,800（96.34%） | 9,593 / 9,800（97.89%） |
| BRAM9K + BRAM32K | 49 + 5 | 64 + 16 |
| DSP | 25 / 29 | 29 / 29 |
| `check-reports.ps1` | QUALIFIED | QUALIFIED |
| bit | `media/Runs/pv9s8/MultimediaSystem_media.bit` | `render/Runs/phy_sat_zero_v2/MultimediaSystem_render.bit` |
| bit SHA256（前 8 位） | `bea01982` | `331a300b` |

发布包（含两颗 bit、SHA256、manifest 与复现命令）：`两板首次完整签核版-8a46c85.zip`（散装在 `release/两板首次完整签核版-8a46c85/`）。

media 本版要点：

- **bus_clk 100 → 50 MHz**，同时 SD 分频改为 `DIV_FAST=1`，**SD_CLK 仍为 25 MHz**，采样点仍是位眼中心——读卡带宽与采样相位与 100 MHz 版本完全一致，功能与协议不变；
- 两处 RTL 优化：`db_link.v` 描述符 RAM 输出寄存一拍（消除布线后 15.78 ns 的跨模块锥）、`fat_wav_controller.v` `want_stop` 预寄存（消除 15 级 / fanout 69 的控制锥）；
- 降频实测路线（100 → 83.33 → 76.92 → 50 → 45.45 MHz）与两处优化的依据、仿真记录见 [media 零违例分析](doc/dual-board/media-v4-closure-analysis-2026-10-30.md)；
- render 与 2026-10-28 签核版输入指纹 114 项零差异，本次在本工作区按相同配置（`InferFsm off / AreaEffort high / PhysicalEffort medium / seed 4`）复刻生成，时序资源逐项一致。

### 历史基线（已过时，仅作对照）

**下表为新增饱和度前后的历史结果，不能作为当前源码的签核依据。**

2026-10-28饱和度版本已完成 render 时序收敛：最终 M-Slice 4792/4900、L-Slice 4801/4900，总 Slice 9593/9800；Setup WNS +0.052 ns、Hold WNS +0.021 ns，TNS 与违例端点均为0。详见[饱和度实现与验证记录](doc/dual-board/settings-saturation-2026-10-28.md)。

| 指标 | media（历史） | render（历史） |
|---|---:|---:|
| Slice | 9,675 / 9,800（98.72%，放置阶段） | 9,433 / 9,800（96.26%，已布线） |
| BRAM9K + BRAM32K | 58 + 1 | 63 + 15 |
| DSP | 28 / 29 | 29 / 29 |
| Setup WNS / TNS | −0.522 ns / −31.641 ns | +0.105 ns / 0 |
| Setup 违例端点 | 213 | 0 |
| bit | 无（时序未闭合） | 已生成单板 bit |

说明：

1. **render 曾在 2026-10-25 与 2026-10-28 两次达到 Setup/Hold 全零违例**；本次交付的 render bit 与 2026-10-28 签核版构建输入逐字节一致（114 项指纹零差异），在本工作区复刻生成。
2. **media 的时序收敛历程**：100 MHz 下最佳同源布线为 −0.522 ns / 213 端点；多轮 RTL 微调与十余个候选方向均未闭合。最终方案为总线降频至 50 MHz（SD 时钟不变）加两处定点 RTL 优化，全过程见 [media 零违例分析](doc/dual-board/media-v4-closure-analysis-2026-10-30.md)。
3. **实板方面**：2026-10-07 用户确认双板功能全部恢复；2026-10-30 用户确认本签核版两板实板可用。长期验收（连续运行、PRBS 吞吐、大图加载时长、拔插复位）另行记录。

资源的根本矛盾很清楚：把一套中型多媒体 SoC 的功能压进一颗两万门级的入门 FPGA。1080p、更多图层、更大缓冲，在这个器件上已没有空间。

---

## 文档索引

| 主题 | 文档 |
|---|---|
| 链路协议全文 | [protocol-v1.md](doc/dual-board/protocol-v1.md) |
| 双板实现说明 | [implementation.md](doc/dual-board/implementation.md) |
| 实板状态与验收 | [hardware-acceptance.md](doc/dual-board/hardware-acceptance.md) |
| 时序收敛过程 | [timing-closure-2026-10-22.md](doc/dual-board/timing-closure-2026-10-22.md) |
| **两板首次完整签核（50 MHz 方案）** | [media-v4-closure-analysis-2026-10-30.md](doc/dual-board/media-v4-closure-analysis-2026-10-30.md) |
| render 零违例收敛 | [render-slice-timing-2026-10-25.md](doc/dual-board/render-slice-timing-2026-10-25.md) |
| 面积优化实验 | [area-optimization-2026-10-22.md](doc/dual-board/area-optimization-2026-10-22.md) |
| 图片配音与轮播 | [image-audio-interval-evaluation-2026-10-24.md](doc/dual-board/image-audio-interval-evaluation-2026-10-24.md) |
| 小图与转场 | [overlay64-evaluation-2026-10-21.md](doc/dual-board/overlay64-evaluation-2026-10-21.md) |
| 完整文档导航 | [doc/README.md](doc/README.md) |
| 双板快速说明 | [README-dual-board.md](README-dual-board.md) |

板级细节见 [media/README.md](media/README.md) 与 [render/README.md](render/README.md)。历史版本的资源、时序与 bit 记录保留在 `doc/dual-board/` 与 `build/` 中，标注为历史证据，不作为当前源码的签核依据。

本文件与两份板级 README 于 2026-10-26 重写：此前三份文档按日期倒序堆叠了数十个版本的变更记录，同一段说明在根与板级文档中重复出现，难以作为工程入口使用。原内容完整备份在 `build/doc-backup-20261026/`，其中的每日变更细节已归入 `doc/dual-board/` 对应专题文档。
````

### 原文件 `README-dual-board.md`

````markdown
# 双板工程使用说明

> 当前源码采用协议 v1.14，并新增仅作用于图片的 SATURATION 设置。本文保留较早版本的构建和试板记录；当前功能及交付状态以 [README](README.md) 和 [协议文档](doc/dual-board/protocol-v1.md) 为准。

**2026-10-30 更新：两板首次完整签核版已交付。** media 以 50 MHz 总线（SD_CLK 仍 25 MHz，读卡零损失）通过 Setup/Hold 零违例签核并生成 bit（9441 Slice，Setup +0.081 ns）；render 复刻 2026-10-28 签核版成功（9593 Slice，Setup +0.052 ns）。配套 bit、SHA256 与提交号 `8a46c85` 见根目录 `两板首次完整签核版-8a46c85.zip`；过程与依据见 [media 零违例分析](doc/dual-board/media-v4-closure-analysis-2026-10-30.md)。以下 2026-10-28 记录保留为历史。

2026-10-28更新：含饱和度的render已实现Setup/Hold零违例，总Slice9593/9800、M/L分别4792/4801（各上限4900）；当时media尚未签核。历史记录见[本轮说明](doc/dual-board/settings-saturation-2026-10-28.md)。

## 字幕滚动与容量（协议 1.12）

手打文字、手动 TXT 和自动匹配 TXT 共用最多 256 字符容量。720p 主屏字幕显示于 x=192–1087 的中间 70% 区域，74 字符以内按宽度居中；更长文本平滑向左滚动，每两帧移动 1 像素，首尾各停约 1 秒后循环。TXT 有界读取为 260 字节，超长内容保留前 256 字符并提示 `TRUNCATED (256)`。该字幕容量从协议1.12引入；当前两板必须配套使用协议1.13。操作与验证见 [SD 字幕说明](doc/dual-board/sd-subtitle-2026-10-11.md)，字段定义见[协议文档](doc/dual-board/protocol-v1.md)。

## 当前工作树扩展：图片配音、可调轮播、字幕、小图与转场（协议 1.13）

SD根目录可放置固定名 `OVERLAY.BMP`（大小写不敏感；64×64、24-bit、BI_RGB、正高度）。media读取后转RGB565并发送至render；不透明小图固定显示于 x=1200–1263，跟随全局亮度，不参与转场。设置、应急、诊断和断线画面隐藏。小图功能由协议1.11引入，当前两板须配套使用协议1.13。样例及转换器见 [`examples/overlay`](examples/overlay) 和 [`tools/convert_sd_overlay.py`](tools/convert_sd_overlay.py)。

设置主页在最右侧新增 INTERVAL 项，仍为单排九张卡片；可设5–300秒，步进5秒，默认5秒。图片显示后查找同名WAV：找到时播放配音，自动轮播按实际播放曲尾切图，关闭轮播时循环配音；找不到时背景音频继续播放，自动轮播使用所设间隔。查找复用字幕目录扫描与名称缓存，图标缩放后继续使用原共享BRAM。协议与实现说明见 [双板协议](doc/dual-board/protocol-v1.md) 和 [render 实现](render/README.md#图片与显示)。两板必须配套使用协议1.13。

## 当前新增：紧急来源触发时间（2026-10-14，协议 1.9）

B0、B1、C 的有效顺序现在同时记录触发时的 **年月日和时分秒**。保留原 `→` / `=` 顺序行，下方最多三行白字按相同顺序显示，例如 `B0 2026-10-14 15:30:01`。时间来自 CLOCK，持续有效时保持不变，解除后移除，再触发更新时间并排到末尾。同周期确认共用时间；不同周期即使同秒也保留先后关系。

[操作、实现与实板验收](doc/dual-board/emergency-time-2026-10-14.md) · [本轮两板试板包](build/emergency-time-v1/release_emergency_time_trial.zip) · [画面预览](build/emergency-time-v1/preview/emergency-clock.png)

本次仅更新 render，media bit 沿用当前 CLOCK 接收修复版，协议仍为 1.9。验证通过 58 项用例及 25+11 张完整画面（23117792 像素）；render 为 9787/9800 Slice（99.87%），新增 BRAM/DSP/PLL 为 0。Hold WNS +0.022 ns、零违例；Setup WNS −1.015 ns / TNS −86.454 ns，按已约定试板标准交付。实板验收待执行，正式签核门槛不放宽。原 CLOCK 发布包保留作回退。下方 CLOCK 段说明日期时钟基础功能及此前实板版本。

### 当前两板资源与时序（最终布局布线，2026-10-14）

当前配套为协议 **1.9** 的紧急触发时间试板版，两板器件均为 **EG4S20BG256**。以下为最终布线及原生 Hold 修复后的结果；media 沿用原 bit，render 为本轮新 bit，下方较早版本的资源表作为历史记录。

| 项目 | media | render |
|---|---:|---:|
| Slice | 9707 / 9800（99.05%） | 9787 / 9800（99.87%） |
| LUT | 17737 / 19600（90.49%） | 17427 / 19600（88.91%） |
| 寄存器 | 12094 / 19600（61.70%） | 12588 / 19600（64.22%） |
| BRAM9K | 56 / 64（87.50%） | 51 / 64（79.69%） |
| BRAM32K | 1 / 16（6.25%） | 5 / 16（31.25%） |
| DSP | 7 / 29（24.14%） | 15 / 29（51.72%） |
| PLL | 1 / 4（25.00%） | 2 / 4（50.00%） |
| RAM 合计块数（9K + 32K） | 57 | 56 |
| Setup WNS | -2.413 ns | -1.015 ns |
| Setup TNS | -638.324 ns | -86.454 ns |
| Hold WNS | +0.022 ns | +0.022 ns |
| Hold TNS | +0.000 ns | +0.000 ns |
| Setup 违例端点 | 956 | 235 |
| Hold 违例端点 | 0 | 0 |
| 正式时序签核 | 未通过 | 未通过 |

media 剩余 **93 Slice**，render 剩余 **13 Slice**。相对上一版 CLOCK 接收修复版，media 资源不变，render 增加 **210 Slice**；两板新增 BRAM、DSP、PLL 均为 **0**。

两板资源均未超容量，Hold 均零违例，满足已约定试板标准；Setup 均未通过正式门槛，因此仍为**试板版本**。新增触发时间功能的实板验收待执行，正式签核脚本保持原要求。

构建标识：media `clock_v1_medium3`；render `emergency_time_v7_high5_nopost`（area_prior / high / seed5，post_place_opt=off，用于避开 TD 6.2 优化阶段崩溃）。资源和时序取自本次 bit 的最终报告，未重新构建或覆盖已交付试板包。

[发布清单与两板 bit SHA256](build/emergency-time-v1/release_emergency_time_trial/manifest.json) · [media 资源报告](media/Runs/phy_clock_v1_medium3/MultimediaSystem_media_phy.area) · [render 资源报告](render/Runs/phy_emergency_time_v7_high5_nopost/MultimediaSystem_render_phy.area) · [media 时序结果](media/Runs/phy_clock_v1_medium3/MultimediaSystem_media_phy.ts) · [render 时序结果](render/Runs/phy_emergency_time_v7_high5_nopost/MultimediaSystem_render_phy.ts)

## 日期时钟基础版本：新增日期时钟功能（2026-10-14，协议 1.9）

本次在双板多媒体系统中新增 **可设置的日期时钟**：屏幕左上角持续显示年月日和时分秒，设置主页新增第七项 **CLOCK**。支持 **2000–2099 年**，当前版本已获用户实板功能确认。

### 时钟显示与计时

左上角以两行显示日期和时间，格式如下：

```text
2000-01-01
00:00:00
```

- 日期位于 x=16、y=16，时间位于 x=16、y=36，采用现有抗锯齿字体、白字和暗色半透明底板。
- **主屏、设置、应急、诊断及断线画面均显示**。时钟在应急叠加和软件 RGB 亮度调节之后绘制；显示器自身的 DDC 亮度仍作用于整屏。
- 由 render 的 **100 MHz 总线时钟**产生每秒计时使能；暂停、切图、轮播、应急、media 复位和板间重连不停止或清零计时。
- 正确处理大小月、闰年和年月日进位；`2099-12-31 23:59:59` 后回到 `2000-01-01 00:00:00`。
- 上电或 **render 系统复位**默认为 `2000-01-01 00:00:00`。不增加 RTC 硬件，不提供掉电保存，断电后需重新设置。
- Text OSD 和 SD 字幕位于 **y=64**，共用256字符上限；在屏幕中间70%窗口内居中，长文本循环滚动。

### 在设置中调整日期时间

打开设置主页，选择第七项 **CLOCK**：矩阵 **2/8** 或板载 **KEY2 单击**选择菜单项，矩阵 **5** 或板载 **KEY4**进入。编辑页依次提供 `YEAR → MONTH → DAY → HOUR → MINUTE → SECOND → APPLY`。

| 编辑页操作 | 行为 |
|---|---|
| 矩阵 2 / 8 | 上一个 / 下一个字段，包含 APPLY，首尾循环 |
| 矩阵 4 / 6 | 减少 / 增加当前数值字段，支持原有方向键连发 |
| 在 APPLY 上按矩阵 5 | 一次性应用完整草稿，并清零不足一秒的计数；留在编辑页供核对 |
| 在其他字段上按矩阵 5 | 不应用日期时间 |
| 矩阵 # 或 KEY2 双击 | 返回设置主页，未应用的草稿丢弃 |
| KEY3 | 关闭设置，未应用的草稿丢弃 |
| 编辑页内 KEY2 单击 / KEY4 | 不调整或应用日期时间 |

数值范围：年 2000–2099，月 1–12，日 1–当月最后一天，时 0–23，分和秒 0–59。

进入编辑页时复制当前日期时间为草稿，**实际时钟继续运行**。字段达到上下限后循环；调整年份或月份时，若日期超过新月份的最后一天，自动钳位到最后一天，例如 1 月 31 日改为 4 月后变为 4 月 30 日。

进入按键与编辑操作隔离，页面显示确认后才接受编辑。应急、断线、media 重启或键盘故障会取消编辑并丢弃未应用草稿，**已应用时间保留**；键盘故障解除后返回并重新进入 CLOCK 编辑页。

[完整时钟操作与验收说明](doc/dual-board/calendar-clock-2026-10-14.md) · [设置主页预览](build/clock-v1/preview/settings.png) · [时钟编辑页预览](build/clock-v1/preview/editor.png)

### 工程集成与当前配套版本

日期计时、编辑草稿及绘制由 render 负责，media 管理 CLOCK 菜单入口与页面生命周期；不跨板传输日期值。 时钟复用共享字库第二读端口，新增 BRAM、DSP、PLL 均为 **0**。协议为 **1.9**，UI 快照仍为 **292 字节**，CLOCK 使用 page=7，不新增 opcode 或日期负载。

当前下载使用 `clock_v1_medium3` media 与 `clock_rxfix_v1_high8` render 配对：

- media：`media_CLOCK_RX_TIMING_TRIAL.bit`。
- render：`render_CLOCK_RX_TIMING_TRIAL.bit`。
- 已使用配套 CLOCK_TRIAL 1.9 时，media bit 相同，只需更新 render；从 GPIO 1.8 升级时两板一起更新，不能混用 1.8/1.9。

[当前配套下载包](build/clock-rx-timing-fix/release_clock_rx_timing_trial.zip) · [构建清单与 bit SHA256](build/clock-rx-timing-fix/release_clock_rx_timing_trial/manifest.json) · [实板功能确认记录](build/clock-rx-timing-fix/release_clock_rx_timing_trial.hardware-status.json)

### 验证与资源记录

时钟父版本完成 124 次仿真及补充检查，包含 36525 个日期边界和 11 种完整 720p 画面；当前接收时序修改版另完成 8 次针对性检查，覆盖图片、音频并行、字幕、CLOCK 菜单和非法元数据，没有重复完整回归。用户已确认当前版本可行，此前首图 ERROR 5 问题恢复，详见 [接收时序修改记录](doc/dual-board/clock-rx-timing-fix-2026-10-14.md) 和 [父版本仿真记录](build/clock-v1/regression.json)。

| 当前最终结果 | media | render |
|---|---:|---:|
| Slice | 9707（99.05%） | 9577（97.72%） |
| 相对 GPIO 版新增 Slice | +14 | +525 |
| BRAM9K + BRAM32K | 56 + 1 | 51 + 5 |
| DSP / PLL | 7 / 1 | 15 / 2 |
| Setup WNS | -2.413 ns | -0.380 ns |
| Setup TNS | -638.324 ns | -4.380 ns |
| Hold WNS | +0.022 ns | +0.022 ns |
| Hold TNS / 违例端点 | 0 / 0 | 0 / 0 |

当前属于**实板功能已确认、长期验收待完成的试板版本**；至少 20 次设置/应急进出、30 分钟混合播放及参考时钟误差尚未单独记录。两板 Hold 零违例，Setup 未达到正式门槛，正式检查脚本保持原要求。已交付 ZIP、bit 和构建清单保留原样，后续实板状态单独记录。

下方 GPIO 应急版及更早的资源、签核和 bit 为历史资料；首次 CLOCK_TRIAL 失败配对保留为故障证据，原 GPIO 配套包保留为整体回退版本。

## 历史：GPIO／C 键应急扩展（2026-10-14）

协议 **1.8**。日常图片目录顺序、背景音频和约 1 秒轮播间隔沿用现有逻辑；任一警报有效时，本地应急层接管画面，循环播放 SD 根目录的 `EMERG.WAV`，数字音量固定 100%。

| 来源 | render 板接线／操作 | 行为 |
|---|---|---|
| GPIOB0 | J2 第 1 脚，FPGA P4 | 高电平激活左箭头，回低解除 |
| GPIOB1 | J2 第 2 脚，FPGA N4 | 高电平激活右箭头，回低解除 |
| 矩阵键盘 C（编号 11） | 按下沿切换，长按不重复 | 激活／解除三角感叹号警报 |
| 矩阵键盘 B（编号 7） | 本版无动作 | 不再作为应急入口 |

GPIO 使用 **0/3.3 V、与 render 共地**，内部下拉、默认低电平；高低变化均经约 1 ms 稳定确认，不能直接输入 5 V。两个 GPIO 都低且 C 警报未锁存时，才恢复正常多媒体模式。

黑底红色图形、白色顺序小字；双 GPIO 显示双向箭头，C 与 GPIO 同时有效时采用上三角、下箭头的组合。小字只保留仍有效来源的顺序，同周期确认用 `=`，先后确认用 `→`，例如 `B0 = B1 → C`；解除后移除，再触发排到末尾。图案与文字在帧界一起更新。

最后来源解除后恢复原完整图片、原曲实际消费位置、暂停状态和轮播开关。增减来源不会重启应急音频或覆盖日常快照；恢复中重触发沿用原快照。菜单、编辑与断线期间仍可本地触发，应急及恢复期间屏蔽普通操作。

`EMERG.WAV` 接受 **48 kHz、16 bit PCM、单声道或立体声**，大小写不敏感，且不加入普通下一首列表；缺文件或读取失败时保留警报画面并静音。

### 下载与验证

[两板试板包](build/emergency-gpio/release_emergency_gpio3_seed5.zip) · [bit SHA256 与状态清单](build/emergency-gpio/release_emergency_gpio3_seed5/manifest.json) · [ZIP SHA256](build/emergency-gpio/release_emergency_gpio3_seed5.zip.sha256) · [七种组合画面](build/emergency-gpio/frames/emergency-combinations.png)

render 板下载 `render_GPIO.bit`；media 板使用 `media_TESTED.bit`。media 文件与此前用户实测通过的 request3 版本逐字节一致，已烧录该版本时只需更新 render。

| 最终结果（保持修复后） | media | render |
|---|---:|---:|
| Setup WNS | −2.154 ns | +0.103 ns |
| Setup TNS | −94.329 ns | 0 |
| Hold WNS／TNS | +0.024 ns／0 | +0.022 ns／0 |
| Slice | 9693（98.91%） | 9052（92.37%） |
| BRAM9K + BRAM32K | 56 + 1 = 57 | 51 + 5 = 56 |
| DSP | 7 | 15 |
| 静态时序签核 | 未通过；沿用用户已实测 bit | 已通过原签核门槛 |

**52 项回归通过**；七张完整 720p 应急画面核对 6,451,200 像素及 25 种有效顺序布局。用户已确认前版实板功能正常；本次新增 GPIO 功能仍待实板验证，包括 20 次进入／恢复及 10 分钟应急播放。

[接线、操作、构建与验收](doc/dual-board/emergency-gpio-2026-10-14.md) · [回归证据](doc/dual-board/evidence/emergency-regression.json) · [示例音频](examples/emergency/README.md)

当前键位、产物、资源和验证状态以本节为准；两板连接和日常操作见下文。旧 B 进入／C 退出规则已替换。

## 连接与分工

| 板 | 原生工程 | 外设 | 职责 |
|---|---|---|---|
| [media](media/README.md) | `media/MultimediaSystem_media.al` / `top_media` | SD卡、板载KEY2/3/4 | FAT32、BMP解码/缩放、WAV读取、目录/播放列表、菜单和发送 |
| [render](render/README.md) | `render/MultimediaSystem_render.al` / `top_render` | HDMI与音频、TM1650键盘、GPIOB0/1 | SDRAM双缓存、交叉淡化、PCM播放、文字/音频OSD、本地组合警报 |

两块EG4S20BG256 / HX4S20板用RTL8211E网口直连，固定千兆全双工。自定义Ethernet协议v1.8，无IP/UDP/ARP。矩阵键盘SCL/SDA接render GPIOB_26/J12、GPIOB_28/K14，外部上拉到3.3V；接线见[键盘文档](doc/dual-board/matrix-keypad-2026-10-08.md)。

## 素材与操作

FAT32根目录放BMP/WAV。BMP接受宽高各1–4096、24bpp、BI_RGB、正高度、自下而上；media最近邻contain缩放并居中补黑，网络仍传固定1280×720 RGB888。cover/stretch仅预留RTL接口，top-down BMP/JPG/PNG板上解码未实现；离线转换使用`tools/convert_fpga_bmp.py`，默认行为保持不变。WAV为48kHz、16bit PCM，单声道/立体声。

- KEY3打开/关闭设置；主页九项由KEY2单击选择、KEY4短按进入，INTERVAL位于最右侧；KEY2双击返回，单击保留300ms双击判断窗口。
- 亮度10%–100%，优先DDC/CI、失败回退全局RGB；对比度0%–200%，仅图片，均默认100%。KEY2加、KEY4减，每步10%；矩阵4减6增。
- 矩阵*打开、2/8选择、5确认、#返回；关窗4/6切图、A切轮播。板载关窗KEY2下一张、长按切轮播。
- Text OSD最多256字符；矩阵2/8/4/6移动、5确认，支持A–Z、SPACE/DEL/CLR与开关。在 y=64 的中间70%区域显示；74字符以内按宽度居中，更长文字每两帧左移1像素循环滚动。菜单/诊断时隐藏；render复位清空，退出/切图/断线/media复位保留。
- 关窗有音轨时KEY4单击暂停/恢复、双击下一首、长按2秒快进5秒；矩阵5单击/双击对应暂停/下一首，矩阵9退出播放（暂停时也有效）。退出清空待播缓冲、隐藏音频OSD，并取消当前图片配音循环及后台音乐恢复；新图片或重新选曲可再次播放。音频OSD保留当前图片背景。
- 有同名WAV时图片播放配音；轮播开启时按实际曲尾切图，关闭时循环配音。无匹配WAV时背景音频继续，自动轮播使用5–300秒INTERVAL。

## 事务与构建

图片BEGIN/READY/DATA/END/PRESENTED事务要求源端解包/缩放/最后打包全部交付、render整帧CRC和实际SDRAM写完成；VS启动约0.5秒/30帧交叉淡化，旧读通路安全交接后才回复PRESENTED。加载保留旧图，动画期间双缓存禁写，切图请求合并一次。media加载保留1秒无进展/15秒绝对上限，提交独立3秒；错误保留旧图，重连重新探测。

PCM按render实际消费位置流控，未播预留1536帧，WAV独立单扇区读取及260帧缓冲；快进先冻结确认再跳240000帧，暂停状态保留。

TD 6.2.168116，ModelSim10.5b，PowerShell7。GUI重新打开`.al`、Reset Syn/Phy再Run；完整功能文件与CLI `Runs/`及PRBS `*_linktest.bit`分开。

```powershell
$env:TD_ROOT='D:/AnLu_FPGA_environment'
$env:MODELSIM_BIN='D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem'
./media/build/run.ps1 -Stage all -RunTag current -PlaceSeed 3 -PhysicalEffort high -RouteEffort routability
./render/build/run.ps1 -Stage all -RunTag current -PlaceSeed 4 -PhysicalEffort medium
./media/build/check-reports.ps1 -RunDir ./media/Runs/phy_current
./render/build/check-reports.ps1 -RunDir ./render/Runs/phy_current
python ./tools/dual-board/audit.py
./tools/dual-board/run-system.ps1 -Test tb_text_osd_menu
./tools/dual-board/run-system.ps1 -ScaleBmp
./tools/dual-board/run-system.ps1 -Test tb_audio_system -ScaleBmp
./tools/dual-board/run-regression.ps1
```

CLI保持Setup WNS≥0.100ns、Setup/Hold零违例、BRAM9K≤56与输入指纹门槛；Slice80%为提示。GUI检查本轮面积/时序/route.qor与最终日志，不读取旧final.qor。CLI命令不承诺逐字节复现GUI产物。复制/新增源码更新本板`sources.txt`/`modules.json`，先留存产物，再执行`-Stage project`重建工程。

文字菜单恢复已有用户确认，多尺寸缩放/方向/黑边/加载时间、音频并行、断线复位、30分钟混合轮播及一小时PRBS仍待分别记录。本次文档更新核对资源报告，不重新执行全套构建和回归。

[协议](doc/dual-board/protocol-v1.md) · [实现](doc/dual-board/implementation.md) · [BMP缩放](doc/dual-board/image-scaling-2026-10-09.md) · [Text OSD](doc/dual-board/text-osd-2026-10-08.md) · [实板验收](doc/dual-board/hardware-acceptance.md) · [文档导航](doc/README.md)。
````

### 原文件 `media/README.md`

````markdown
## 资源与时序

2026-10-28 的当前优化 RTL 已合入：FAT 独热译码、缓存输出流水、挂载半字比较与现有 DSP 输入寄存器复用，链路序号进位预计算，以及菜单行元数据 ROM。相同配置下布局由 9742 降至 9536 Slice（M/L 4769/4767），DSP 仍为 26；完整布线尚在筛选，集中功能仿真尚未执行，不能作为零违例签核结果。详见[本轮优化与证据](../doc/media-zero-2026-10-28.md)。以下表格与记录均为历史证据。

| 项目 | 数值 | 来源与状态 |
|---|---:|---|
| Slice | 9,675 / 9,800（98.72%） | 2026-10-24 面积修正后 **放置** 报告 |
| LUT | 16,844 / 19,600 | 综合（2026-10-22 工作树） |
| 寄存器 | 10,858 / 19,600 | 综合（面积修正后） |
| BRAM9K + FIFO9K | 58 / 64 | 放置报告 |
| BRAM32K | 1 / 16 | 放置报告 |
| DSP | 28 / 29 | 放置报告 |
| PLL | 1 / 4 | — |
| Setup WNS / TNS | −0.522 ns / −31.641 ns | **完整布线**，canonical 源码（2026-10-22） |
| Setup 违例端点 | 213 | 同上 |
| Hold WNS / TNS | +0.019 ns / 0 | 同上 |
| 可发布 bit | 无 | bitgen 门槛拦截 |

注意：Slice/DSP 来自放置阶段，Setup/Hold 来自完整布线，两者不是同一次构建。面积修正后的版本只跑到放置，路由未完成，因此不能宣称该版本已闭合时序。

本板是全系统最先撞到资源墙的一侧。原因是它同时承担了 SDIO、FAT32、两套读流、图像流水线和完整菜单状态机，而这些模块的时序关键路径分散在 FAT 几何计算、链路序号进位和浏览器使能三个位置。

已尝试并回退的方向包括：FAT 几何分拍、FAT 最大簇捕获简化、链路序号 8/16 位分段进位、浏览器 WAV 捕获本地化、状态二进制编码。全部做过完整回归再进物理筛选，均未优于基线，canonical 源码保持原状。每个候选的终止原因和拥塞数据保留在 `build/timing-closure-next-20261022/` 的 `experiment-aborted.json` 中。

后续优化遵循**保留全部现有功能**的约束，结合等价逻辑重构和综合映射配置评估资源与时序。2026-10-26 的有效检查点已降至 **9379 / 9800 Slice（95.70%）**，布局 setup +0.218 ns、hold +0.059 ns；距 95% 目标仍差 69 Slice，最终布线尚未验证。源码等价依据、功能回归、淘汰的候选和复现步骤见 [本轮优化记录](../doc/media-area95-equivalence-2026-10-26.md)。

同日后续的逐模块分析把 `fat32_ro` 的 `u_maximum` 从 DSP 保持器改为普通触发器（`resource_fat_ff_hold`）：**9384 Slice（95.76%）**、布局 setup +0.399 ns、wire −7%；完整 `routability` 布线后 Setup 违例端点 **110**（此前 213）、TNS −22.864 ns、Hold 零违例。剩余违例集中在该模块内部且以 net delay 为主，WNS −1.792 ns 不能与 seed8 基线直接比较。分析与实测记录见 [时序与面积分析](../doc/media-timing-slice-analysis-2026-10-26.md)。

种子扫描（同参数同 RTL）：seed4 → 110 个违例端点 / TNS −22.864 ns；seed8 → 9316 Slice 但 527 个端点 / TNS −221.635 ns；seed12 布局 WNS 已为 −2.039 ns，未布线。**布局 WNS 不能预测布线 WNS，选种子必须看布线结果。** 进一步压缩 `fat32_ro` 比较逻辑的三种写法均触发 TD 6.2 崩溃，详见分析文档 §10.1。

---
````

### 原文件 `render/README.md`

````markdown
## 资源与时序

当前含饱和度版本（2026-10-28）已完成完整布线及Hold修复：M-Slice **4792/4900**、L-Slice **4801/4900**、总Slice **9593/9800**；Setup WNS **+0.052 ns**、Hold WNS **+0.021 ns**，TNS和违例端点均为0。综合LUT16426、寄存器12302；布线后LUT16886、寄存器12372；BRAM9K64/64、BRAM32K16/16、DSP29/29。现有资源、零违例和源码指纹门槛均通过，已生成render单板bit；media尚未签核，实板验收未执行。报告及bit位于根目录`build/saturation-zero/reports/final/phy/`，详见[本轮记录](../doc/dual-board/settings-saturation-2026-10-28.md)。

以下为新增饱和度前的历史记录，不代表当前资源结果：

| 项目 | 数值 | 来源与状态 |
|---|---:|---|
| Slice | **9,433 / 9,800（96.26%）** | 2026-10-25 完整布线 |
| LUT | 17,081 / 19,600 | 综合（2026-10-22） |
| 寄存器 | 12,305 / 19,600 | 综合（2026-10-22） |
| BRAM9K | 63 / 64 | 2026-10-25 布线 |
| BRAM32K | 15 / 16 | 同上 |
| DSP | 29 / 29 | 同上，已用满 |
| PLL | 2 / 4 | — |
| Setup WNS / TNS | **+0.105 ns / 0** | **零违例，通过** |
| Setup 违例端点 | **0** | 通过 |
| Hold WNS / TNS | +0.022 ns / 0 | 零违例 |
| Hold 违例端点 | 0 | 通过 |
| 可发布 bit | 无 | bitgen 门槛拦截 |

LUT 与寄存器数取自 2026-10-22 的综合报告，比 10-25 的布线版本早一轮（该轮 Slice 为 9,582）；两者相差在 150 Slice 以内，不改变结论。

**2026-10-25 完成 Setup/Hold 全零违例**，Slice 从 9,582 降到 9,433（−149）。达成手段是两处结构性改动，不是调 seed：

1. `frame_fifo_read_dual` 的 `App_rd_en` 从组合比较改为寄存控制，把 `issued` 比较器从高扇出 SDRAM 读使能路径里移走。
2. segment 长度计数器在普通突发时使用固定 `BURST_SIZE`，不再用可变 `target` 做宽减法。

这两处都保持了原有的突发目标、地址步进和返回字计数行为，改后跑了 `tb_sdram_read_contract` 和 `tb_frame_read_dual` 两个完整用例。

**但仍未出 bit**：构建脚本的 `QoR #RAMs ≤ 56` 门槛报告 78（63 BRAM9K + 15 BRAM32K）。这个 56 是人为阈值，不是器件容量——物理上限是 64 + 16。门槛没有放宽，所以流程停在 bitgen 之前。

资源结构值得注意：DSP 29/29 已用满，BRAM 63/64 + 15/16 接近满，Slice 96.26%。这意味着任何新功能都必须先在别处腾出空间，不存在"再加一点"的余地。

---
````

### 原文件 `doc/README.md`

````markdown
# 项目文档导航

[SD 卡 TXT 字幕与验收](dual-board/sd-subtitle-2026-10-11.md)

当前主工程为media/render双板系统，根目录[README](../README.md)是统一使用入口。当前工作树已加入协议1.10切图转场模式；最新资源占用见根README的[当前工作树资源统计](../README.md#当前工作树资源占用2026-10-21)。两板均已生成最终route资源和时序报告；当前物理时序均未签核。

## 当前双板文档

- [协议 v1](dual-board/protocol-v1.md)：真实字段、事务、ACK、音频流控和反馈。
- [实现与状态](dual-board/implementation.md)：板级分工、当前修复与验证边界。
- [实板验收](dual-board/hardware-acceptance.md)：功能恢复记录与后续专项测试。
- [矩阵键盘移植](dual-board/matrix-keypad-2026-10-08.md)：render 接线、分层接口、操作、验证与同功能资源对照。
- [设置与亮度](dual-board/settings-brightness-2026-10-08.md)、[图片对比度](dual-board/image-contrast-2026-10-08.md)：菜单、DDC/CI、全局回退与独立像素处理接口。
- [Text OSD](dual-board/text-osd-2026-10-08.md)与[完整源码说明](dual-board/text-osd-source-2026-10-08.md)：106字符编辑、事件归属、CDC及绘制。
- [BMP自动缩放](dual-board/image-scaling-2026-10-09.md)：格式、contain、采样、缓存、完成条件与验证。
- [ERROR 5修复](dual-board/image-scaling-repair-2026-10-09.md)：组合取消异步复位缺陷、负向复现、同步取消及构建状态。
- [GUI文字菜单恢复](dual-board/text-osd-gui-recovery-2026-10-09.md)：用户反馈、当前产物归档及完整菜单链路回归。
- [历史资源证据（2026-10-09）](dual-board/evidence/current-resources-2026-10-09.json)：当时两板GUI最终资源/时序与报告哈希；不代表当前转场工作树。
- 当前报告：[media最终资源](../media/MultimediaSystem_media_Runs/phy_1/MultimediaSystem_media_phy.area)、[media route时序](../media/MultimediaSystem_media_Runs/phy_1/route.qor)、[render最终资源](../render/MultimediaSystem_render_Runs/phy_1/MultimediaSystem_render_phy.area)、[render route时序](../render/MultimediaSystem_render_Runs/phy_1/route.qor)。
- [链路/SD 分析](dual-board/independent-link-sd-audit-2026-10-07.md)：实际 TEMAC 网表与 SD 启动死锁复现。
- [音频分析](dual-board/audio-pause-seek-audit-2026-10-07.md)：暂停、快进和单声道溢出的复现与修复。
- [频谱条圆头](dual-board/spectrum-cap-2026-10-31.md)：80 根玻璃条顶端由 2 阶切角改为 4 阶半圆，顶部两行高光与验证记录。
- [render 链路 CE 预寄存](dual-board/render-link-ce-timing-2026-10-31.md)：125 MHz 字头预取 CE 改为寄存预测，违例端点 50→2、行为等价比对。
- `dual-board/evidence/`：有效联合回归结果与修复前复现；`baseline.sha256.json` 用于保护单板源码基线。
- `dual-board/release-pair.json`：早期构建的历史指纹与签核数据。

2026-10-09 GUI恢复包保留为历史交付资料；其下载哈希与编译前输入指纹未核实。旧keypad/text_osd/bmp_scale构建按日期查阅，bmp_scale_release已撤回烧录推荐。物理资源、工具签核、实板功能恢复和长期测试属于不同证据，详见根README。

## 单板与参考资料

- [单板技术说明](single-board/README.md)：原单板架构、素材、模块与按键；文中源码路径按仓库根目录解释。
- [Goertzel 频谱设计](single-board/spectrum-goertzel.md)：现有算法的实现说明。
- `single-board/history/`：明确标记日期的旧时序分析，供技术对照。
- [FAT32 来源](reference/fat32-sources.md)：实现来源及许可证说明。
- `reference/board-support/`：原始板卡资料摘录、原图与引脚/寄存器文本；不参与构建，实物 PHY 已确认为 RTL8211E。

板级 `media/doc/`、`render/doc/` 保留独立工程所需的协议、实现、实板状态和历史构建证据。media 的 GUI/资源优化旧记录归到 `media/doc/history/`，对应指标只适用于当时输入。

已清理拆板前的重复实现计划、被替代的链路修正记录、旧会话记忆、一次性脚本和 ModelSim 工作库。正式 RTL/IP/约束、工程文件、测试素材和板级编译产物保留；根目录旧综合报告/数据库归到本机 `log/single-board/`，不纳入 Git。
````

### 原文件 `release/First_Release_8a46c85/README-签核说明.md`

````markdown
# 两板首次完整签核版（media + render 零违例）

- **对应提交**：`8a46c854ec4fc0419b9fdffc7cf28bbcd088cb5b`（短号 `8a46c85`，"两板终于都违例为0了！"，2026-10-30 22:41）
- **工具**：Tang Dynasty 6.2.168116，器件 EG4S20BG256，协议 v1.14
- **签核门槛**：Setup/Hold WNS ≥ 0、TNS=0、违例端点=0、资源不超容量、`check-reports.ps1` 通过（含输入指纹与 bit SHA）

## 烧录文件

| 板 | 文件 | SHA256（前 8 位） |
|---|---|---|
| media | `MultimediaSystem_media_50MHz_8a46c85.bit` | `bea01982` |
| render | `MultimediaSystem_render_100MHz_8a46c85.bit` | `331a300b` |

完整校验和见 `SHA256SUMS.txt`。

## 签核数据

| 指标 | media（50 MHz 总线） | render（100 MHz） |
|---|---:|---:|
| Setup WNS / TNS / 端点 | +0.081 / 0 / 0 | +0.052 / 0 / 0 |
| Hold WNS / TNS / 端点 | +0.024 / 0 / 0 | +0.021 / 0 / 0 |
| Slice | 9441（96.34%） | 9593（97.89%） |
| BRAM9K / BRAM32K / DSP | 49 / 5 / 25 | 64 / 16 / 29 |

## media 本版要点（相对此前 100 MHz 版本）

- bus_clk 100 → **50 MHz**；SD 分频同步改为 DIV_FAST=1，**SD_CLK 仍为 25 MHz**（读卡带宽与采样点不变）
- RTL：`db_link.v` 描述符 RAM 输出寄存一拍；`fat_wav_controller.v` `want_stop` 预寄存
- 影响面：仅内部解码/打包时钟减半（对 SD 读有 10 倍余量）；协议、按键、音频、字幕行为不变

## 复现命令

```
# media
./media/build/run.ps1 -Stage all -RunTag pv9s8 -AreaEffort medium -ShareArithmetic -MinRippleLength 16 -PlaceSeed 8
./media/build/check-reports.ps1 -RunDir ./media/Runs/phy_pv9s8

# render
./render/build/run.ps1 -Stage all -RunTag sat_zero_v2 -InferFsm off -AreaEffort high -PhysicalEffort medium -PlaceSeed 4
./render/build/check-reports.ps1 -RunDir ./render/Runs/phy_sat_zero_v2
```

> media 的物理配置里去掉了 `place post_place_opt high`（该参数在 76.92/45.45 MHz 下两次稳定 coredump），
> 实际运行配置见 `media/Runs/pv9s8/settings.cfg`；完整分析见
> `doc/dual-board/media-v4-closure-analysis-2026-10-30.md`。

## 验收状态

- 实板功能：用户已于 2026-10-30 确认两板可用
- 待办：完整双板回归（`run-regression.ps1`）、长期实板验收（大图加载时长、30 分钟混合轮播等）
````

### 原文件 `release/Second_Release_682b0ab/README-签核说明.md`

````markdown
# 第二次签核板（682b0ab）

源码提交：`682b0ab14712e401bc3ae345ef950a113dfae1f6`
分支：`双板v2_频谱圆头_CE签核`（基于首次签核版 `8a46c85`）
生成日期：2026-11-01

两颗 bit 均为该提交在工作树干净状态下重新构建的产物。TD 每次构建会把当前时间写进 bit 头部的 `Date:` 字段，因此 SHA256 与参照 bit 不同，但**载荷与 `Bitstream CRC` 位级别一致**，时序/资源逐项相同。

## 文件

| 文件 | 说明 | SHA256 |
|---|---|---|
| `MultimediaSystem_render_100MHz_682b0ab.bit` | render 板 | `529997e7ce0b0946e032b11fefcfca1afa55cd32f5bd612b1144b42ff070da3d` |
| `MultimediaSystem_media_50MHz_682b0ab.bit` | media 板 | `d3ffcf3e84d4086aede2ad323fb13ab6dc951ed6d04fe2f249807947421ca282` |

同目录附 `render_final.qor`、`media_final.qor` 与两板 `inputs.json`（构建输入指纹）。

## 时序与资源

| 指标 | render | media |
|---|---:|---:|
| Setup WNS / TNS / 违例端点 | +0.104 ns / 0 / 0 | +0.272 ns / 0 / 0 |
| Hold WNS / TNS / 违例端点 | +0.022 ns / 0 / 0 | +0.030 ns / 0 / 0 |
| Slice | 9,605 / 9,800（98.01%） | 9,402 / 9,800（95.94%） |
| BRAM9K / BRAM32K | 64 / 16 | 51 / 5 |
| DSP | 29 | 25 |
| Bitstream CRC | `01011` | `00101000110` |
| `check-reports.ps1` | QUALIFIED | QUALIFIED |

## 构建参数

render：

```powershell
./render/build/run.ps1 -Stage all -RunTag ce_rep `
  -InferFsm off -AreaEffort high -PhysicalEffort medium -PlaceSeed 6
```

media（先 syn，复制成 `_9`，再 phy）：

```powershell
./media/build/run.ps1 -Stage syn -RunTag final1msc `
  -AreaEffort medium -ShareArithmetic -MinRippleLength 16 -PlaceSeed 3 -NoPostPlaceOpt
Copy-Item -Recurse media/Runs/syn_final1msc media/Runs/syn_final1msc_9
./media/build/run.ps1 -Stage phy -RunTag final1msc_9 `
  -AreaEffort medium -ShareArithmetic -MinRippleLength 16 -PlaceSeed 9 -NoPostPlaceOpt
```

`-NoPostPlaceOpt` 必须保留（否则会追加 `place post_place_opt high`）。`phy` 的 `parent` 是 `../syn_final1msc_9`，因此要先复制综合目录；若换 RunTag，`phy` 的 tag 必须是 `<syn tag>_9`。

## 复现步骤

1. **准备源码**：克隆仓库并切到该提交，工作树必须干净（构建指纹会比对源码）。

   ```powershell
   git checkout 682b0ab14712e401bc3ae345ef950a113dfae1f6
   git status --short        # 输出为空
   ```

2. **环境**：TD 6.2.168116，单实例工具，构建前确认没有其它 TD 进程（`tasklist | findstr td_commands_prompt`）；两板不要同时构建。

   ```powershell
   $env:TD_ROOT='D:/AnLu_FPGA_environment'
   $env:MODELSIM_BIN='D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem'
   ```

3. **render**：执行上面的 render 命令，产物在 `render/Runs/phy_<tag>/MultimediaSystem_render.bit`。

4. **media**：按顺序执行 syn、复制、phy，产物在 `media/Runs/phy_final1msc_9/MultimediaSystem_media.bit`。

5. **签核校验**（必须用 pwsh 7）：

   ```powershell
   pwsh -NoProfile -File render/build/check-reports.ps1 -RunDir ./render/Runs/phy_ce_rep
   pwsh -NoProfile -File media/build/check-reports.ps1 -RunDir ./media/Runs/phy_final1msc_9
   ```

   两者都应输出 `QUALIFIED`，并核对 `final.qor` 的 Setup/Hold 为零违例、Slice 与上表一致。

6. **与包内 bit 比对**：`sha256sum` 会因 `Date:` 不同而不相等，应按载荷判断：

   ```powershell
   # 读 bit 头部（前 200 字节），应看到 Bitstream CRC: 01011 / 00101000110
   python -c "print(open('MultimediaSystem_render_100MHz_682b0ab.bit','rb').read()[:200])"
   # 或逐字节比较：只有 3 个字节不同，且都在 Date: 行
   cmp -l <参照.bit> <新.bit>
   ```

## 与参照 bit 的比对

| 板 | 参照 | 差异 |
|---|---|---|
| render | `render/Runs/phy_ce_s6/…bit`（`57ecdeae…`） | 仅 3 字节 `Date:` 字段；CRC `01011` 相同 |
| media | `build/fix-candidates-20261101/MultimediaSystem_media_SIGNED_FAST06_S9.bit`（`be40bb58…`） | 仅 3 字节 `Date:` 字段；CRC `00101000110` 相同 |

复现时请用 pwsh 7 运行 `check-reports.ps1`（Windows PowerShell 5.1 在 `ConvertFrom-Json -AsHashtable` 处会报错）。TD 为单实例工具，两板构建不要并发。
````

## README与源码核对记录（2026-11-01）

范围：主工程两板的全部RTL/头文件、主源清单、顶层实例及参数、ADC/SDC、厂商公开封装与IP依赖、构建/仿真入口、独立PRBS、转换工具与示例，以及12份相关README。加密IP不宣称可读其内部实现，ROM/原语映射按其调用及生成数据核对。原单板基线和历史试验生成的RTL不混入当前双板功能。

主要文档纠正：

- 首图自动加载，轮播默认关闭；SD DISPLAY/AUTO和本地Text OSD默认关闭。
- 十项设置含SATURATION，字幕容量256，UI快照296字节、字幕快照264字节；不再混用旧协议和旧菜单项数。
- media总线50MHz、SD初始化200kHz/读卡25MHz；render SDRAM/MAC TX为125MHz，像素75MHz、TMDS 375MHz。
- VGA仅为virtualIO，HDMI声音没有独立I2S/扬声器顶层输出；不能按旧文字推断实际物理接口。
- 图片同名WAV独立于字幕开关，补齐背景音乐恢复、配音循环/曲尾切图、矩阵9退出的完整语义。
- 补齐手动TXT、空文件、ASCII/BOM/TAB/首行及DISPLAY优先级，触发时间、三路应急顺序和本地时钟草稿。
- EMERG示例的B进入/C退出已失效，当前是GPIO高有效加C切换；WAV转换工具不能直接处理MP3。
- 两板db_link实现并非同一份逐字节副本；media实际重传约1ms，render约5ms，minor不构成严格兼容性拦截。
- 两帧共5,529,600字节，没有把8MiB SDRAM全部占满；不能据旧注释假定刷新最低优先级。
- 签核WNS门槛为0，RAM按9K/32K容量分别核算；移出所有旧资源/时序过程和旧试板烧录推荐。

发布证据核对：Second_Release_682b0ab两颗bit的SHA256与包内清单一致，最终QoR为media Setup/Hold +0.272/+0.030ns、9402 Slice，render +0.104/+0.022ns、9605 Slice，TNS/端点均0。这是固定发布构建，不等于此次文档变更重新跑过物理签核。render存档114项输入与工作区逐字节相同；media71项中69项相同，top_media.v和bmp_image_pipeline.v的原始字节哈希不同，后者LF规范化后匹配。当前这两文件与682b0ab的Git文本（统一换行）一致；top_media原始存档指纹差异不在本次修改范围，不将文本一致冒充严格指纹通过。

本次只修改Markdown，没有改RTL、IP、约束、工程、脚本、bit或发布SHA256清单。校验项目包括原单板基线/本地依赖审计、Markdown目标/锚点、示例BMP/WAV头部、发布bit哈希和git diff空白检查。运行了7项针对性仿真：tb_settings_menu（SharedKeys）、tb_text_osd_scroll、tb_emergency_timestamp、tb_keypad_router、tb_txt_prefix_parser、tb_audio_osd_layout、tb_calendar_clock；结果在本机build/readme-review/。未重新执行完整回归、综合/布局布线或实板长测。
