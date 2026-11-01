# Media Slice 优化与功能等价分析（2026-10-26）

用户约束：现有功能、格式支持、分辨率、数据精度、错误语义与握手时序保持。目标为 EG4S20BG256 的 **Slice ≤ 9310 / 9800（95%）**。

本轮按用户要求结束优化探索，保留已通过功能检查的配置：**9379 Slice（95.70%）**，setup +0.218 ns、hold +0.059 ns，仍比最初目标多 69 个 Slice。收尾仅处理回归、构建流程一致性及最终复现，未继续调整功能或资源参数。

已阅读 `README-dual-board.md`、`media/README.md`，结合 TD 层级面积报告，检查 FAT、BMP/WAV 解析及控制器、浏览器超时、SDIO、链路与发送层。README 中 9675 Slice 属于较早的源码快照；本轮同流程对照起点为 9625 Slice。

所有下表物理测量均为 **place-only**，固定 seed4、`area_prior`、FSM inference off、high placement、`crit_path_opt off`。setup/hold 为布局估算，不能代表最终布线或实板验收。

| 实验快照 | Slice | 占用 | Setup WNS | Hold WNS | 结论 |
|---|---:|---:|---:|---:|---|
| 起点 `phy_endcrc_direct_seed4_nocritopt_placeonly_20261026` | 9625 | 98.21% | +0.090 ns | +0.109 ns | 对照 |
| `phy_area95_mbrreuse_seed4_placeonly_20261026` | 9532 | 97.27% | +0.251 ns | +0.059 ns | MBR 单项优化，有效 |
| `phy_area95_predicates_equiv_seed4_placeonly_20261026` | 9533 | 97.28% | +0.436 ns | +0.059 ns | 固定字段与扩展名标志，通过回归 |
| `phy_area95_fourccpred_equiv_seed4_placeonly_20261026` | 9566 | 97.61% | +0.436 ns | +0.059 ns | 再加入 FourCC 标志，通过回归，面积未改善 |
| `phy_area95_bramhold_equiv_seed4_placeonly_20261026` | 9554 | 97.49% | −2.560 ns | +0.059 ns | BRAM 替代暂存寄存器，时序不合格，已撤回 |
| 算术共享、进位阈值 8 | 9604 | 98.00% | −0.092 ns | +0.059 ns | 时序不合格 |
| 算术共享、进位阈值 12 | 9407 | 95.99% | +0.352 ns | +0.059 ns | 有效改善 |
| 算术共享、进位阈值 13 | 9426 | 96.18% | +0.121 ns | +0.059 ns | 有效，面积较高 |
| 算术共享、进位阈值 14 | 9536 | 97.31% | +0.230 ns | +0.059 ns | 有效，面积较高 |
| 算术共享、进位阈值 16 | 9394 | 95.86% | +0.436 ns | +0.059 ns | 有效检查点，复现一致 |
| 算术共享、进位阈值 18 | 9618 | 98.14% | +0.298 ns | +0.059 ns | 有效，面积较高 |
| 新 FAT 暂存复用 + 进位阈值 12 | 9468 | 96.61% | +0.065 ns | +0.059 ns | 功能对比与集成回归通过 |
| 新 FAT 暂存复用 + 进位阈值 16 | 9379 | 95.70% | +0.218 ns | +0.059 ns | 当前最佳有效检查点 |
| 新 FAT 暂存复用 + 进位阈值 15 | 9478 | 96.71% | +0.191 ns | +0.059 ns | 未优于保留配置 |
| 新 FAT 暂存复用 + 进位阈值 17 | 9466 | 96.59% | +0.314 ns | +0.059 ns | 未优于保留配置 |
| 新 FAT 暂存复用 + 中等 LUT 映射、阈值 16 | 9379 | 95.70% | +0.218 ns | +0.059 ns | 最终保留配置，综合输入与当前 RTL 匹配 |
| 收尾后最终综合/布局复现 | 9379 | 95.70% | +0.218 ns | +0.059 ns | 与保留检查点一致，输入和数据库核对通过 |

此前出现的 **9399 Slice（95.91%）不属于有效交付结果**。该候选包含浏览器超时合并和叠加图行计数的问题；本轮逐拍检查、回归后已撤回，不能用它宣称功能保持或目标完成。

各项修改的等价依据如下，源码位于 `media/rtl/`。

