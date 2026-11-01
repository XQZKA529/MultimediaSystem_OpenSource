# 两板 Slice 优化首轮实施（2026-10-12）

本轮保留一项模块内部 RTL 优化，并为两板固定经过验证的构建参数。**两板尚未达到 85% / 80% 目标**。没有以减少功能、降低时钟、放宽约束或增加跨功能共享逻辑来换取面积。

## 基线与保留结果

基线是提交 `e9394890fbc63f901542f05bb84c4f77371c1416` 的 SD TXT 字幕版本，包含现有图片、音频、菜单、Text OSD 和字幕功能。重新综合、布局布线后复现 media 9392、render 8515 Slice；README 中更早的 8474/8355 等数字属于历史版本。器件每板有 9800 Slice。

| 指标 | media 基线 | media 本轮 | render 基线 | render 本轮 |
|---|---:|---:|---:|---:|
| Slice | 9392 | 9197 | 8515 | 8463 |
| 占比 | 95.84% | 93.85% | 86.89% | 86.36% |
| 减少 | — | 195 | — | 52 |
| 物理 LUT（含进位逻辑） | 16677 | 16586 | 15003 | 15006 |
| 物理寄存器 | 11793 | 11784 | 10752 | 10766 |
| Setup WNS / ns | +0.112 | +0.113 | +0.101 | +0.103 |
| Hold WNS / ns | +0.022 | +0.024 | +0.022 | +0.021 |
| BRAM9K + BRAM32K | 56 + 1 | 56 + 1 | 51 + 5 | 51 + 5 |
| DSP | 7 | 7 | 15 | 15 |
| 物理参数 | medium / seed 5 / relaxation 0.85 | medium / seed 3 / relaxation 0.85 | medium / seed 3 | medium / seed 5 |

以上通过版本的 Setup/Hold TNS 和违例端点数均为零。**render 的 52 Slice 收益来自种子选择，RTL 没有改动，不能算作 RTL 优化收益。**

85% 对应 8330 Slice，media/render 还需分别减少 **867 / 133**；80% 对应 7840 Slice，还需减少 **1357 / 623**。

## 保留的 RTL 修改及边界

唯一生产 RTL 修改是 [`image_scale_nearest.v`](../../media/rtl/image/image_scale_nearest.v) 内部的四个输出位置计数器：`ox`、`row_x`、`dx` 按 `$clog2(DST_W+1)` 定宽，`oy` 按 `$clog2(DST_H+1)` 定宽，最小一位。默认 1280×720 时分别为 11 / 10 位，包含写完一行、输出完最后一行时的终止值。

位宽依据原有 `image_scale_geometry` 的合法目标矩形契约。源坐标仍为 13 位，余数、尺寸输入和计算精度保持原样；没有截断 4096 像素源尺寸或改变取样规则。FSM、接口、握手、周期数、行缓存、吞吐和取消行为均保持原实现。

综合 LUT 从 16057 降至 15937，寄存器从 11710 降至 11694。相同 seed 5 下 Slice 从 9392 降至 9244，相同 seed 3 下从 9376 降至 9197，两个种子均有面积下降。但原版 seed 3 和候选 seed 5 均未满足时序，因此交付选择候选 seed 3，与原签核 seed 5 比较净减少 195 Slice。

没有修改模块依赖、仲裁、CDC、协议 v1.7、超时、缓存容量、音频精度、分辨率、字符容量、字体或厂商 IP；两板源码/IP/约束仍各自本地完整。新测试和测量工具不进入 FPGA 数据通路。

## 已实现并测量、随后撤回的候选

候选均在隔离目录中保存源码与综合/物理报告。没有把综合 LUT 下降直接当作整板 Slice 下降，也没有将时序不合格的 bit 作为交付版本。

| 候选 | 实测结果 | 处理 |
|---|---|---|
| FAT 目录去除 256-bit 条目副本，字符直接同步读取扇区 RAM | 综合 LUT −219、寄存器 −150；seed 5/7/3 分别 9166/9310/9307 Slice，Setup −0.168/−0.104/−0.956 ns | 时序不合格，撤回 |
| TX 包头字段冻结、分层字节选择 | media 在 FAT 候选上 LUT +67；render 相对原版 LUT +1、寄存器 +14 | 没有稳定面积收益，撤回 |
| Text OSD 除 12 与十进制显示改写 | 整板综合 LUT +41；独立模块少量收益未转化为整板收益；倒数乘法还增加 DSP | 撤回 |
| UI 坐标压缩与商/余数复用 | 综合 LUT +36，物理布线失败；只保留商/余数改写仍 LUT +71 | 撤回 |
| RX 去除 224-bit 包头中间副本，直接写未发布槽位 | 初版 media LUT −188 但 Setup −1.861 ns；render 时序通过但 8661 Slice，高于 8515 基线 | 撤回 |
| RX 写口进一步简化 | media/render 综合 LUT −265/−143；media seed 5/3 为 9274/9228 Slice、Setup −0.541/+0.057 ns；render seed 3 为 8426 Slice、Setup −0.806 ns，seed 5 布线失败 | 未满足 +0.100 ns 门槛，撤回 |
| 缩放器行就绪条件提前计算 | 逐拍等价通过，但 LUT +85；9424 Slice、Setup −1.125 ns | 撤回 |
| DDC 计数器位宽与算术寄存器生命周期收缩 | 合并版本 LUT +12、8543 Slice、Setup +0.049 ns；仅计时器版本 LUT −22，但 seed 5 Setup −0.217 ns，seed 3 布线失败 | 撤回 |

