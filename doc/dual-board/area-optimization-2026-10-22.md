# 双板 Slice 面积优化记录（2026-10-22）

目标为 media/render 两板各低于 90% Slice，即每板不超过 8,819/9,800 Slice。现阶段保持双板功能、器件、约束、原签核门槛不变；未通过签核的流程不生成 bit。

## 菜单传播问题

`tb_text_osd_menu` 曾因 `seam_media.transition_mode` 在测试台未连接而得到高阻控制位。`ui_controls == ui_controls_frozen` 在仿真中因此为 X，快照 FSM 在每轮末尾丢弃有效快照并重新复制。补齐 file_browser 到 seam_media 的 transition mode 连线，并在测试台显式产生复位脉冲后，菜单打开/关闭 smoke 和完整的菜单、Text OSD、音量、时钟、断线重连用例均通过。media 侧保留了一个调度修正：纯控制字段变化只置 dirty，不提前宣告字符 RAM 已提交；实际页面提交或此前已提交的页面仍可触发快照。

完整回归日志：`doc/dual-board/evidence/text-osd-menu-system.txt`。测试台的 `MENU_SMOKE` 可单独执行菜单开关快检。

## 面积试验

| 板/试验 | Slice | 相对 90% 目标 | 综合/布局布线设置 | 结论 |
|---|---:|---:|---|---|
| media 优化前 RTL | 9,471（96.64%） | 多 652 | area_prior、FSM off、高强度 LUT 映射、seed 4 | 综合 LUT 16,572 |
| media BMP 头字段窄化（仅 w/h 13 位） | 9,306（94.96%） | 多 487 | area_prior、FSM off、高强度 LUT 映射、medium placement、seed 4 | 完整 BMP header/controller/SD boot/17 组 scale 像素对照通过；Setup −2.529 ns、Hold −0.044 ns |
| media BMP 头字段窄化（含压缩标志），seed 4 | 9,241（94.30%） | 多 422 | area_prior、FSM off、高强度 LUT 映射、medium placement | 综合 LUT 16,491、寄存器 10,549；Setup −0.756 ns、Hold +0.024 ns |
| media BMP 头字段窄化（含压缩标志），seed 3 | **9,239（94.28%）** | **多 420** | 同上，seed 3 | 完整 BMP header/controller/SD boot/17 组 scale 像素对照通过；Setup −1.456 ns、Hold +0.021 ns；原 bitgen 门槛未通过，未生成 bit |
| media BMP 头字段窄化（含压缩标志），seed 8 | 9,275（94.64%） | 多 456 | 同上，seed 8 | Setup −0.563 ns、Hold −0.025 ns；Hold 失败，不保留 |
| render 原基线 | 9,454（96.47%） | 多 635 | area_prior、默认综合映射、seed 8 | 综合 LUT 16,766 |
| render 高强度映射 | 9,390（95.82%） | 多 571 | area_prior、FSM off、高强度 LUT 映射、seed 8、medium placement | Setup WNS −9.651 ns，Hold +0.022 ns |
| render 高强度映射/高 placement | 9,276（94.65%） | 多 457 | 同上，high placement、seed 13 | Setup WNS −10.150 ns，Hold +0.022 ns；面积略降，时序变差 |
| render 字形坐标商/余数共享 | 9,260（94.49%） | 多 441 | 高强度映射、medium placement、seed 8 | 综合 LUT 15,998（较基线少 768）；Setup WNS −13.317 ns，Hold +0.027 ns |
| render 字形坐标商/余数共享，seed 4 | **9,164（93.51%）** | **多 345** | 高强度映射、medium placement | 综合 LUT 15,998；Setup WNS −9.518 ns，Hold +0.022 ns |

所有已完成试验仍高于 90%。render 当前最佳 Slice 为 9,164，media 为 9,239。media seed3 比 seed4 少 2 Slice，但 Setup 裕量差 0.700 ns；seed4 面积接近且时序更好，seed8 面积和 Hold 都更差。render 当前输入指纹在 `area_text_shared_current` 中重新综合和布局布线，得到同一结果：9,164 Slice、Setup −9.518 ns、Hold +0.022 ns，确认旧 seed4 结果与当前源码逻辑一致。两板都没有合格 bit：render 和 media 的 Setup WNS 都为负，原流程均按门槛停止在 bitgen。render placement seed1 为 9,193 Slice（93.81%），略高于 seed4；seed4 medium placement 仍是最佳。自定义 `/12` 为 `shift>>2` 后恢复除以 3 的结构少 67 个门级 LUT，但 placement 变为 9,176 Slice、Setup −6.647 ns，劣于恢复 `/12` 的 seed4 配置，已撤回。media 在 area_prior 下改用 one-hot 的综合结果为 17,320 LUT/10,702 Reg，劣于 FSM off 的 16,572 LUT/10,616 Reg；`map_mode=auto` 也会把 media LUT 增至 18,731，均已排除。render 用 high placement、seed 13 时面积为 9,318 Slice，较 seed4 多 154 Slice；高 placement 的 WNS 也更差。media high placement、seed 13 的初步结果为 9,268 Slice（94.57%），Setup −0.138 ns、Hold −0.041 ns；详细布线前 Setup 估算恶化至 −13.349 ns，已停止该试验，不能视为有效签核结果。媒体 file_browser 二进制状态编码虽通过菜单仿真，但综合 LUT 从 16,491 增至 16,650，已撤回。render SD 字幕接收器把 4 个逐字节 9 位算术判断改为字组/尾字节掩码后，像素/协议边界仿真通过但最终综合 LUT 不变，RTL 已撤回、1～4 字节合法负载用例保留。render 字幕右边界预寄存使 Slice 增至 9,203（93.91%）、Setup −10.324 ns，已撤回；窗口减法复用候选综合 LUT 减少 38，但最终为 9,185 Slice（93.72%）、Setup −10.018 ns，较 9,164 的当前最佳更差，已撤回。滚动末端的单调计数器改用相等判断虽通过像素/滚动仿真，但综合总 LUT 增至 12,959，已撤回。编辑器计数字符转换重写后 LUT 估算增加约 122，已撤回。

## 下一步

继续检查媒体 FAT/BMP 和 render HDMI/视频控制等大面积层级，测试能通过完整回归的结构优化；之后对有效方案重新综合、布局布线并逐板记录 Slice 与 Setup/Hold。当前还没有满足 90% 目标，也没有可签核的 bit。
