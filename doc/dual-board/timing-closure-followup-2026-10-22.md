# 双板时序继续优化（2026-10-22）

本报告记录此前 [时序优化基线](timing-closure-2026-10-22.md) 之后的工作。**render 已完成时序闭合，media 仍在优化。两板尚未全部达到零违例，未生成新 bit。** 所有时钟、ADC/SDC、协议 1.12、缓冲容量和原有正式门槛保留。

## 已核验的检查点

| 板卡 | 最终 Setup WNS / TNS（ns） | setup / hold 违例端点 | Hold WNS（ns） | 状态 |
|---|---:|---:|---:|---|
| media，上一轮源码匹配基线 | −0.522 / −31.641 | 213 / 0 | +0.022 | 后续候选仍在评估 |
| render，当前主源码 | **+0.104 / 0.000** | **0 / 0** | **+0.022** | Routed、Slow/Fast、原生 Hold 修复后通过 |

render 实测目录：`build/timing-closure-next-20261022/crcpipe/render/Runs/phy_closure_crc1_m3/`。当前 `render/build/input-fingerprint.ps1` 的完整输入集合与该目录 `inputs.json` 逐项相等；工程文件保留用户原来的 GUI 策略，复现以独立脚本参数为准。机器摘要见 `build/timing-closure-next-20261022/render-closed-summary.json`。

render 资源：9602/9800 Slice，17081/19600 LUT，12305/19600 寄存器，63/64 BRAM9K，15/16 BRAM32K，29/29 DSP，2/4 PLL。时序门槛为 Setup WNS ≥ +0.100 ns、Setup/Hold TNS=0、违例端点=0；当前余量仅比 WNS 门槛高 0.004 ns。**时序通过不代表 bit 发布通过**：现有资源门槛仍会拦截该版本的 BRAM 用量，门槛未放宽，实板验证尚未执行。

## 已保留的 render 修改

- 发包序号的 32 位自增拆为 18+14 位，寄存低位进位预判；发送仲裁增加候选寄存；CRC 头部按 32 位字预取，避免每字节经过 256 位选择器。
- 接收头先本地捕获，再计算范围与命令分类，最后准入；将加法、比较、命令译码分离。
- 字幕坐标除以 12 改为同步商/余数表；字体稀疏边缘改为同步双端口 ROM。读取延迟保持一致。
- 字幕抗锯齿混合增加一拍，RGB 与 HS/VS/DE 一起延迟，仍为每拍一个像素。音量增益拆为三拍，样本数值和输入时的增益语义保留。
- 主图/小图 CRC 的输入先寄存，再进入反馈 XOR 网络；END 校验等待最后一个流水字完成，数据仍可连续每拍接受一字。
- 音频环形 FIFO 的空判定使用同步后的 Gray 指针相等；错误画面的字符区域使用并行绝对边界判断。

## 功能验证

完整日志和输入 SHA256 位于 `build/timing-closure-next-20261022/`：

- `divider-gate/`：综合后厂商 RAM 模型，穷举全部 4096 个字幕横坐标的商、余数及一拍对齐。
- `font-equivalence/`：行为模型及厂商 RAM 模型各 132771 拍，双端口全地址和随机独立读取，与原字体逐点相等。
- `volume-equivalence/`：随机输入、音量、unity、停顿及复位，99933 个立体声样本与原实现逐样本相等。
- `blendpipe-tests/`：5591656 个字幕像素；928093 个完整 720p 字幕与音量组合采样；92160 个图片/字幕/亮度及同步信号采样。
- `crcpipe-stream-tests/`：主图、小图连续每拍一字，完整 CRC、坏 CRC 拒绝、真实双时钟视频握手、立即重试、会话复位及取消恢复。
- `system-evidence/crc-main/`：独立两板可靠链路，图片、288 字符 UI、亮度/对比度、重连重发与后端反馈。
- `system-evidence/font-subtitle/`：真实 FAT、独立两板链路、帧界字幕、重试、按键、失败保留及重连，涵盖字体 ROM 改动。
- `system-evidence/max-subtitle/`：最终 CRC 版本在真实 FAT 和两板链路上的字幕系统回归，完成 5676062 个总线时钟采样。

按键缓冲等其他候选及不同物理策略只用于对照，未将性能退化的候选混入当前 render 源码。media 的 SD 命令超时预判、状态编码、FAT 最大簇捕获和文件描述符使能等候选保存在独立源码目录，待最终布线结果筛选。

## 2026-10-23 media 后续筛选

后续从 media 的 FAT32 几何路径、link 重发序号、CRC/header 预取、BMP 自动轮播计数和物理 placement seed 等方向做了隔离试验。所有候选都通过了对应的 FAT32、link 或双板回归后才进入综合/物理评估；canonical media RTL 保持不变。完整路由中最好的新 RTL 候选仍不如原始 seed8 基线，因此没有合入。

