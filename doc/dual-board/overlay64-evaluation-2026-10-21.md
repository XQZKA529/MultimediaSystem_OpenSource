# SD 64×64 小图叠加实现评估（2026-10-21）

## 实现范围

协议升级到 1.11。media 从 SD 根目录识别保留文件 `OVERLAY.BMP`，不把它加入普通播放或浏览列表；校验 BMP 头并把 64×64 BGR888 像素打包为 RGB565，经现有图片 FIFO、重传和 CRC 通道发送。读取错误、缺图、短文件或错误格式均不影响底图播放。应急/设置打断后会重试；render 侧事务错误触发一次重传，成功后恢复重试额度。

render 用两块 BRAM32K 保存 4096 像素，在完整长度和 CRC 正确后于帧界提交。小图固定显示在 x=1200–1263、y=16–79；不透明，固定在画面上而不参与转场，只在正常播放和转场显示。全局亮度生效，图片对比度不作用于小图；诊断、设置、应急及断线画面隐藏。

## 仿真结果

| 用例 | 结果 | 覆盖 |
|---|---|---|
| media `tb_sd_overlay_controller` | 通过 | 4096 像素/RGB565 打包、缺图、错误尺寸、SD 读失败、截断、应急取消后重试、render 错误后一次重传 |
| media `tb_bmp_controller`、`tb_file_browser_overlay` | 通过 | 大小写不敏感识别/隐藏保留文件，普通图片目录不受影响 |
| media `tb_seam_overlay_tx` | 通过 | BEGIN/READY、2048 个 32-bit 字、CRC、8 KiB END 偏移和 APPLIED |
| render `tb_overlay_protocol` | 通过 | READY、4096 像素写入、BMP 行方向、CRC 成功提交、坏 CRC 不提交、链路/会话中断后旧事务不提交 |
| render `tb_image_overlay_64` | 通过 | RGB565、右上角坐标/边界、帧界提交、视频同步和隐藏条件 |
| 系统回归 | 通过 | SD 启动、设置菜单、应急 quick、转场、音频、字幕、对比度、音量用例 |

720p 完整 SD 启动压力用例未完成，不能据此声明所有计划中的系统组合均已跑完。示意画面见 [`preview_1280x720.png`](../../examples/overlay/preview_1280x720.png)；它用渐变占位底图展示坐标，并非板上截图。测试日志保存在两板 `build/evidence/`。

## 2026-10-22 上板问题根因与修复

上一轮先验证了 READY 不返回时控制器不释放 busy 的后果，并修正了仅凭本地 SD 读图器空闲就预占文件调度器的问题。该门控可以避免在主图尚未完成 PRESENTED 时提前占用存储，但它没有验证实际文件返回接线，不能充分解释小图始终不显示。此次继续定位发现 `overlay_file_*` 没有驱动、突发反压预留不足、快速重试的帧界请求相互抵消和取消 abort 被屏蔽等确定性问题，修复前均取得集成仿真失败记录；详见[当前根因报告](overlay64-data-path-fix-2026-10-22.md)。下面保留上一轮验证过程，其物理报告已被后续源码修改取代。

根因修订在 `seam_media` 导出 `image_transport_idle`，只在 render 已确认 PRESENTED 且没有活动 overlay 时为真；`sd_overlay_controller` 的启动条件和 `overlay_candidate` 的预留条件都改为等待该信号。仿真在 render 事务未结束时保持 overlay `begin_req=0`、`busy=0`；PRESENTED 后才开始，并通过 overlay 数据流回归，记录见 [`tb_sd_overlay_controller.txt`](../../media/build/evidence/tb_sd_overlay_controller.txt)。这样正常切图动画期间不再被 overlay 提前占用 SD 调度器。watchdog 仍用于真正的链路丢回应答故障，不承担调度修复职责。

先运行修复前复现：模拟 render 接受 `OVL_BEGIN` 后一直不返回 `OVL_READY`。500 个时钟周期后 media 控制器仍 `busy=1`、`load_done=0`，与主图切换和浏览器 busy 锁住的现象一致；复现日志见 [`tb_overlay_watchdog_before_fix.txt`](../../media/build/evidence/tb_overlay_watchdog_before_fix.txt)。

