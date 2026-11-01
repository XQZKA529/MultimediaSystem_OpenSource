# 双板音频暂停、快进故障：本次独立代码分析与仿真

本次依据 RTL 和联合仿真定位，没有沿用以前排障记录的结论。现象是图片正常后，长按快进只卡顿，暂停时音频 OSD 与 ERROR 5 / WAIT DATA 闪烁。

## 复现的原因

1. **PCM 缺少基于实际播放位置的远端流控。** `seam_media` 只检查本地 512 帧 FIFO，能持续向网络发送；render 的环只有 2048 帧，包准入阈值为 1788 字。暂停或冻结后不再消费，后续 PCM 元数据在 `seam_render.rx_meta_ready` 等待空间。`db_link` 的业务接收按包串行，ACK 在应用完整接收后才产生，因此后面的 STOP / BEGIN / PAUSE / STATUS / 图片包一起被阻塞，PCM 重试耗尽后重建会话。

   旧代码暂停复现：`sent=5644 played=3208 ring=1962 rxop=21 ready=0`，随后会话重置。
   旧代码快进复现：SD 控制器已经跳转，`sent=243208`，render 仍在 `played=3208 ring=1962`，随后重置。也就是说，SD 的目标计算可以成功，但新的 STOP / BEGIN 没有送到播放端；重连恢复又使用旧的已播位置。

2. **冻结确认只有一次。** `db_audio_sink` 原先把 `freeze_pending` 作为 POSITION 的 bit 2，首次快照后清零；20ms 的后续反馈报 0。`seam_render` 在控制发送忙时合并反馈，可以把这一次确认覆盖。即使先修好 PCM 流控，单独延迟反馈发送两个周期仍能复现 `seeks=0 position=3287 seekwait=1 freeze=1`：播放端冻结了，发送端永远等不到确认。

3. **单声道突发预留不足。** 一个 16bit 单声道扇区解包成 256 个 `{L,R}` 字，两扇区产生 512 字，但 media 本地准入只预留 260 字。联合单声道测试复现本地 FIFO overflow。这与 SD 文件损坏无关。

## 修复

- `media/rtl/seam/seam_media.v`：按 `audio_sent - played_position` 限制所有已排队、在途和已接收的未播放帧，最大预留 1536 帧；每个新包保守预留 256 帧。减法和比较分成两拍，另外扣除两帧流水余量。新音频 epoch 同时重基发送位置和播放反馈位置，避免快进后使用旧基准。等待冻结期间停止排新的 PCM；每次 seek 只发一次执行脉冲。
- `render/rtl/seam/db_audio_sink.v`：冻结位置稳定后，每个 POSITION 都持续返回冻结状态，直到解除冻结或切换流，不再依赖一次事件。
- `media/rtl/media_core.v`：WAV 的非抢占 SD 突发改为最多一个扇区，使单声道与立体声都满足本地 260 帧 credit。根目录单板工程未改。

1536 帧约 32ms，超过 1024 帧开播预填；每 20ms 反馈对应 960 帧。接收准入阈值 1788 字还留有空间，暂停时不需要依靠无限延长链路超时维持控制通信。

## ERROR 5 与原图片

在 SD 已成功初始化的条件下，media 发出的诊断 5 来自 `fat_bmp_controller` 的图像探测/写请求/加载/提交等待超时，不是 WAV 格式错误码。链路重连会触发已显示图片重传；被 PCM 阻塞的控制与图片路径会导致这类超时。render 会在会话重置时清除本次 STATUS 有效标志，重新等待状态，因此可以交替显示诊断和 WAIT DATA。

音频 OSD 本来叠在已显示图片上：`render_core.rgb_base` 在 `image_display_valid` 有效时继续使用原图片，音频开始或暂停不清除已提交图像。修复通信后应保留背景图片与稳定的暂停 UI，消除异常诊断闪烁。

## 验证

新增 `tools/dual-board/tb_audio_system.v`：真实 WAV 解析/解包与 lba_stream、两端分别编译的生产 db_link、两端 seam、真实音频环和 PCM 输出。SD 扇区内容和 FAT 段表、MAC 字节传输使用模型。样本内容编码绝对帧号，检查实际输出的左右声道，不仅检查进度条。

仿真缩放采样/反馈与链路超时参数以缩短运行；保持真实 FIFO 深度、每个反馈周期 960 个样本和 240000 帧快进步长。暂停持续时间超过缩放后的重试预算；延迟场景阻塞 POSITION 发送超过两个反馈周期。

```powershell
& tools/dual-board/run-system.ps1 -Test tb_audio_system
& tools/dual-board/run-system.ps1 -Test tb_audio_system -Scenario 2
& tools/dual-board/run-system.ps1 -Test tb_audio_system -Mono
```

通过场景：长时间暂停/恢复、播放中 +240000 帧快进、暂停中快进与曲尾保留 1 秒的钳位、恢复后的 PCM 样本准确、控制反馈积压、单声道复制左右声道、未播帧预留不超过 1536、无会话重置、保留图片与 UI。结果见 `doc/dual-board/evidence/audio-system-*-mono*.txt`。

另外通过 `tb_audio_sink`、`tb_media_source`、`tb_media_sd_boot`、`tb_fat_wav_actual`、`tb_image_commit`，以及 128 字图像/UI 跨双链路测试和 `audit.py`（单板基线哈希未变，双板只依赖本地源码）。本次没有重新综合、布局布线或生成下载 bit；仍需重新编译 media 与 render 并上板验证。仿真没有验证 PHY 电气时序、真实 SD 卡或 HDMI 串行物理输出。


## 后续实板确认

2026-10-07 用户上板反馈：功能已全部恢复。本文保留本次独立分析和仿真证据；文中“尚未上板/编译”等表述描述排查当时的阶段，当前状态见 [实板记录](hardware-acceptance.md)。