| 文件与位置 | 原结构及开销 | 等价实现与边界 |
|---|---|---|
| `fat/fat32_ro.v`：MBR 接收、`S_MOUNT_MBR` | 当前分区组装、选中分区、最终分区各有一份暂存 | 挂载操作串行，复用 `partition_lba/partition_sectors` 组装并保留首个有效 FAT32 分区。选中后停止改写；原分区顺序、类型识别、非零起始 LBA 和错误处理保持。该项单独测得少 93 Slice。 |
| `fat/fat32_ro.v`：BPB 字节 11、12 与 BPS 判定 | 16 位字段只用于判断是否为 512 | 两字节累计一个匹配标志；完整引导扇区接收后才使用，非法 BPS 仍返回原错误码。 |
| `fat/fat32_ro.v`：目录项装载与输出 | cluster/size/attr 的组装寄存器组与输出寄存器组重复 | 在 entry_start 前组装到输出寄存器，并保持到 entry_end。接收控制器仍按原 entry_start 捕获元数据。非有效条目期间的元数据电平不是接口承诺；有效条目全部周期已与原版对比。 |
| `fat/fat32_ro.v`：FAT RAM 读取及簇比较 | RAM 输出后再复制一份下一簇号；Brent/map 边界保存多余高位 | EVAL/GET 到 CHECK 期间 RAM 地址及内容保持，直接使用已有同步输出。文件/map 初始簇校验完成后才使用 Brent 比较；FAT 下一簇已屏蔽为 28 位，合法 map 簇的加一结果亦在 28 位内。 |
| `image/bmp_header_parser.v`：固定字段捕获、状态 1/2 | 签名、planes、bpp 共 48 位只用于常量校验；DIB 长度和结束偏移占两组 32 位 | 固定字段累计校验标志；DIB 原值在状态 1 判定后原位加 14，沿用原状态 1/2 的分段加法与进位。尺寸、偏移、溢出、完成时刻均保持。 |
| `audio/wav_header_parse.v`：`S_FMT` | tag/channels/rate/bits 捕获原始字段后再比较 | 分别保留 tag、mono、stereo、rate、bits 低字节标志；最后一个 bits 字节仍在原时刻直接参与判定。错误优先级仍为 tag → rate → bits → channels。 |
| `audio/wav_header_parse.v`：`S_RIFF/S_WAVE/S_CHUNK_ID` | 一个 32 位码寄存器供 RIFF/WAVE/FMT/DATA 判断 | 对固定码逐字节累计匹配；块类型保留到 size 和 body 阶段。未知块、奇偶填充、扩展 fmt、大小及偏移算术保持。 |
| `image/fat_bmp_controller.v`：目录名字节、条目结束 | 四个 8 位寄存器保存末四个字符，再比较 `.BMP/.WAV` | 七个逐级后缀标志表示相同的末 1～4 字符关系；沿用大小写规则。目录元数据仍在 entry_start 捕获，overlay/emergency 过滤和 catalog 上限保持。 |

寄存器减少不等于 Slice 同比例减少。例如固定字段候选减少了 186 个综合网表寄存器，但 LUT 总量仅从 14049 变成 14035，布局占用与 MBR 单项优化基本持平。必须同时检查 LUT4/LUT5、进位链、Slice 配对和时序，不能只数 RTL 位宽。

已经测量并淘汰的其他方向：

- 合并浏览器等待与事务计时器会改变关闭窗口后的超时起点，不满足功能约束。
- 目录元数据直接取 entry_end 时的输入不符合 entry_start 捕获契约；已恢复原捕获方式。
- 叠加图行计数的完成值是 64，6 位不足；最终恢复原实现。
- BRAM32K 写穿透可在同一时钟沿模拟无复位的使能寄存器。336 位暂存移入 12 个 BRAM32K 的厂商模型对比通过，但布局 setup −2.560 ns，因此未采用。
- `map_mode auto` 虽减少逻辑 LUT，打包时 MSlice 达 5004、超过 4900 上限；未采用。
- 自动 FSM 识别与映射组合增大资源；未采用。

本轮验证证据保存在 [review_area95_equiv_20261026](../media/Runs/review_area95_equiv_20261026/)（本机实验目录）：

