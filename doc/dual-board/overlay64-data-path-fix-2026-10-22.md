# 64×64 overlay 数据链根因修复（2026-10-22）

本轮在真实 `media_core` 文件返回接线中复现了小图不显示的直接原因，并用真实双时钟、两板 seam 和厂商 BRAM32K 模型验证修订。之前验证 watchdog 和调度门控的测试没有经过实际文件返回接线，不能据此认定小图数据链已正常。

## 用户实测 bit 的对应证据

用户实际使用的是两板 `MultimediaSystem_*_Runs/best_result/` 下的 bit。本轮没有覆盖这两个文件。

| 板卡 | 文件时间（本地） | SHA256 |
|---|---|---|
| media | 2026-10-22 12:06:55 | `AB23CA3C8A51A7EB64BAB80FF7A1043B3C9267A998B5BA519C7253BD175FE210` |
| render | 2026-10-22 10:14:53 | `188F73F157CE77C1D6A7107AA4548C3AB57D4EB566DC9E2653E081470D288BA9` |

两个 bit 都与各自 `phy_1` 的 bit 哈希一致，`best_result/readMe.txt` 也指向 `phy_1`。media 的对应综合日志明确报出 `overlay_file_data[7]`、`overlay_file_valid`、`overlay_file_done`、`overlay_file_ok` 没有驱动，之后按工具规则把未驱动信号取 0。已保存[日志摘录](../../media/build/evidence/overlay_board_undriven_warnings.txt)和[bit 审计](../../media/build/evidence/overlay_board_bit_audit.json)。因此这次定位对应用户实测文件，而不只是一个人为丢 READY 的假设。

## 复现与修正

| 故障 | 修复前实际仿真结果 | 修正 |
|---|---|---|
| 文件返回未接通 | SD 已返回第 1 个字节，overlay 的 valid 仍不是 1；27,655 ns 立即失败 | 把存储服务 `stored_file_*` 返回连接到 overlay 输入，按当前所有者分发 valid/done |
| SD 突发没有容量预留 | 网络连续停顿 100 µs，已开始的 SD 突发在源文件第 6205 字节无法接收 | 最多 4×512 字节不可中断突发开始前，要求已有发送 FIFO 至少空闲 352 个 32 位字；不增加整张小图缓存 |
| 帧界隐藏请求相互抵消 | 坏 CRC 后在下一 VS 前立即 BEGIN，prepare 翻转两次回到原值，1 ms 后仍等 READY | 复用尚未确认的隐藏请求，按请求/确认相等完成；测试使用真实视频域确认 |
| 取消读操作被所有者 mux 屏蔽 | 会话取消同拍令 busy=0、file_abort=1，存储端看不到 abort | overlay 文件 abort 独立于 busy 选择器传递；render 会话替换同时清掉部分事务和待发送确认 |

修复前日志分别保存在：

- [文件返回断开](../../media/build/evidence/tb_media_overlay_e2e_unwired.txt)
- [突发容量不足](../../media/build/evidence/tb_media_overlay_e2e_no_reservation.txt)
- [隐藏请求丢失](../../render/build/evidence/tb_overlay_protocol_toggle_loss.txt)
- [abort 被屏蔽](../../media/build/evidence/tb_media_overlay_e2e_abort_masked.txt)

还修正了两处恢复细节：隐藏小图时同时消耗旧 commit，防止下一帧重新启用已取消的数据；共享 ERROR 只终结匹配的活动事务，overlay object 的最高位固定为 1，与主图 24 位 ID 分离。高像素 BRAM 的读口 reset 补齐显式接地。协议仍为 1.12，object 在线路上继续按不透明字段比较。

上一轮的 `image_transport_idle` 门控保留，用于避免主图尚未 PRESENTED 时提前占用 SD；watchdog 仅承担真正无应答时的恢复。

## 当前源码验证

`tb_media_overlay_e2e` 运行实际 FAT32、storage_service、media_core、RGB565 解码、media seam、render seam 和双时钟 sprite。厂商 BRAM 模式以 `EG_PHY_BRAM32K` 替换行为 RAM。初次事务核对完整 12342 字节、2048 个 32 位字、全部 4096 像素；随后覆盖会话重连、SD 负载中途取消、render 单独复位和 media 单独复位重挂 FAT，四次完成图像合计核对 16384 个小图像素。

每次扫描还核对区域外底图、DE/HS/VS；在 x=1184–1279、y=0–95 截取实际仿真像素。四张原始 RGB 图像 SHA256 相同：`6b16ee825ae48b2c7248947c2e5aa75b58741b71bcbe191366b7eec01791e534`。