| 试验 | 最终 Setup WNS / TNS（ns） | setup / hold 端点 | 结论 |
|---|---:|---:|---|
| canonical media，`phy_timing_v4_high8_20261022` | −0.522 / −31.641 | 213 / 15 | 目前最佳同源完整 route，仍有 setup/hold 违例 |
| baseline-only FAT 几何分拍，`build/.../maxbase/media/Runs/phy_maxbase_m3` | −2.052 / −273.314 | 515 / 0 | Hold 通过，Setup 退化，不合入 |
| 几何分拍 + render-derived link/CRC，`build/.../maxbase2/media/Runs/phy_maxbase2_m3` | −2.594 / −140.545 | 303 / 0 | Hold 通过，Setup 退化，不合入 |
| 几何分拍 + link arbiter 双拍 + slot cursor，`build/.../maxpipe4/media/Runs/phy_maxpipe4_m3` | −3.010 / −223.820 | 299 / 1 | Hold 仍有 1 个端点，不合入 |
| 几何分拍 + link 重发序号预寄存，`build/.../maxbase4/media/Runs/phy_maxbase4_m3` | −3.476 / −633.470 | 810 / 1 | Hold 仍有 1 个端点，不合入 |
| baseline seed3/high/routability，`media/Runs/phy_baseline_h3_routability` | −0.935 / −166.637 | 582 / 0 | Hold 通过，但比 seed8 基线差 |

其他高 effort 路由有明确的终止原因，没有被当作最终时序结果：baseline seed3/high/normal 在 detail routing 有 3 个资源冲突，baseline seed5/high/routability 中止时 phase2 WNS 为 −10.062 ns 且仍有约 100 条溢出网。实验目录内保留了 `experiment-aborted.json` 和日志。当前 media 最终目标仍是 routed Slow/Fast setup/hold 全零且满足 WNS 裕量；本轮未达到。

## 复现已闭合的 render

在工程根目录执行（需 TD 6.2、ModelSim，使用未占用的新 RunTag）：

```powershell
pwsh -NoProfile -File render/build/run.ps1 -Stage syn -RunTag closure_reproduce -InferFsm auto -AreaEffort auto
pwsh -NoProfile -File tools/dual-board/run-resource-physical.ps1 -Board render -SynthesisRunTag closure_reproduce -RunTag closure_reproduce_m3 -PlaceSeed 3 -PhysicalEffort medium
python tools/dual-board/report-timing-closure.py render/Runs/phy_closure_reproduce_m3 --output build/timing-reproduce.json
```

报告工具同时读取普通时钟路径与 `*_exception.timing`，并与 `final.qor` 核对，避免漏记显式 max/min-delay 端点。布局报告、未完成的布线、旧 GUI bit 均不作为通过证据。中止的拥塞实验保留 `experiment-aborted.json`，不计为完成结果。

## 2026-10-23 追加筛选

在本报告后又做了三项 media 检查，均没有替代 canonical 版本：

| 实验 | 最终/中间 Setup WNS / TNS（ns） | Setup / Hold 端点 | 结论 |
|---|---:|---:|---|
| canonical seed 11，`phy_timing_seed11_20261023` | −0.662 / −99.844 | 416 / 0 | Routed 双角及 native hold 完成，差于 seed 8 基线 |
| FAT mount 簇数移位预寄存候选，seed 8，`phy_clusterpipe_seed8_20261023` | −1.951 / −126.392 | 413 / 0 | 完整 post-hold route；新关键路径转到 seam FIFO → FAT FSM，候选未保留 |
| canonical seed 12，`phy_timing_seed12_20261023` | −0.534 / −73.086（Phase 3 中间值） | 352 / 未完成 | 因持续拥塞人工停止；当时仍有 214 条 overflow 网，未生成 final route / post-hold 报告，不计为完成结果 |

FAT mount 候选在 `S_MOUNT_GEOM4` 将 `geometry_clusters` 移位结果寄存，下一拍在 `S_MOUNT_GEOM4B` 进行最大簇 `+1` 捕获。它未通过物理筛选，且没有进入 canonical media RTL；canonical 源码已恢复。该候选未完成独立功能等价回归，因此不作为可发布实现。seed 12 的终止原因和中间读数保存在运行目录 `experiment-aborted.json`。

以上尝试均未达到 Setup WNS ≥ +0.100 ns、setup/hold TNS=0、setup/hold 违例端点=0；没有生成新 bit。render 源码未更改。

## 2026-10-23 media 逻辑优化续试

本轮继续从 FAT 几何移位、link 序号进位和文件浏览器输出使能三个方向做 RTL 改写；每个候选先跑对应仿真，再用 seed 8/high/routability 做物理筛选。未改时钟、ADC/SDC、协议、缓冲容量或正式门槛。