- `header-diff/result.txt`：2048 组 BMP 新旧解析器逐周期输出对比，含有效、畸形、截断及字节间隙。
- `wav-fourcc-diff/result.txt`：4096 组 WAV 对比，含 mono/stereo、错误码优先级、坏 RIFF/WAVE、未知块、填充、截断及字节间隙。
- `suffix-diff/result.txt`：2048 组目录名，对比所有 39 个控制器输出及目录 RAM，含大小写、短名、目录过滤、overlay/emergency 与目录容量上限。
- `fat-diff-predicates/`：对照本轮改动前 FAT 源码，MBR/文件、map、目录及超时四组用例中对外输出逐周期一致。
- `fat-diff-bankreuse/`：新 FAT 暂存候选对照原版；条目有效期间元数据保持一致，其余对外输出逐周期一致。真实 FAT 字幕与 production media_core 伴随文件/切图回归也通过。
- `evidence/`：BMP/WAV 既有回归、实际 WAV 控制器、BMP 取消/重试与媒体 SD 启动回归。

这些是 RTL/厂商模型仿真覆盖，未作形式等价签核，也未完成新候选的最终布线和实板验收。各物理快照的 `settings.cfg`、`inputs.json` 和 `place.qor` 保存在对应 `media/Runs/` 目录，验收时应使用与最终源码、构建参数匹配的一组报告。

构建脚本新增显式选项：`-ShareArithmetic` 设置 `rtl adder_mux_unsharing off`；`-MinRippleLength <N>` 设置 `rtl min_ripple_len N`；`-AreaEffort medium` 使用 `gate add_map_lut_struct on`。这些是映射策略，未启用重定时或修改时钟约束。

布局复现工具为 [run-media-placeonly.ps1](../tools/dual-board/run-media-placeonly.ps1)。它继承综合参数，核对运行前后 71 项输入指纹及父综合数据库/参数，检查完成标记，记录综合数据库 SHA256，并输出 `place-summary.json`。从仓库根目录重新构建保留配置：

```powershell
./media/build/run.ps1 -Stage syn -RunTag area95_recheck -AreaEffort medium -ShareArithmetic -MinRippleLength 16
./tools/dual-board/run-media-placeonly.ps1 -SynthesisRun syn_area95_recheck -PhysicalRun phy_area95_recheck
```

脚本要求使用新的物理目录名；源码变化后须先重新综合。原生 GUI 工程入口保留，复现本轮面积时应使用上述参数或在 GUI 中设置同一组参数。

收尾检查补充与修正：

- `sim/tb_fat32_ro.v` 新增超级软盘启动代码区含伪 FAT32 分区记录、空根目录读取及随后分区式重挂载用例。确认 `S_MOUNT_ISFS` 原有清零分区偏移分支正确，未重复修改该 RTL；默认突发和单扇区模式均通过。
- `build/MyFlow.tcl` 中旧的 RAM 总数 ≤57 与 `check-reports.ps1` 已有的分类型容量检查不一致，会阻挡合法的 58×BRAM9K + 1×BRAM32K。现统一为 BRAM9K+FIFO9K ≤64、BRAM32K ≤16，并校验总数一致；Setup ≥0.100 ns、零 setup/hold 违例等时序门槛保持。
- [test-media-flow-gates.tcl](../tools/dual-board/test-media-flow-gates.tcl) 直接测试真实 bitgen 校验过程，覆盖合法当前占用、容量边界、两类 RAM 超限、合计不一致、缺失字段和时序不合格，共 12 例通过；测试桩未生成 bit。
- 收尾功能回归覆盖 FAT32 默认/单扇区、目录/VFAT、map、超时、BMP/WAV 头、BMP 取消/重试、实际 WAV、真实 FAT 字幕、伴随文件扫描切图和媒体启动，全部通过。
- 工具生成的 `.al` 空标签等临时改动恢复；浏览器计时器、SDIO、叠加图、行缓冲和像素打包器的试验修改均未保留。

最终保留记录：

- 综合：[syn_area95_final_20261026](../media/Runs/syn_area95_final_20261026/)。
- 布局摘要：[place-summary.json](../media/Runs/phy_area95_final_audit_20261026/place-summary.json)。
- 原始布局报告：[place.qor](../media/Runs/phy_area95_final_audit_20261026/place.qor)。
- 当前 71 项构建输入与最终综合记录全部一致；布局前后源码、父综合数据库和参数均未变化。
- `python tools/dual-board/audit.py` 通过：media 54 项、render 83 项本地设计依赖；render 与冻结基线未受本轮改动影响。
- 最终综合和布局成功，12 项收尾功能回归、12 项 bitgen 门槛测试、PowerShell 语法检查和 `git diff --check` 通过。
- 本轮按用户要求结束。95% 原目标尚差 69 Slice；记录仍为 place-only，最终布线和实板验收未完成，未把本轮结果标记为可发布 bit。
