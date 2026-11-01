# GPIO 方向警报与 C 键警报（2026-10-14）

本版在用户已实测功能正常的 request3 试板版本上增加本地警报来源与组合显示。协议仍为 1.8。media 使用原试板 bit，render 重新构建；正式签核与试板状态分开记录。

## 接线与操作

| render 板输入 | 排针位置 | FPGA 引脚 | 含义 |
|---|---|---|---|
| GPIOB0 | J2 第 1 脚 | P4 | 高电平显示左箭头 |
| GPIOB1 | J2 第 2 脚 | N4 | 高电平显示右箭头 |

两个输入配置 LVCMOS33 和下拉，默认低电平。使用 0/3.3 V 信号并与 render 板共地；不能直接输入 5 V。J2 第 30 脚为 GND、第 29 脚为 3.3 V，可按板卡排针标记接线。引脚依据 `doc/reference/board-support/gpio_header_dump.txt`。

GPIO 双级同步后，连续 100000 个 100 MHz 总线周期稳定才确认变化，约 1 ms；短于此时间的高、低毛刺均被忽略。C（键编号 11）在按下沿切换键盘警报，松开后才能再切换；B（编号 7）本版无动作。键盘和 GPIO 在菜单、编辑、板间断线时均可触发。

| 当前有效来源 | 应急画面 |
|---|---|
| 无 | 正常多媒体（恢复完成后） |
| B0 | 左箭头 |
| B1 | 右箭头 |
| B0、B1 | 双向箭头 |
| C | 三角形感叹号 |
| C、B0 | 上方三角，下方左箭头 |
| C、B1 | 上方三角，下方右箭头 |
| C、B0、B1 | 上方三角，下方双向箭头 |

图形静态显示，黑底红图，白色顺序文字在下方。只显示仍有效的来源，来源解除后移除；再触发排到末尾。不同确认周期用 → 分隔，同周期用 = 分隔，例如 B0 = B1 → C。并列组内部按 B0、B1、C 排列。GPIO 回低解除该方向，C 再按解除键盘警报；只要仍有来源有效，就保持应急。

## 音频、恢复与异常

第一次触发保存原日常快照。SD 根目录的 EMERG.WAV 按实际消费曲尾循环，支持 48 kHz、16 bit PCM、单／双声道，应急数字音量固定 100%。新增、减少、重新排列来源不会重新保存快照、重启音频或重新发送应急进入事务。

最后一个来源解除后恢复原完整图片、原曲实际消费位置、暂停状态和轮播开关。恢复期间仍显示最后一幅应急画面；新来源触发立即取消恢复、重新接管，并沿用最初快照。帧界提交完整图案与顺序，不在一帧中混合新旧状态。

断线不清除来源和键盘锁存，画面保持，音频静音；重连恢复现有应急业务。render 系统复位清除 C 锁存，仍为高的 GPIO 再次通过稳定确认自动进入应急。缺文件、格式错误、读失败及 media 复位恢复限制沿用前版。

## 实现与验证

`emergency_inputs` 用三位来源集合和最多三个三位并列组记录有效顺序；`emergency_controller` 仅根据集合是否为空控制进入／恢复。完整画面状态通过稳定邮箱传入视频域，在最终应急层于 VS 结束统一提交。绘图层将坐标运算、图形／字形准备和最终 RGB 分为三个流水级，RGB 与 HS/VS/DE 同步延迟三拍。绘图和小字均由坐标比较、固定小字点阵生成，不增加 BRAM、帧缓存或音频格式，不改 RAM 预算。

media 主源码已与原实测试板包的构建输入逐项核对一致。原 media bit SHA256：
`ad0490e957e343f9eed3ec34169d67eb104ed869bb557465045a7caf501e0d47`。

原 media 保持修复后的最终双角报告 `MultimediaSystem_media_pr.timing`：Setup WNS -2.154 ns、TNS -94.329 ns，Hold WNS +0.024 ns、TNS 0；Slice 98.91%，RAM 57。前版说明中的 Hold -0.052 ns 来自保持修复前的 `final_timing.rpt`；本版按修复后报告更正。用户已报告原包实板功能正常，此事实不等同于通过静态时序签核，也不代表本次新增 GPIO 已实测。

render 当前 `syn_emergency_gpio3` / `phy_emergency_gpio3_seed5` 已通过原签核门槛：Setup +0.103 ns、Hold +0.022 ns、TNS 0，9052 Slice（92.37%），51 BRAM9K + 5 BRAM32K = 56 RAM，15 DSP。bit SHA256：`c847d0109e92793554a61cf2a4b847686a79186810120e140d055d3aeceee548`。

七张完整 1280×720 应急帧通过逐像素／同步检查，独立检查器核对 6451200 像素、精确白色顺序字形及全部 25 种有效顺序布局。波形中的来源变化只更新画面，未改变业务 revision 或启动次数。控制器覆盖八种状态、六种先后顺序、同刻并列、部分解除／重新触发、键盘离线、抖动、原快照保留、预填、断线与系统复位。

完整回归 **52 项全部通过**，记录见 `doc/dual-board/evidence/emergency-regression.json`，包含本轮两板输入指纹及所有 PASS 日志 SHA256。七帧绘图测试在源码、测试台、日志和帧文件 SHA256 一致后复用证据，其余回归全部重新运行。

配套交付：[GPIO 应急两板试板包](../../build/emergency-gpio/release_emergency_gpio3_seed5.zip)，SHA256 清单和完整源码包含在包内。media_TESTED.bit 与此前已实测文件逐字节一致，已有该版本 media 的板子只需更新 render_GPIO.bit。实板仍需覆盖全部组合、按顺序逐个解除、至少 20 次进入／恢复及 10 分钟应急播放。

## 复现

```powershell
./render/sim/run.ps1 -Test tb_emergency_controller
./render/sim/run.ps1 -Test tb_emergency_overlay
python ./tools/dual-board/check-emergency-gpio-frames.py
./tools/dual-board/run-emergency.ps1 -ReuseOverlayEvidence
./render/build/run.ps1 -Stage syn -RunTag emergency_gpio3
./tools/dual-board/run-area-physical.ps1 -Board render -SynthesisRunTag emergency_gpio3 -RunTag emergency_gpio3_seed5 -PlaceSeed 5 -PhysicalEffort medium
./tools/dual-board/package-emergency-gpio.ps1 -RenderRunTag emergency_gpio3_seed5
```

已存在的构建／交付目录不能覆盖，复现需选择新的 RunTag。`-ReuseOverlayEvidence` 只复用绘图源码、测试台、PASS 日志及七张完整帧的 SHA256 均一致的证据；其他回归全部执行。保留文件检查、基线审计、签核和打包检查均不降低门槛。