| 候选 | 最佳可读 Setup 证据 | 物理状态 | 结论 |
|---|---:|---|---|
| FAT 最大簇直接捕获 + 简化加法，`phy_fat_direct_plus2_seed8_20261023` | Phase 5 前最后一次 timing update：−3.767 / −490.827 ns，880 setup / 13 hold | 后续拥塞长时间振荡；未出 final/post-hold | 中止，不合入 |
| FAT 最大簇在现有保持寄存器中分拍右移/加一，`phy_fat_shift_then_inc_seed8_20261023` | routed 初始 −5.582 / −1809.589 ns，1919 setup endpoints | Phase 1 拥塞未收敛 | 中止，不合入 |
| WAV size 从浏览器全局手势优先级树拆出独立 always，`phy_browser_wavcapture_seed8_20261023` | 未路由 | packing 需要 4948 MSlices，超过 4900 | 不合入 |
| WAV size 在同一时序块内本地捕获，`phy_browser_wavcapture_local_seed8_20261023` | routed 初始 −1.246 / −245.962 ns，653 endpoints；Phase 2 −1.246 / −334.283 ns，854 endpoints | Phase 2 拥塞由 538 升至 1160 网后中止 | 不合入 |
| link 序号 8 位四段 carry，`phy_link_carry8_seed8_20261023` | routed 初始 −1.121 / −148.106 ns，457 endpoints | Phase 1 拥塞振荡后中止；从同一 placement 续跑至 30 次仍升至 1281 溢出网 | 不合入 |
| link 序号 16 位双段 carry，`phy_link_carry16_seed8_20261023` / high area 版本 | 未路由 | 两种 mapping 都需要 4901 MSlices，超过 4900 | 不合入 |
| link 序号按 DSP 的 18/14 位边界分段，`phy_link_carry18_seed8_20261023` | routed 初始 −1.742 / −512.127 ns，992 endpoints | Phase 1 路由拥塞未收敛 | 中止，不合入 |
| FAT 按 shift bit 分三拍固定移位、再独立加一，`phy_fat_shift3_inc_seed8_20261023` | routed 初始 −1.559 / −412.170 ns，833 endpoints；Phase 2 −1.559 / −516.696 ns，1076 endpoints | 拥塞升至 625 溢出网后中止 | 不合入 |
| FAT 最大簇 +1 改为四段 8 位并行进位，`phy_fat_p1_carry8_seed8_20261023` | routed 初始 −1.085 / −180.728 ns，506 endpoints；Phase 2 −1.085 / −222.864 ns，621 endpoints | Phase 2 溢出最高 1144 网后中止 | 不合入 |
| FAT 最大簇 +1 改为双段 16 位并行进位，`phy_fat_p1_carry16_seed8_20261023` | routed 初始 −0.923 / −137.851 ns，450 endpoints；Phase 2 −0.923 / −182.539 ns，558 endpoints | Phase 2 溢出升至 1001 网后中止 | 不合入 |
| 同一 FAT 16 位 carry 从 placement 续跑，`phy_fat_p1_carry16_seed8_resume_20261023` | routed 初始 −0.923 / −137.851 ns，450 endpoints | Phase 2 19 次 reroute 后溢出超过 1000 网；未生成最终报告 | 不合入 |
| 同一 16 位 carry 候选，seed 3 | Global Placement Step 3 中间 −3.539 / −86.657 ns，89 endpoints | 在 route 前因显著退化中止 | 不合入 |
| FAT 将簇数为零改写为 `data_sectors < 2^cluster_shift`，`phy_fat_zero_threshold_seed8_20261023` | 未路由 | placement −12.970 / −966.415 ns，301 setup / 194 hold endpoints；normal routing无进展 | 中止，不合入 |
| link 8 位四段 carry + high area mapping，`phy_link_carry8_higharea_seed8_20261023` | routed 初始化 −4.642 / −1457.847 ns，1620 setup / 8 hold endpoints | 明显退化，初始化后中止 | 不合入 |

FAT32 的 MBR/所有簇几何、目录、映射、超时回归在 shift3、zero-threshold 与 p1-carry8 候选上通过；link 序号候选通过 1,800,021 次比较（含连续包、停顿、回绕、会话清除），可靠链路回归通过；WAV 本地捕获候选通过设置菜单/BMP/WAV 导航和浏览器叠加回归。对应日志和 SHA256 保存在 `build/timing-closure-next-20261022/candidate-20261023/evidence/`。所有中止目录均含 `experiment-aborted.json`；中间 routed/placement 指标不当作最终时序结果。

本轮没有候选超过 canonical media seed 8 的完整 routed 基线（−0.522 / −31.641 ns，213 setup / 0 hold endpoints），也没有任何候选达到正式零违例目标。canonical RTL 已恢复，未生成 bit；render RTL 未触碰。
