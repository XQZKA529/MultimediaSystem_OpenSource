# render Slice 与时序收敛（2026-10-25）

本次按 render 单板完成 RTL 检查、面积映射试验和完整布线。目标按最终 Setup/Hold 违例端点数均为 0 判定；不把 Setup WNS 必须大于 +0.100 ns 作为目标。

## 结果

| 指标 | 原完整 route | 本次完整 route |
|---|---:|---:|
| Slice / 9,800 | 9,582 (97.78%) | **9,433 (96.26%)** |
| Setup WNS / TNS | −0.246 ns / −0.579 ns | **+0.105 ns / 0 ns** |
| Setup 违例端点 | 4 | **0** |
| Hold WNS / TNS | +0.022 ns / 0 ns | **+0.022 ns / 0 ns** |
| Hold 违例端点 | 0 | **0** |
| BRAM9K + BRAM32K | 63 + 15 | 63 + 15 |
| DSP | 29 | 29 |

最终数据来自 Tang Dynasty 6.2.168116 的 routed 双角报告。`route.qor` 和 `MultimediaSystem_render_phy.ts` 均报告 Setup/Hold 的 TNS 为 0、违例端点为 0。Slice 减少 149（1.55%）。综合采用 `area_prior`、`infer_fsm off` 和 high LUT mapping；物理实现采用 high effort、seed 8，未改时钟、ADC/SDC 或 timing exception。

## RTL 调整

- `frame_fifo_read_dual` 的 `App_rd_en` 从 `state == S_BURST && issued < target` 的组合比较改为寄存控制。准入后拉高，最后一个已发 burst word 的时钟沿拉低。这样把 `issued` 比较器从高扇出 SDRAM 读使能/tag FIFO 控制路径中移除。
- segment 长度计数器的普通 burst 更新使用固定 `BURST_SIZE`，不再使用可变 `target` 作宽减法。segment 切换判断、突发目标、地址步进和返回字计数保持原有行为。

## 验证与复现

以下两项仿真通过：

- `./sim/run.ps1 -Test tb_sdram_read_contract`：真实 SDRAM 控制器 256-word 读突发请求/返回节拍。
- `./sim/run.ps1 -Test tb_frame_read_dual`：完整双缓冲 720p 扫描、FIFO 反压、RGB 坐标、刷新、单路模式及中断恢复。

原始 route 候选的输入指纹 SHA256 为 `377B0F26E77A2A1D7AA75DCDEACB4A2AA17FF2D07E071BE49F78038BFDA6476`。完整日志、设置、输入指纹和报告位于 `render/Runs/{syn,phy}_zero_viol_opt2/`。复现命令：

```powershell
cd render
./build/run.ps1 -Stage all -RunTag zero_viol_opt2 -InferFsm off -AreaEffort high -PhysicalEffort high -PlaceSeed 8
```

## 单板 bit 生成（2026-10-26）

按用户请求生成 render 单板 bit。旧 `#RAMs <= 56` 将 BRAM9K 与 BRAM32K 总数混算；已改为检查器件实际容量：BRAM9K+FIFO9K≤64、BRAM32K≤16。同时 bitgen 与报告检查按 Setup/Hold 零违例判定（WNS≥0、TNS=0）。这次完整构建和 `check-reports.ps1` 均通过，生成文件为 `render/Runs/phy_bitgen_20261026/MultimediaSystem_render.bit`。

| 项目 | 最终值 |
|---|---:|
| Setup WNS / TNS / 违例端点 | +0.105 ns / 0 ns / 0 |
| Hold WNS / TNS / 违例端点 | +0.022 ns / 0 ns / 0 |
| Slice | 9,433 / 9,800 |
| BRAM9K + FIFO9K / 容量 | 63 / 64 |
| BRAM32K / 容量 | 15 / 16 |
| DSP / 容量 | 29 / 29 |
| bit SHA256 | `1008e35c6ad0811f9edbd3d6d246841261361b7b44c2394ef4ed7167fd8cb9b6` |
| 构建输入指纹 SHA256 | `784C2CECF1E21CF7AB66A7935AF13D1A21B5D6236D201B61B67E6D3B9AE6C15D` |

完整构建目录为 `render/Runs/{syn,phy}_bitgen_20261026/`，qualification 结果保存在 `phy_bitgen_20261026/qualification.json`。复现命令：

```powershell
cd render
./build/run.ps1 -Stage all -RunTag bitgen_20261026 -InferFsm off -AreaEffort high -PhysicalEffort high -PlaceSeed 8
```

这是 render 单板 bit。media 时序尚未闭合，因此不构成双板配套发布版本；实板验收仍需单独完成。
