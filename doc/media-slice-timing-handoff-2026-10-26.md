# Media FPGA 面积与时序优化交接

更新时间：2026-10-26（Asia/Shanghai）

## 目标与当前结论

目标仍是优化 media 板 RTL 的 Slice/布线，并让最终 routed setup、hold slack 都大于 0。用户不要求额外的 +0.1ns 裕量。所有 PPA 对比固定 `seed 4`；本记录不把换 seed 当作优化方法。

当前源码匹配的最佳检查点是 **place-only 正时序**：

| 指标 | 结果 |
|---|---:|
| Setup WNS / TNS / 违例端点 | +0.090ns / 0 / 0 |
| Hold WNS / TNS / 违例端点 | +0.109ns / 0 / 0 |
| Slice | 9625 / 9800（98.21%）|
| Wire length | 1,340,662 |
| Top 1% tile utilization | 78% |

报告：[place.qor](../media/Runs/phy_endcrc_direct_seed4_nocritopt_placeonly_20261026/place.qor)。`inputs.json` 与当前 71 项输入逐项 hash 相同。

**尚未证明最终 routed 正时序。** 对应详细 route 在 setup 优化期间降到 SWNS -0.563ns、132 个端点；用户要求停止后，在第 51 轮、81 个 over-net 时终止。目录中没有最终 `*_pr.timing`、`final.qor` 或 `route.qor`。不能把 place-only 指标当成 routed closure。

## 工程背景

已阅读 [media/README.md](../media/README.md)。目标器件为 EG4S20BG256，Slice 上限 9800；设计同时接近 BRAM、DSP 上限。工程由 Tang Dynasty 6.2、ModelSim 10.5b 和 PowerShell 流程构建。由于工具在 post-place critical-path optimization 阶段会崩溃，最近的可复现布局检查使用固定 seed4、`crit_path_opt off`，先综合再 place-only。

## 保留的 RTL 优化

- FIFO occupancy：在 [db_stream_fifo.v](../media/rtl/seam/db_stream_fifo.v) 用寄存 `used_count` 代替 `wp-rp` 反馈减法，并同步维护 `used_ge_256`；[seam_media.v](../media/rtl/seam/seam_media.v) 用占用量阈值直接产生 credit，TX 长度使用已寄存的 256-word 标志。
- END payload：IMG_END/OVL_END 在发送时直接取 `~image_crc`，避免 END 分支驱动 `payload_r` 的宽 CE mux。这是当前 +0.090ns 检查点相对前一版的最新结构改动；place wire length 也从前一正时序版的 1,417,252 降到 1,340,662。
- 图像 scaler： [image_scale_nearest.v](../media/rtl/image/image_scale_nearest.v) 将每行输出像素计数改为剩余像素倒计数，移除 `dx+1 == scaled_w` 动态宽度比较。
- FAT32： [fat32_ro.v](../media/rtl/fat/fat32_ro.v) 拆分 mount 几何变量移位与加一、FAT map 的 Brent `lam+1` 与比较、文件 hop-limit 高低位比较；复用已有暂存寄存器。
- 计数器： [key_debounce.v](../media/rtl/clock/key_debounce.v) 对长按计数器分段预登记进位，降低宽进位路径。
- 其他既有保留改动包括 reset release 扇出、RGMII reset deassert、SDIO error/FSM、MAC RX CRC、db_link 字节计数，以及 emergency/file browser 控制逻辑局部化；详见 `git diff`。

## 最近针对性验证

以下仿真已通过：

- `tb_stream_fifo`：512/1024 深度、顺序、占用、`used_ge_256` 边界、满空、清零和 backpressure。
- `tb_seam_overlay_tx`：完整 2048-word overlay、CRC/APPLIED、ERROR dispatch。
- `tb_media_sd_boot`、`tb_bmp_scale -ScaleCase 0`。
- `tb_fat32_ro`、`tb_fat32_map`。
- `tb_link`、`tb_link_sequence`、`tb_bmp_controller`。
- `git diff --check` 和 `python tools/dual-board/audit.py` 通过。

`tb_media_source` 不是有效的当前接口回归：该 testbench 的 DUT 端口连接不完整（ModelSim 报当前模块期望 108 个端口、测试台只连接 64 个），最终因后续 UI 等待超时。不要将它的超时直接归因于 seam RTL。

## 已试过并撤回的方案