随后在 `sd_overlay_controller` 增加默认 25,000,000 周期（100 MHz 下 250 ms）的超时，覆盖等待 READY、SD 文件流无进展和等待 APPLIED。超时会取消协议/文件事务，失败后最多重试一次；再次失败则结束加载并释放 `overlay_busy`。验证见 [`overlay-watchdog-simulation.json`](../../media/build/evidence/overlay-watchdog-simulation.json)、[`tb_overlay_watchdog.txt`](../../media/build/evidence/tb_overlay_watchdog.txt) 和更新后的 [`tb_sd_overlay_controller.txt`](../../media/build/evidence/tb_sd_overlay_controller.txt)。当前修订已完成 media 综合和 route，但 Setup WNS −1.139 ns（565 个违例）、Hold WNS −0.006 ns（4 个违例），Slice 9352/9800（95.43%）；签核门槛失败，bitgen 被拦截。完整 QoR 见 [`final.qor`](../../media/Runs/phy_overlay_rootcause_20261022/final.qor)，本轮输入指纹和仿真摘要见 [`inputs_overlay_rootcause.json`](../../media/build/evidence/inputs_overlay_rootcause.json) 与 [`overlay-watchdog-simulation.json`](../../media/build/evidence/overlay-watchdog-simulation.json)。以下 10 月 21 日资源报告仅代表此前 source revision。

## 最终布局布线资源及时序

器件为 EG4S20BG256。资源数量在容量内；正式签核门槛仍是 Setup WNS ≥ +0.100 ns、Setup/Hold 违例为零。两板均未满足 setup 门槛，工具依原规则拦截 bitgen，因此**没有生成配套实验 bit，也不是正式签核版本**。

| 最终 route 指标 | media | render |
|---|---:|---:|
| Slice | 9421 / 9800（96.13%，余 379） | 9317 / 9800（95.07%，余 483） |
| LUT | 17270 / 19600（88.11%） | 16823 / 19600（85.83%） |
| 寄存器 | 10670 / 19600（54.44%） | 11602 / 19600（59.19%） |
| BRAM9K + FIFO9K | 58 + 0 / 64（余 6） | 60 + 0 / 64（余 4） |
| BRAM32K | 1 / 16（余 15） | 15 / 16（余 1） |
| DSP | 28 / 29（余 1） | 29 / 29（余 0） |
| Setup WNS / TNS | −0.891 / −48.259 ns | −9.367 / −321.958 ns |
| Setup 违例端点 | 218 | 220 |
| Hold WNS / TNS | +0.022 / 0 ns | +0.022 / 0 ns |
| Hold 违例端点 | 0 | 0 |
| Bitgen | 被门槛拦截 | 被门槛拦截 |

render 的 `image_overlay_64` 映射为 2 块 BRAM32K、0 DSP。LUT、寄存器、Slice 和分类型 RAM 均未超容量；render 的 BRAM32K 只剩 1 块，media 的 BRAM9K 只剩 6 块。Slice 利用率高于 80% 提示线。

## 构建来源

10 月 21 日最终 route 使用的输入清单 SHA256：media `B2834ECCD8D3B196D12C04CE7D40A97853B090EB7EF48F5C260144783D19393C`；render `1A0A6D1789E0086366CD3904643DC3A61ED4151E9138856AC77B5F5DFDECB495`。10 月 22 日 watchdog 修复后的 media 输入清单 SHA256 为 `A8549947E1D755BD9DEA94531AC2A6481157919B46CA1DCEE1F55BD2F3FA86D3`，见 [`inputs_overlay_watchdog.json`](../../media/build/evidence/inputs_overlay_watchdog.json)；它尚未经过物理构建。

- media 报告：[`final.qor`](../../media/Runs/phy_overlay64_release3/final.qor)、[`MultimediaSystem_media_phy.area`](../../media/Runs/phy_overlay64_release3/MultimediaSystem_media_phy.area)、[`MultimediaSystem_media_phy.ts`](../../media/Runs/phy_overlay64_release3/MultimediaSystem_media_phy.ts)、[`inputs.json`](../../media/Runs/phy_overlay64_release3/inputs.json)。
- render 报告：[`final.qor`](../../render/Runs/phy_overlay64_release/final.qor)、[`MultimediaSystem_render_phy.area`](../../render/Runs/phy_overlay64_release/MultimediaSystem_render_phy.area)、[`MultimediaSystem_render_phy.ts`](../../render/Runs/phy_overlay64_release/MultimediaSystem_render_phy.ts)、[`inputs.json`](../../render/Runs/phy_overlay64_release/inputs.json)。
- 两板机器可读资格状态：media [`qualification.json`](../../media/Runs/phy_overlay64_release3/qualification.json)、render [`qualification.json`](../../render/Runs/phy_overlay64_release/qualification.json)。它们记录 UNQUALIFIED、输入指纹匹配和 bitgen 被拦截。
- 资源门槛脚本仍要求 BRAM9K+FIFO9K ≤64、BRAM32K ≤16，并核查 Slice、LUT、寄存器和 DSP；Setup/Hold 条件未放宽。

替换 SD 卡上的小图需重新上电。两板必须一起升级协议 1.11；实板兼容性和画面验收待后续执行。