失败路径分布在既有 FAT 控制/取消网络、BMP ready/计数器使能链，以及共享字库到视频合成链。高占用下，较小的 RTL 变化会显著改变布线和保持时间修复成本；因此没有继续叠加未签核候选。

## 验证与复现

新增两个公共接口回归并接入 [`run-regression.ps1`](../../tools/dual-board/run-regression.ps1)：

- `tb_fat32_directory`：SFN/VFAT、255 字符、跨碎片目录簇、删除项、卷标、非 ASCII、损坏长名和重复枚举。
- `tb_rx_header_commit`：零/最大载荷、延迟 MAC 完成、CRC/地址/MAC 坏包、非法长度、管理帧、最小帧间隔和元数据背压。原实现和候选均通过；已有 `tb_rx_full` 另外验证满队列保护及中途释放槽位仍丢弃原帧。

[`check-scale-cycle-equivalence.py`](../../tools/dual-board/check-scale-cycle-equivalence.py) 从指定 Git 提交读取原缩放器，与当前版本同台逐拍比较 ready/valid、RGB 和 done。17 种尺寸、随机背压、输入空拍、取消及无复位重启共 **33,781,345 个时钟**通过。独立 BMP 像素参考测试对每种尺寸检查完整 1280×720 输出，共 **15,667,200 像素**通过，覆盖行填充、补黑、取样、尾部排空。真实 `media_core` 另通过 691200 个精确打包字、42 次文件簇转换和完整结束/呈现握手检查。

[`check-link-wire-equivalence.py`](../../tools/dual-board/check-link-wire-equivalence.py) 验证包头候选与原版的双向 MAC 字节和时间戳完全相同：39320 + 4500 字节，包含原有重试、损坏包和序号回绕刺激。此项功能通过不足以取代物理签核，因此包头候选仍撤回。

验证覆盖板级用例、原生 TEMAC/BRAM 模型、SD 字幕、Text OSD/音量重试、720p BMP 缩放、图片切换、WAV 并行/暂停/快进/单声道、诊断和本地依赖审计。重型像素参考和系统用例拆分并行运行；基线板级回归通过后，对最终改动的 BMP 链再次回归。13 个系统场景中，最后三个不经过 BMP 缩放的音频协议场景显式使用 `-FrameWords 432`；完整 720p 图片传输、720p 图像与音频并行及所有受影响的缩放链另行全尺寸验证。具体命令、日志、输入 SHA256 和状态见交付清单。

复现签核参数（使用新 RunTag，不覆盖已有 run）：

```powershell
./tools/dual-board/rebuild-slice-optimized.ps1 -RunTag slice_reproduce_01
./tools/dual-board/run-regression.ps1
python tools/dual-board/check-scale-cycle-equivalence.py --reference-revision e939489
```

新物理重用工具 [`run-area-physical.ps1`](../../tools/dual-board/run-area-physical.ps1) 在复用 gate 数据库前逐项核对源文件字节指纹；保持原时钟、约束、medium 物理努力、原生 hold 修复和原检查门槛。缺少最终产物、工具报错、Setup < +0.100 ns、Hold < 0 或 TNS 非零均不签核。

最终配套产物：[media bit](../../build/slice-optimization-2026-10-12/release/media/MultimediaSystem_media.bit)、[render bit](../../build/slice-optimization-2026-10-12/release/render/MultimediaSystem_render.bit)、[清单与验证状态](../../build/slice-optimization-2026-10-12/release/manifest.json)、[含两板独立构建源码的签核包](../../build/slice-optimization-2026-10-12/slice-optimization-release.zip)。候选测量摘要见 [实验记录](evidence/slice-optimization-2026-10-12.json)，源码和原始报告归档见 [实验包](../../build/slice-optimization-2026-10-12/experiments.zip)。

**实板验收待执行**：两板配套烧录后验证 4096/小图/竖图切换与缩放、淡化、音频并行、菜单/Text OSD/SD 字幕、断线恢复和至少 30 分钟混合运行。工具签核和仿真不替代该项。

## 剩余工作

下一轮先在原模块内收敛 FAT 控制、BMP ready 和视频合成的短裕量路径，再复测已保存的目录/RX 候选，保持数据通路和控制归属独立。只有整板面积和严格时序一起改善才合入。BRAM/DSP/FIFO 的进一步迁移必须由新的模块面积热点和端口/带宽证明支持，不重复采用此前已证实增加面积或破坏时序的方案。

本轮已验证的改动没有足够收益支撑 85% 目标；剩余 867/133 Slice 是实际缺口，不记作已完成，也不以取消现有功能补足。
