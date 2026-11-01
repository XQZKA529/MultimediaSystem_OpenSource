# render：帧缓存、图层合成与 HDMI 音视频

原生工程 [MultimediaSystem_render.al](MultimediaSystem_render.al)，顶层 [top_render](rtl/top_render.v)，器件 EG4S20BG256。本目录自带 RTL/IP/约束，可独立构建；SD、BMP/WAV/TXT 文件解析和主菜单状态由 media 提供。系统操作见[主 README](../README.md)与[速查](../README-dual-board.md)。

## 顶层结构

```text
top_render
├─ board_sys_pll / video_pll / board_reset / reset_sync
├─ db_ethernet + db_link              千兆 MAC / 可靠链路
├─ seam_render                       对象接收、校验、控制与反馈
├─ db_audio_sink → wav_play_glue / audio_ring_bram / audio_wav_pcm
├─ tm1650_keypad → keypad_event_encoder → text_osd_event_router
├─ text_osd_controller               本地文字模型
├─ calendar_clock                    本地日期时钟及编辑草稿
├─ emergency_inputs / controller / view_cdc
└─ render_core
   ├─ frame_read_write / frame_fifo_read_dual / frame_fifo_write
   ├─ sdram_app_arb → sdram           双帧与显示优先仲裁
   ├─ video_timing_data / rgb888_word_reader ×2
   ├─ mix_alpha_ctrl / mix_transition_ctrl / pixel_mixer
   ├─ contrast_adjust / saturation_adjust
   ├─ error_overlay / image_overlay_64 / ui_text_overlay / font_rom
   ├─ db_audio_model / audio_osd_overlay / audio_goertzel_osd
   ├─ sd_subtitle_view / text_osd_view_cdc / text_osd_overlay
   ├─ volume_view_cdc / volume_hint_controller / volume_overlay
   ├─ audio_volume_gain / brightness_scale
   ├─ emergency_overlay / clock_view_cdc / clock_overlay
   └─ hdmi_audio_driver → video_to_axis / ACR / HDMI核 / hdmi_phy
```

PCM 播放环位于顶层 `db_audio_sink` 内，不在 render_core/SDRAM 内；图像缩放在 media，render 接收固定 720p RGB888 帧。

## 时钟、引脚与输出

| 时钟 | 频率 / 用途 |
|---|---|
| `sys_clk` | 50 MHz 外部输入 |
| `clk` / `bus_clk` | 100 MHz，业务、链路总线、输入与日历 |
| `mem_clk` / `mem_sft` | **125 MHz**，SDRAM/MAC TX 与相移时钟 |
| `tx_clk_90` | 125 MHz 相移，RGMII TX |
| `rgmii_rxc` | PHY 125 MHz 接收 |
| `video_clk` | 75 MHz，像素/音频采样与合成 |
| `video_5x_clk` | 375 MHz，TMDS 串行化 |

两组 PLL 均锁定才释放板级复位，各域同步释放。TM1650 SCL/SDA 为 J12/K14（J2 pin31/pin33，外部上拉 3.3V）；应急 GPIOB0/1 为 P4/N4（J2 pin1/pin2，内部下拉），输入 0/3.3V 并共地。矩阵 IIC 与 HDMI DDC 独立。

HDMI 固定 1280×720，行前肩/同步/后肩=110/40/220，场前肩/同步/后肩=5/5/20，正极性，总时序1650×750，场频约60.606 Hz。HDMI 使用 TMDS 和数据岛音频，ACR N=6144、CTS 按实际采样脉冲生成。EDID 触发固定为0，外部 DDC 由 DDC/CI 独占。

VGA RGB/HS/VS 虽有顶层端口，但 [render.adc](constr/render.adc) 全部约束为 **virtualIO**，是观察信号，未连接物理 VGA 接口。没有独立外接扬声器/I2S 输出端口，声音从 HDMI 接收设备输出。

## SDRAM 与图片事务

| 缓冲 | 32 位字起始地址 | 字数 / 字节数 |
|---|---|---|
| BUF0 | `0x000000` | 691200 / 2764800 |
| BUF1 | `0x0A8C00` | 691200 / 2764800 |

两个缓冲共 5,529,600 字节，占 8 MiB SDRAM 的一部分；并非“8 MiB 已全部用尽”，但容不下两张完整 1080p RGB888。每行 960 字，4 像素/3 字紧凑 RGB888，写地址垂直翻转以恢复 BMP 行序。音频不占此 SDRAM。

接收 `IMG_BEGIN` 后分配非显示缓冲，READY 后按顺序/偏移和 FIFO 信用接收 DATA。END 的整帧 CRC32 与完整字数通过，并确认实际写完成，才向视频域申请转场。显示读请求优先于写入、尊重控制器刷新/忙状态；双路读按 FIFO 占用调度，返回计数完成后才结束突发。