![实际仿真输出的右上角 96×96 裁剪，最近邻放大四倍](../../media/build/evidence/overlay_simulation_crop_4x.png)

这张图来自仿真输出，不是板上截图。中心是 64×64 测试图，四边各 16 像素的底图对应窗口外保持不变。

| 验证 | 结果 |
|---|---|
| [集成文件到像素链，厂商 BRAM](../../media/build/evidence/tb_media_overlay_e2e_physical.txt) | PASS，四次加载与 16384 像素，含网络反压与两板独立复位 |
| [render 协议，真实双时钟和厂商 BRAM](../../render/build/evidence/tb_overlay_protocol_physical.txt) | PASS，CRC、立即重试、会话替换、取消后重新 BEGIN |
| [小图存储与绘制，厂商 BRAM](../../render/build/evidence/tb_image_overlay_64_physical.txt) | PASS，4096 像素、边界、同步、旧 commit 被取消后保持隐藏 |
| [overlay 解码控制器](../../media/build/evidence/tb_sd_overlay_controller.txt) | PASS，格式/读错/截断/超时/重试、事务空闲门控、object 命名空间 |
| [media 协议发送](../../media/build/evidence/tb_seam_overlay_tx.txt) | PASS，CRC、APPLIED、与已结束主图 ID 相同的 ERROR 正确分发 |
| [media SD 启动](../../media/build/evidence/tb_media_sd_boot.txt)、[应急集成 quick](../../media/build/evidence/tb_emergency_integration_quick.txt)、[render 主图提交](../../render/build/evidence/tb_image_commit.txt) | PASS |

复跑主要用例：

```powershell
powershell -ExecutionPolicy Bypass -File media/sim/run.ps1 -Test tb_media_overlay_e2e -PhysicalOverlayRam
powershell -ExecutionPolicy Bypass -File render/sim/run.ps1 -Test tb_overlay_protocol -PhysicalOverlayRam
powershell -ExecutionPolicy Bypass -File render/sim/run.ps1 -Test tb_image_overlay_64 -PhysicalOverlayRam
```

集成用例仅把“已有正常主图”作为环境前提，force media 的 `img_idle`、`display_valid`；没有 force 小图文件返回、有效信号或像素内容。SD 物理层由按请求返回扇区的模型代替，两板通过 seam 的 ready/valid 连接，未实例化 RGMII/可靠分包重传层。VS 周期被缩短以加速恢复用例，像素时钟与总线时钟独立。它不替代真实 SD 卡/网线/屏幕验收，也不是完整主图转场系统的画面测试。

## 综合与签核状态

两板已用当前源码完成 `syn_overlay_pathfix_20261022` 综合，输入清单与本轮证据一致。

| 综合资源 | media | render |
|---|---:|---:|
| LUT / 19600 | 16844 | 16722 |
| 寄存器 / 19600 | 10720 | 11558 |
| BRAM9K + FIFO9K / 64 | 58 | 60 |
| BRAM32K / 16 | 1 | 15 |
| DSP / 29 | 28 | 29 |

资源表是综合网表统计，不能代替最终 Slice 和布线时序。现有发送 FIFO 的突发预留没有新增 BRAM/DSP。报告为 [media gate.area](../../media/Runs/syn_overlay_pathfix_20261022/MultimediaSystem_media_gate.area) 和 [render gate.area](../../render/Runs/syn_overlay_pathfix_20261022/MultimediaSystem_render_gate.area)。源码指纹为 media `9D188FF56E6A6ADE5360272857A4EA600D7F99184BA84F812F0C22F58C560C79`、render `C8BCF037DB9B8AA79E2060A0F2E7E822C4E74B1309E3725CB6F9CB6256184CDA`。

本轮修改后尚未重新 route，没有生成新 bit。用户正在使用的旧 bit 的时序分别是：media Setup WNS −0.975 ns / Hold WNS −0.060 ns；render Setup WNS −10.614 ns / Hold WNS −0.025 ns。render 最差路径从 `pixel_x_cell` 到 `u_pixel_mixer/mixed_rgb_reg`，数据路径 23.595 ns，而 75 MHz 周期预算为 13.333 ns。这个时序问题仍需闭合；功能仿真通过不代表它已消失。正式 Setup WNS ≥0.100 ns、Setup/Hold 零违例门槛保留。

两份 `best_result` 旧 bit 不含本轮数据链修正，不能继续用来验收这些修订；两板源码需要配套重新构建。完整机器可读记录见 [overlay-pathfix-simulation.json](../../media/build/evidence/overlay-pathfix-simulation.json)，包含 bit 审计、输入指纹、日志哈希和验证边界。
