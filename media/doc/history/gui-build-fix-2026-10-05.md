> 历史构建记录（2026-10-05）。以下输入、资源、时序和 bit 指纹只对应当时版本；当前功能状态见本板 README。

# media GUI原生编译修复记录

日期：2026-10-05。验收目标是打开本板`.al`后，普通GUI Run/Reset使用厂商默认流程即可完成编译，并满足最终时序和资源门槛。此前仅用命令行分开route/fix_hold的方案不能满足这一目标，现已替换。

本文记录资源优化前的GUI编译修复，78.87%及对应输入为当时的验收结果。后续FAT32资源优化及最新产物见[资源优化记录](resource-optimization-2026-10-05.md)和[配对清单](../release-pair.json)。

## 原因与最终改进

最初GUI工程没有保存既定面积优化策略，slice达到87.64%。同步面积/时序策略后，普通布线力度仍在集成hold修复新增缓冲时触发PHY-8023/RUN-8102，失败网络包括复位副本及邻近业务网络。这不是Verilog语法错误，也不能只凭总体资源未满就判断可布通。

最终采用TD原生`route effort=routability`，让布线器尝试更多避开拥塞的算法；保留`route fix_hold=on`、中等高扇出优化、既定高面积/时序优化及布局种子1。参数通过原生API保存到`.al`，并写入`build/project.tcl`，重建工程或Reset不会丢失。GUI生成的综合和物理Tcl脚本与本机TD的`DefaultFlow.tcl`逐字节一致，没有替换GUI运行脚本。

`build/run.ps1`默认使用同样的`routability`及集成hold修复。`build/MyFlow.tcl`现在保留与GUI相同的route/hold顺序，并额外收集最终报告、在bitgen前检查资源和时序门槛。已删除“普通GUI Run不可用”的使用限制。

media未使用的PLL输出`clkc[2]`会被优化掉，之前已删除其无效时钟重命名及空时钟组成员。没有为通过编译而关闭hold检查、降低业务时钟或增加屏蔽真实路径的约束。最终业务RTL与本次研究开始前一致。

## GUI使用

1. 如果已有工程窗口，通过Project菜单关闭后重新打开`media/MultimediaSystem_media.al`，载入已保存的参数。
2. 点击普通Run。需要干净重编译时，Reset Syn/Phy后再Run。
3. 产物为`media/MultimediaSystem_media_Runs/phy_1/MultimediaSystem_media.bit`。
4. 查看最终Physical/Timing Report：setup WNS至少100ps、setup/hold TNS为0、hold WNS非负、slice不超过80%、BRAM9K不超过56。TD可能在时序不合格时也生成bit，必须以最终报告验收。

自动构建可双击`media/compile-media.cmd`，或在PowerShell 7运行：

```powershell
pwsh -NoProfile -File D:/AnLu_FPGA_project/MultimediaSystem_v1/media/build/run.ps1 -Stage all -RunTag release
```

自动构建产物在`Runs/phy_release/`，会在bitgen前执行上述门槛，并在发布前核对当前输入及bit指纹。GUI入口不依赖这个命令或CMD文件。

## 实际验证

| 构建 | 结果 | Slice | BRAM9K | Setup / Hold WNS |
|---|---|---:|---:|---:|
| GUI普通Run，厂商DefaultFlow，中等高扇出优化+routability | 合格bit | 78.87% | 50 | +102 / +3ps |
| 同一策略，工程重新打开并Reset后普通Run全量复测 | 最终记录见`doc/evidence/gui-native/` | 78.87% | 50 | +102 / +3ps |
| 命令行相同原生策略，`Runs/phy_gui_compatible` | 合格bit，当时输入核对通过 | 78.87% | 50 | +102 / +3ps |

合格结果的setup/hold TNS均为0。GUI复测前保存输入快照，快照早于Read Design开始，复测后核对当前输入一致；同时保留实际生成的原厂Tcl、原生工程、参数、完整日志、最终报告及bit指纹。GUI证据在`doc/evidence/gui-native/`；正式配对产物与输入指纹见[release-pair.json](../release-pair.json)，最终生产报告在`doc/evidence/production/`。旧的`gui-repaired/`为此前手工修正物理脚本的历史记录，不能代替本轮GUI默认流程的证据。

本轮另外通过完整691200字图片及288字符UI联合仿真、原单板基线/本地依赖审计，以及media复制到含空格路径并改名后的独立工程重建、综合和链路仿真。

## 优化取舍与余量

降低全局高扇出优化虽然减少复制，但本轮试验出现一条setup路径为−210ps；下降沿释放全局复位的试验则把使能逻辑推到半周期路径，setup为−1273ps且slice为81.17%。这两种方案均撤回，相关试验bit不发布。最终只采用原生增强布线策略，保留原来的业务与复位结构。

最终slice距80%门槛剩1.13个百分点，setup距100ps门槛只有2ps，hold裕量3ps。当前通过工具验收，但新增功能、ChipWatcher插入或任何RTL/IP/约束/参数变化仍需重新收敛并检查最终报告。实板RGMII、HDMI/SDRAM及长时间运行验收状态未改变。