转场过程为：帧界启双路 → 30 帧推进 → 完整新图帧 → 切单路 → 安全退役旧读者 → 提交显示索引 → 回复 PRESENTED。动画期间禁止写两张缓存；欠载等失败退回旧显示并报错。断线取消部分加载，已经进入有效转场的事务继续完成。

| 模式 | 实现 |
|---|---|
| FADE | RGB888 交叉淡化，alpha 0–256 |
| SMOOTH SLIDE | 预定义减速位移，重排 SDRAM 行读地址形成上推 |
| GRID DISSOLVE | 8×6 网格、每格160×120，固定延迟与收缩/混合 |
| RANDOM | 64项固定表选上述效果并循环，不是真随机 |

模式在发起视频域转场时锁存；第一张图片从黑底淡入。没有 Gamma 校正，也没有额外第三帧缓存。

## 图层、菜单与画面调节

实际像素链顺序：

```text
图片混合 → 对比度 → 饱和度 → 诊断 → 64×64台标 → 菜单
→ 播放卡片/频谱 → 本地文字或SD字幕 → 音量提示 → 软件亮度
→ 应急图层 → 日期时钟 → HDMI
```

每级同时延迟 RGB/HS/VS/DE。菜单、文字、字幕、时钟和图层通过冻结邮箱/双银行存储在视频帧界更新；不同视图独立提交，不应理解为全系统所有设置同一时刻原子生效。

- **对比度**：0–200%、每步10%，默认100%，以128为中心、舍入饱和，0%中灰。位于所有UI之前，仅作用于图片和补边。
- **饱和度**：0–200%、每步10%，默认100%，亮度加色差缩放，0%灰度，100%原色。与对比度一样在VS结束更新参数。
- **亮度**：10–100%，默认100%；DDC/CI Get/Set VCP 0x10、读回验证，失败回退RGB缩放，约5秒重探测。开漏IIC支持时钟延展/错误恢复；软件亮度之后绘制应急与时钟，显示器DDC背光仍影响整屏。
- **菜单**：media发送296字节快照（flags、饱和度扩展字、288字节文本）；十卡主页及数值/文件/字幕/转场/间隔页面。Text OSD/CLOCK 编辑器由本地模型绘制，进入编辑需新快照和视频确认。
- **字体**：菜单/文字共享同步BRAM字库，四档覆盖率抗锯齿；诊断及其他图层也有专用行字模/ROM。`NOREG`不代表异步零延迟读，调用方需对齐像素流水。
- **台标**：RGB565、64×64、不透明，x=1200–1263/y=16–79；两块BRAM32K，PREPARE先隐藏，CRC通过后帧界COMMIT。设置、应急、诊断、断线隐藏，切图动画中固定不动。

## PCM、音量与频谱

`db_audio_sink` 接收 epoch/总帧数/起点/暂停配置，经8KiB BRAM环跨至视频域，通常预填1024帧，短曲EOF允许提前起播。`audio_wav_pcm` 用75MHz累加器形成平均48kHz节拍，消费成功才推进位置；暂停/冻结保留预取，欠载/断线输出静音而采样时基不停。约20ms反馈epoch、实际消费位置和状态，冻结另有稳定确认。

`audio_volume_gain` 对内部24位样本施加0–100%增益、每步5%，样本间平滑收敛；应急已确认音轨走100%数字增益，恢复阶段静音，不修改日常音量。音量提示显示约2秒、20格，菜单/诊断/断线时抑制。

播放卡片位于 **x=8/y=88、136×52**，显示 `MM:SS / MM:SS`、实际消费进度及播放/暂停图标，时间显示上限99:59。底部频谱位于x=0/y=624、1280×88，**80根**、每格16像素/条宽12像素，四行圆头、顶部高光和半透明玻璃色。

实际分析器为 `audio_fft_osd.v` 中的 **audio_goertzel_osd**：12频点、256样本块、三角窗、分时递推、帧间峰值/衰减；80根是12带插值，不是80带FFT。输入取用户音量增益前PCM，暂停保持柱高。播放卡片与频谱只在正常播放场景显示，菜单/应急/诊断/断线/被判全黑的背景场景隐藏。

## 三种文字来源

本地 Text OSD 保存最多256字符，初始为空且OFF，提供A–Z、SPACE、DEL、CLR、ON/OFF；`2/8/4/6`移动、`5`执行，编辑器显示末尾预览和计数。退出/切图/链路重连/media复位不清本地文字，render系统复位清空。

SD字幕经264字节快照接收，双bank、字符检查、revision/session和视频APPLIED确认。DISPLAY开时选SD缓存，关时回本地文字；AUTO字幕必须绑定当前image ID且未在转场中，手动字幕不绑定图片。SD内容解析/自动匹配/状态归media，render不读TXT文件。

