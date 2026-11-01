# 项目文档导航

双板系统的用途、完整功能、格式、接线和构建以[根 README](../README.md)为入口；[操作速查](../README-dual-board.md)适合上板使用。板级实现细节见 [media](../media/README.md)、[render](../render/README.md)。

## 使用与实现

| 文档 | 内容 |
|---|---|
| [源码功能索引](dual-board/source-map.md) | 实际构建文件、模块归属、启用路径和未引用模块 |
| [协议定义](dual-board/protocol-v1.md) | 报文、对象事务、音频反馈、UI/字幕字段；对应版本以两板 board_link.vh 为准 |
| [实现专题](dual-board/implementation.md) | 架构与专项实现说明，阶段性状态按正文适用范围读取 |
| [实板验收记录](dual-board/hardware-acceptance.md) | 已记录反馈与专项待验项，不等于工作树自动通过验收 |
| [配套发布说明](../release/Second_Release_682b0ab/README-签核说明.md) | 固定提交的两板 bit、SHA256、输入指纹、QoR及复现命令 |
| [media PRBS](../media/diag/README.md) / [render PRBS](../render/diag/README.md) | 独立双向 PRBS31 诊断及计数含义 |
| [字幕样例](../examples/sd-subtitle/README.md) | 手动/同名 TXT、空文件和长文本 |
| [台标样例](../examples/overlay/README.md) | OVERLAY.BMP格式、生成工具与坐标预览 |
| [应急音频样例](../examples/emergency/README.md) | EMERG.WAV格式、触发和替换方法 |

板内 `media/doc/`、`render/doc/` 保留独立工程需要的协议/实现/验收材料。协议文档在根和两板各保留一份，修改时需同步，`tools/dual-board/audit.py` 会核对一致性。部分专题保留了引入功能时的旧参数/构建状态，日常用法以当前 README 和源码为准。

## 开发、故障与验证历史

[开发与验证记录](dual-board/development-history.md)是开发时间线的统一入口，包含从 README 迁出的原始记录以及键盘、缩放、配音、字幕、时钟、应急、资源与时序优化等专题索引。旧试板包、旧报告和版本间对比只作为各自输入的证据，不作为当前源码签核依据。

`dual-board/evidence/` 保存专项回归与资源证据，`dual-board/baseline.sha256.json` 保护原单板基线；板级 `doc/release-pair.json` 及旧签核包按其固定输入解释。发布构建、仿真范围和实板长期验收分别记录。

## 单板与参考资料

- [原单板技术说明](single-board/README.md)与[单板构建工具](../tools/single-board/README.md)：适用于根目录单板工程。
- [Goertzel 算法说明](single-board/spectrum-goertzel.md)：算法参考，双板的显示布局和实际参数以 render 源码为准。
- [FAT32 来源](reference/fat32-sources.md)：实现来源及许可说明。
- [板卡参考资料](reference/board-support/README.md)：原始引脚/寄存器摘录及来源，不参与构建。

README只维护工程入口、功能和操作。带日期的开发过程、逐轮资源数字、故障复现和回归结论写入开发记录或专题文档；固化release的README只说明该配对的使用和复现。
