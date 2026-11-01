# CLOCK 首图 ERROR 5：图片接收时序恢复试板

本轮用户反馈：两板 CLOCK_TRIAL 配套下载后，启动始终没有正常图片，黑屏一段时间后显示 ERROR 5，其他功能正常；原包正常。用户授权尝试修改对应时序违例。交付本轮接收时序修改版后，用户确认“当前版本可行”：记录为实板功能已确认、此前图片问题已恢复。失败配对和原 GPIO 包保留；长期混合播放、20 次设置/应急进出及参考时钟误差尚未单独记录，具体根因仍未独立确认。

## 局部修改

生产逻辑只修改 `render/rtl/seam/seam_render.v`。原 render −0.551 ns 路径从 `u_link/u_receive/header_q[74]` 经 `pkt_header[90]`（offset[26]）通向 `u_seam/payload_kind[3]`，包含八级逻辑。UI 快照和应急状态包在握手接受时仍直接检查原始 offset，绕过了现有元数据寄存阶段。

在现有预检查阶段增加 `checked_ui_payload` 和 `checked_emergency_status`，分别寄存长度及偏移有效性。接受包时使用这些结果，移除从原始 offset 到负载归属优先选择树的直达组合路径。沿用元数据稳定保持、预检查及准入握手，不增加日期网络字段，不改变包长度、超时、图片 CRC 或图片事务状态。两板协议仍为 1.9。

media 源码和 bit 保持与失败 CLOCK_TRIAL 配对相同，便于对 render 接收路径作隔离试验。media 仍有 −2.413 ns Setup 违例，不把本轮视为完整时序修复。局部修改和重布局结果不能单独证明实板根因。

## 验证范围

本次运行八次针对性检查：图片写入/CRC/提交/跨域所有权；UI 快照；双板应急及丢包重传；双板 CLOCK 菜单；新增元数据边界检查；完整 720p 图片缩放和可靠链路传输；图片与音频并行；实际 FAT/字幕及恢复。

新增边界检查覆盖 offset[26]=1 的非法 UI 快照、非法长度、非法应急状态偏移和长度，确认不更新 UI、不产生应急回复；合法应急状态及后续合法 UI 仍正确处理。完整图片测试核对 691200 个打包 RGB888 数据字及后端反馈。之前 124 次回归保留为父版本仿真记录，本次不声称重复了完整回归，也不把父版本仿真通过视为实板图片通过。

## 最终候选与时序

选用 `clock_rxfix_v1_high8`（high / seed 8）。同源码的 seed 6 候选 Setup WNS 为 −1.865 ns、TNS 为 −176.799 ns，较差，不用于本轮推荐下载。

| render 最终结果 | 失败父版本 | 本轮候选 |
|---|---:|---:|
| Slice | 9492（96.86%） | 9577（97.72%） |
| Setup WNS | −0.551 ns | −0.380 ns |
| Setup TNS | −2.264 ns | −4.380 ns |
| Setup 违例端点 | 11 | 21 |
| 总线域 Setup WNS | −0.551 ns | −0.168 ns |
| Hold WNS | +0.021 ns | +0.022 ns |
| Hold TNS / 违例端点 | 0 / 0 | 0 / 0 |

原包头到负载分类路径不再是负裕量路径；本轮总线域七个违例端点已由最终报告完整列出，主要为可靠链路 peer_age 更新及字幕控制路径。整体 WNS 改善，但 TNS 和违例端点数变差，不能把这一候选描述为全工程时序改善。BRAM9K=51、BRAM32K=5、DSP=15、PLL=2，与父版本一致；资源在物理容量内。

media 沿用 `clock_v1_medium3` 的同一 bit：Slice 9707，Setup WNS −2.413 ns / TNS −638.324 ns，956 个 Setup 违例端点；Hold WNS +0.022 ns，Hold 零违例。两板均未正式签核。用户已确认本轮版本可行；这一功能恢复结果不证明时序违例已全部解决，也不单独确认实板根因。

配套包位于 `build/clock-rx-timing-fix/release_clock_rx_timing_trial.zip`，包含两板 bit、源码、八次针对性检查日志、最终报告及 SHA256；原 CLOCK_TRIAL 和原 GPIO 包保持原样。

## 实板操作

1. 当前已使用配套 CLOCK_TRIAL 1.9 时，只更新本轮 render bit；media 无需再次下载。
2. 当前已回退 GPIO 1.8 时，必须一起下载本轮包中的两块 bit；不能混用 1.8/1.9。
3. 使用同一 SD 卡和正常素材，断电冷启动，记录是否出现首图、出现时间及 ERROR 5 是否消失。核对连续切图、设置、时钟及应急恢复，至少 30 分钟混合播放。
4. 若仍失败，保留这对 bit 指纹及现象，继续区分首图探测、READY、数据写入、END/CRC、提交和 PRESENTED 的停滞阶段。不要通过增加超时或抑制 ERROR 5 作为修复。

本轮包为实板功能已确认、长期验收待完成的试板版本；正式资源与 Setup/Hold 检查保持原门槛。已交付 ZIP、bit、构建清单及 SHA256 保持原样，后续用户确认记录在 `build/clock-rx-timing-fix/release_clock_rx_timing_trial.hardware-status.json`，不改写交付时清单中的 pending 状态。