主屏文字统一位于y=64、x=192–1087的896像素窗口。74字符以内居中；长文本每两帧左移1像素、首尾各停61帧后循环，裁剪文字与暗边。菜单/诊断/应急隐藏主屏字幕，编辑页仍显示本地文字编辑器。

## 日期时钟、输入与应急

`calendar_clock`在100MHz域计秒，默认2000-01-01 00:00:00，范围2000–2099，大小月/闰年/世纪回绕；没有RTC与掉电存储。两行日期时间常驻左上角，所有场景可见，media复位/断线/播放操作不清零。

CLOCK草稿进入时取当前时间，实际时钟继续走；2/8选YEAR/MONTH/DAY/HOUR/MINUTE/SECOND/APPLY，4/6循环增减，APPLY上的5提交并清亚秒。年月改变钳位日期；退出/应急/连接或输入取消丢弃草稿，已应用值保留。

`tm1650_keypad`负责开漏IIC、轮询与稳定判定；事件编码器产生按下/松开/方向连发/取消，方向500ms后150ms连发。普通事件经可靠控制通道交media；Text OSD/CLOCK编辑留本地。矩阵物理布局与操作见速查，关窗9走现有PCM_STOP通路停止音轨。

应急由GPIOB0/1（约1ms高低稳定确认）和C按下切换锁存三路组成。有效来源显示红色箭头、感叹号或组合，白字顺序行按同周期`=`、先后`→`排列；每路固定保存触发日期时间，解除移除、重触发更新时间。输入层即使菜单/断网仍可本地触发。

`emergency_controller`冻结并保存显示/实际音频位置快照，与media以revision/epoch协调应急播放和恢复；来源增减不重复覆盖日常快照，恢复中重触发复用它。最后来源解除后帧界恢复原图，等音轨恢复/预填或明确失败状态才释放普通操作；缺音频静音保留警报图。`emergency_view_cdc`一起提交图形、顺序与触发时间。

## 构建、仿真与诊断

从仓库根目录、PowerShell7执行：

```powershell
$env:TD_ROOT='D:/AnLu_FPGA_environment'
$env:MODELSIM_BIN='D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem'
pwsh -NoProfile -File ./render/build/run.ps1 -Stage all -RunTag local -InferFsm off -AreaEffort high -PhysicalEffort medium -PlaceSeed 6
pwsh -NoProfile -File ./render/build/check-reports.ps1 -RunDir ./render/Runs/phy_local
pwsh -NoProfile -File ./render/sim/run.ps1 -Test tb_sdram_read_contract
pwsh -NoProfile -File ./render/sim/run.ps1 -Test tb_mix_transition
pwsh -NoProfile -File ./render/sim/run.ps1 -Test tb_saturation_adjust
pwsh -NoProfile -File ./render/sim/run.ps1 -Test tb_text_osd_scroll
pwsh -NoProfile -File ./render/sim/run.ps1 -Test tb_audio_osd_layout
pwsh -NoProfile -File ./render/sim/run.ps1 -Test tb_calendar_clock
pwsh -NoProfile -File ./render/sim/run.ps1 -Test tb_emergency_timestamp
pwsh -NoProfile -File ./render/sim/run.ps1 -Test tb_tm1650_keypad
```

CLI默认area_prior、InferFsm=off、AreaEffort=high、PhysicalEffort=medium、seed4；上例显式seed6。GUI打开本板.al并Reset Syn/Phy，输出在`MultimediaSystem_render_Runs/`；CLI在`Runs/`，不能混用报告。维护sources/modules后用-Stage project重建入口。签核要求Setup/Hold WNS≥0、TNS/端点=0、资源不超容量和输入指纹一致；BRAM9K+FIFO9K≤64、BRAM32K≤16。

完整用例与 -UiCase/-ClockCase/-FrameDir/-PhysicalSubtitleRam/-PhysicalOverlayRam 等参数见[sim/run.ps1](sim/run.ps1)。用例覆盖对象提交、abort、双路读、转场、文本CDC/滚动、音量、时钟/应急和TEMAC。发布资源/时序见[固定配对说明](../release/Second_Release_682b0ab/README-签核说明.md)，历史优化过程见[开发记录](../doc/dual-board/development-history.md)，不将旧结果作为工作树签核。

LED1逻辑值为`~display_valid`，`DBG_BMP_LOAD_DONE=display_valid`；`DBG_LINK_UP`与`DBG_LINK_EVENTS[0/1/2]`分别表示链路及保持到复位的重传/拒绝/丢弃事件，后者部分来自RX时钟域，不能据此直接计量总线事件率。`DBG_EMERGENCY_MODE/STATUS`反映应急状态。以上调试口和VGA观察信号按ADC为virtualIO，ChipWatcher调试构建需独立验收。PRBS入口见[diag](diag/README.md)。

实际源文件清单为[build/sources.txt](build/sources.txt)，未引用的兼容模块不等于已启用功能。模块与资源原语归属见[源码索引](../doc/dual-board/source-map.md)。
