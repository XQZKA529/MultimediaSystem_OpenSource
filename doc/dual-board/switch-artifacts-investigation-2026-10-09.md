# 切图加载期间黑条与 HDMI 嗡嗡声排查

日期：2026-10-09。排查当前仓库源码；未更改生产 RTL、约束、原生工程或 bit。没有连接实板采集设备，以下区分代码事实、仿真结果与待验证假设。

## 用户确认的触发条件

- 已经有图片显示，按键切到下一张。
- 黑色横向闪烁条纹出现在等待新图加载期间，尚未进入交叉淡化。
- 没有播放 WAV。
- 嗡嗡声来自显示器或 HDMI 接出的音箱。

因此，淡化时双路读带宽与播放音乐时 PCM 断供都不能直接解释本次反馈。

## 当前结论

**尚未锁定实板根因。** 当前代码存在“旧图读通路欠载时输出黑像素”的明确机制，但本次并行读写仿真没有触发它。未播放音轨时，音频源向 HDMI 输出连续零值 PCM，生产频率下 ACR 正常；未找到切图发声或图像字直接进入 PCM 的正常代码路径。

需要优先观测 render 在图片接收/写入负载下的 HDMI 输出，包括协议核锁定、75MHz 到 375MHz 串化交接，以及实板时钟/供电/信号质量。该方向可以同时影响视频和 HDMI 音频，但目前仅为待验证假设。也不能排除黑条与音箱模拟侧供电/接地干扰是两个不同问题。

## 显示路径

`seam_render` 把新图写到当前显示缓存的另一张，完整帧、CRC 与实际写完成之前不会提交；加载期间视频域继续选择旧缓存。见 [seam_render.v](../../render/rtl/seam/seam_render.v)、[render_core.v](../../render/rtl/render_core.v)。

`rgb888_word_reader` 在有效视频区取不到解包 bank 时会输出 `24'd0` 并置位 `underflow_sticky`，因此欠载确实可能产生黑色片段。欠载时像素相位不推进，后续恢复还可能造成该帧像素位置偏移。见 [rgb888_word_reader.v](../../render/rtl/framebuffer/rgb888_word_reader.v)。

单路扫描时，这个 sticky 信号没有接到上屏错误或板上诊断输出。`mix_fail` 只在 `mix_lane1_en` 为真时反馈故障，因此“没有 ERROR”不能证明加载期间没有欠载。

读 FIFO 为 512 个 32 位字，每次补充 256 字；读调度器的 `read_urgent` 为图片写突发让路设了优先保护。图片写侧 `into_burst` 检查读占用/读忙，但没有检查 `Sdr_busy` 或 `Sdr_init_ref_vld`。这是应核查的接口风险，不能仅凭静态阅读判为本次根因：厂商控制器包含内部处理逻辑，下面的厂商控制器时序仿真已通过。见 [frame_fifo_read_dual.v](../../render/rtl/framebuffer/frame_fifo_read_dual.v)、[frame_fifo_write.v](../../render/rtl/framebuffer/frame_fifo_write.v)。

`video_read_ready` 已产生但没有被视频扫描时序使用，视频固定运行。这意味着实际硬件出现超过缓冲能力的延迟时，扫描不会等内存；需要通过欠载证据定位，而不能只看网络完整帧 CRC。

## 音频路径

音频走 `db_audio_sink → wav_play_glue → audio_ring_bram → audio_wav_pcm → hdmi_audio_driver`，使用 8KB BRAM。`sdram_app_arb` 生产实例 `ENABLE_AUDIO=0`，PCM 不使用图片 SDRAM。

`seam_render` 中图片 payload 为 kind 1，PCM 为 kind 3；`audio_push` 仅在 PCM payload 时有效。`audio_wav_pcm` 在未开播、暂停、欠载时仍按 48kHz 发 valid，并把样本设为零。没有切图提示音的实例或控制逻辑。见 [db_audio_sink.v](../../render/rtl/seam/db_audio_sink.v)、[audio_wav_pcm.v](../../render/rtl/audio/audio_wav_pcm.v)。