这些实验已还原，避免新对话重复尝试：

- 将 `overlay_count`、`overlay_sent` 同时收窄到 12 位：综合 LUT 减少，但 place setup -2.312ns、Slice 9666；已还原为 32 位。
- 只将 `overlay_sent` 收窄到 12 位：place setup -1.673ns、Slice 9744；已还原为 32 位。
- 给 seam TX 增加一个数据包长度准备状态：place setup -1.511ns、Slice 9600，最差路径转到 link；已还原。
- 修改 db_link 的 peer timeout 计数器更新：place setup -1.881ns，最差路径转到 expired/arbiter；已还原。
- route 期间尝试以 seed4 固定布局优化；多个详细 route 因拥塞长时间震荡而按用户要求停止。没有最终 routed QoR。

## 新对话建议从这里继续

1. 先核对 `phy_endcrc_direct_seed4_nocritopt_placeonly_20261026/inputs.json` 与当前输入 hash（应为 71/71 一致）；不要重新做 seed sweep。
2. 继续围绕 **route 的负 slack和约 100 个 over-net 平台**做 RTL/互连优化。重点检查 seam 的 payload/END/credit 扇出与 link 跨区连接；每次都比较固定 seed4 的 Slice、wire length、congestion 和 place timing。
3. 只在 place 保持正 slack后跑详细 route；最终验收要有 routed `*_pr.timing`/`final.qor`，证明 setup 与 hold WNS 都大于 0、TNS 为 0、违例端点数为 0。
4. 综合命令示例（在 `media` 目录）：

   ```powershell
   .\build\run.ps1 -Stage syn -RunTag <tag>
   ```

   物理 run 应使用 seed4 的现有 place 参数并将 `crit_path_opt off`；直接 `-Stage phy` 默认启用该阶段，已观察到工具崩溃。综合脚本会重建 `MultimediaSystem_media.al`，跑完后核对并还原工具生成的空 `<LABEL>`/策略项变更，不要覆盖用户源码或其它板文件。

## 2026-10-26 后续暂停记录

- 保留的 RTL 增量包括：`wav_playlist.v` 在扫描前暂存单拍选曲请求和 cluster；`fat32_ro.v` 将 map 下一簇判定编码为 2-bit 结果；`db_link.v` 用等价的有符号模序比较函数替代 arbiter 中的 8-bit 减法比较。当前源码没有残留 `media_core` 双来源试验接口或字幕名称折叠试验。
- `syn_fatmap_action_20261026` 对应布局为 setup +0.398ns、hold +0.059ns、TNS/端点均为 0、9655 Slice、wire 1,305,857。固定 seed4 的 place-only 报告在 `phy_fatmap_action_seed4_nocritopt_placeonly_20261026/place.qor`。
- `phy_fatmap_action_seed4_normalroute_extended_20261026` 使用相同 71 项输入、seed4、normal route、`crit_path_opt off`。phase 1 结束 timing 为 setup −14.085ns / TNS −6875.628ns / 2602 endpoints，hold −0.020ns / TNS −0.064ns / 5 endpoints。用户要求停止时 phase 2 进行至 iter 24、over=185。没有 `final.qor` 或最终 `*_pr.timing`，不能签 routed closure。
- 试过只暂存 browser/subtitle 来源位、不暂存 32-bit cluster 的变体：place +0.436ns、hold +0.059ns、9533 Slice；route phase 1 setup WNS −11.376ns，phase 2 WNS −8.072ns，已恢复为带 cluster 暂存的版本。字幕名称折叠变体 place −2.554ns、9725 Slice，也已完全恢复。
- 为当前源码运行并通过 `tb_link_sequence`、`tb_fat32_ro`、`tb_fat32_map`、`tb_media_sd_boot`。结果和对应输入哈希保存为 `media/build/evidence/*_stopcheck_20261026.*`；原有证据文件已恢复。
- 目前结论仍是 routed timing 未闭合；工作按用户要求暂停。继续时从上述 `normalroute_extended` 的 phase 2 结果和当前保留 RTL 开始，不要重复 seed sweep。

## 工作区注意事项

保留 README 和 render 板相关的既有用户改动。最近运行生成的 media test evidence 在 `media/build/evidence/`。`media/MultimediaSystem_media.al` 已恢复到原项目文件；当前 PPA hash 不包含仿真 testbench。