`hdmi_audio_driver` 把 PCM 和 ACR 接到加密 HDMI 核；核的 `video_locked` 仅作为内部线网，没有接到可见诊断。视频 AXI 的 `axis_s_ready` 也没有被上游消费。尚未证明加载时它们异常，建议一起采集。见 [hdmi_audio_driver.v](../../render/rtl/driver/hdmi_audio_driver.v)。

75MHz 像素与 375MHz 串化均由同一个 PLL 输出。`lane_lvds_10_1` 通过翻转标志安排 10 位字装载，数据总线直接跨入串化域；约束将这两个时钟设为 exclusive，相关跨域交接不能由 README 中的整体 WNS 数值证明安全。此处沿用厂商参考设计，**不是已确认错误**。见 [lane_lvds_10_1.v](../../render/rtl/driver/lane_lvds_10_1.v)、[render.sdc](../../render/constr/render.sdc)。

## 本次实际执行的验证

| 验证 | 结果 | 范围与限制 |
|---|---|---|
| `tb_audio_sink` | PASS | PCM 顺序、暂停、冻结、STOP、短 EOF、断线静音；采用加速节拍 |
| `tb_frame_read_dual` | PASS | 厂商 SDRAM 控制器时序、生产读 FIFO、真实解包/混合；4 个完整720p帧，含单/双路；没有并行图片写入 |
| `tb_switch_load_probe` | PASS | 125/75MHz，实际图片写 FSM、读 FSM、读 FIFO、厂商控制器与 arb；完整691200字新图写入与旧图扫描重叠，连续2帧像素/valid检查通过 |
| `tb_idle_hdmi_audio` | PASS | 75MHz生产音频链与 ACR，196对样本全零，间隔1562/1563拍，4次ACR，稳定CTS=75000、N=6144 |

并行加载探针使用恒定充足写 FIFO 水位，覆盖饱和写入压力；写数据为占位值，读像素由请求地址模型提供。厂商物理 SDRAM 仿真原语没有真实存储行为，因此这个测试验证的是请求/返回时序、FIFO供数与旧图扫描，**不验证实际 SDRAM DQ、物理写入数据完整性、网络接收、电源、PLL抖动、HDMI数据岛或串化输出**。

探针日志的 `low_water=0` 不能单独作为欠载证据：统计包含有效帧尾，而解包 bank 可能已持有最后像素；有效区所有像素均通过了 valid 和 RGB 检查。`write_refresh=0` 表示该仿真运行未观测到写 valid 与刷新 valid 重叠，也不能证明所有实板相位都安全。

证据与可复跑探针位于 [build/switch-artifact-investigation](../../build/switch-artifact-investigation/)：`probe.txt`、`silence.txt`、`tb_audio_sink.txt`、`tb_frame_read_dual.txt`、两个探针源文件与 `run.ps1`。

```powershell
./build/switch-artifact-investigation/run.ps1 -Test load
./build/switch-artifact-investigation/run.ps1 -Test silence
```

## 实板定位的最短判别路径

1. 在视频有效区捕获旧图 `pixel_valid`/欠载、FIFO水位、图片写使能、读写状态、`Sdr_busy/ref`。黑条同拍发生且 `pixel_valid=0`，才能确认读供数问题；若欠载始终为零，继续检查实际 SDRAM 数据与后端。
2. 在 HDMI 核输入处捕获 `audio_valid/left/right`、ACR CTS/N、`video_locked`、`axis_s_ready`，并与加载窗口关联。若 PCM 变为非零，回查是否误收 PCM_BEGIN/DATA；若 PCM 保持零而音箱发声，则优先检查协议核之后及音箱模拟侧。
3. 采用诊断固件，在保持原有读图/网络/SDRAM负载的情况下把 HDMI 视频固定为本地测试图，同时保持零值音频。如果故障依旧，能缩小到 HDMI 后端、时钟或物理链路；如果消失，继续分离帧缓存数据路径与后端输入时序。尚未生成或烧录此诊断固件。
4. 在相同图片/负载下进行 HDMI 线、显示器和两板独立供电的对照；通过复现差异定位物理环境。显示器静音只用于确认声音来自扬声器，不能单独区分数字音频错误和模拟干扰。

本次没有修改工作 GUI bit，也不建议以未经证实的忙/刷新门控修改替换已工作的版本。先增加诊断可观测性，再按捕获证据修复。
