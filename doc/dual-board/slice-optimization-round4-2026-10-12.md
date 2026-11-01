# 两板 Slice 优化第四轮：等价算法替换（2026-10-12）

本轮实施三类算法、两个 CRC 写法，共六个独立板级候选和七次物理实现。功能比对通过，但没有找到同时降低最终 Slice、满足严格时序门槛的候选，生产 RTL 未增加本轮改动。当前合格版本仍为 **media 9197 Slice（93.85%）／render 8415 Slice（85.87%）**，两板尚未达到 85% 或 80% 目标。

## 验收条件与基线

保留协议 v1.7、图像/音频/文字精度、分辨率、吞吐、缓存及各模块边界。约束、时钟、area_prior 综合、medium 物理实现和原生 hold 修复不变；media 使用原有 placement relaxation 0.85。Setup WNS 必须 ≥ +0.100 ns，Hold ≥ 0，两个 TNS 和违例数均为零。

基线取首轮 media 与第三轮 render 的合格输入。完整源文件字节哈希再次与生产工程逐项核对，未复用不匹配网表。综合基线分别为 media 15937 LUT / 11694 FF、render 14416 LUT / 10664 FF；物理基线分别为 9197 / 8415 Slice。下表所有差值均相对此基线。

## 算法与实测

| 候选 | 板卡 | 综合 LUT / FF 变化 | seed | 最终 Slice | Setup / Hold ns | 处理 |
|---|---|---:|---:|---:|---|---|
| CRC 共享异或网络 | media | +21 / +0 | 3 | 9292 | +0.044 / +0.022 | 未达到严格时序门槛，Slice 更高 |
| CRC 共享异或网络 | render | +62 / +0 | 5 | 8502 | -0.325 / +0.024 | 未达到严格时序门槛，Slice 更高 |
| 时间换算因式分解 | render | +20 / -1 | 5 | 8447 | +0.101 / +0.022 | 时序通过，Slice 更高 |
| 频谱柱高直接阈值 | render | -62 / +0 | 5 | — | 无最终签核 | 增量布线冲突 |
| 频谱柱高直接阈值 | render | -62 / +0 | 3 | 8480 | +0.108 / +0.027 | 时序通过，Slice 更高 |
| CRC 直接校验矩阵 | media | +7 / +0 | 3 | 9333 | -0.549 / +0.022 | 未达到严格时序门槛，Slice 更高 |
| CRC 直接校验矩阵 | render | +13 / +0 | 5 | 8427 | +0.143 / +0.022 | 时序通过，Slice 更高 |

全部候选保持 BRAM、DSP 数量。未签核候选不交付推荐 bit；时间换算虽生成合格 bit，其面积更高，同样不用于生产。

### CRC：线性代数替代逐位反馈

原 `db_crc_byte` 对反射多项式 `0xedb88320` 展开八次逐位反馈。新算法先计算 `crc[7:0] ^ value`，再直接得到全部 32 位下一状态，仍每拍处理一个字节，初始化/末尾异或、字节顺序和协议不变。

共享写法用 GF(2) 公共子表达式，将反馈部分异或运算从 82 个降至 39 个，产生 17 个共享中间奇偶值。直接矩阵写法不指定共享节点，让 LUT 映射器自行选择组合。两种写法的整板综合都没有降低 LUT；减少抽象异或运算不能当作减少 FPGA LUT 或 Slice 的证据。

### 播放时间：精确提取除数的 2 次幂因子

利用 `48000 = 128 × 375`，把已饱和的采样帧数变为 `floor(n/128)`，每秒减法由 48000 改为 375，工作寄存器在 RTL 中由 32 位变为 22 位。因为 `floor(n/48000) = floor(floor(n/128)/375)`，而减数是 128 的整数倍，每一次比较、减法、BCD 更新和状态转换拍数均相同。99:59 饱和上限从 287952000 编码为 2249625。

整板综合仅少一个 FF，`u_audio_model` 的层级寄存器数仍为 328；工具已对原常数运算有效裁剪。新编码综合反而多 20 LUT，物理多 32 Slice，撤回。

### 频谱柱高：直接精确阈值

保留全部 Goertzel 递推、系数、25 位状态、乘法、三角窗及峰值/衰减流程，仅替换幅值到柱高的计算。原算法先求绝对值，再编码最高置位，最后按固定标定得到柱高；候选直接判断绝对值是否达到各个 2 次幂阈值。负数判断严格包含 `-2^k` 边界，未作近似或改变显示量化。

整板综合少 62 LUT，但最终物理结果未满足保留条件。seed 5 增量布线冲突涉及文字宽度信号与 hold 修复网；候选影响整板布局，不能只根据频谱模块的局部逻辑判断可用性。

## 功能验证与边界

- CRC 两种写法各通过原生 ModelSim 实际 HDL 的 165568 次函数比较：65536 个低字节/数据组合、32 个 CRC 基向量、100000 个随机状态。另有数学矩阵检查。
- 两种 CRC、两板共四次链路回归，分别与 Git `e939489` 比较双向 MAC 流：39320 / 4500 字节的内容和每字节时间戳完全一致，包含既有丢包、损坏、重传刺激。
- 时间换算在生产 BAR_W=340 与附加 BAR_W=640 下各通过 307 组用例、2428203 次逐周期比较；检查完整 model、状态、BCD、进度及新旧工作数编码关系。覆盖整秒/分钟边界、最大帧数、总长为零、99:59 饱和，以及忙时 VS 更新。时间/进度另有独立数学预期检查。
- 频谱直接阈值通过 100253 次幅值比较，含正负幂次阈值及邻近值；实际窗乘/递推/RAM/峰值链用 1200 个样本、生产采样间隔进行 1874504 次输出逐周期比较，覆盖暂停、停止、重启与帧界衰减。
- `audit.py` 和 `git diff --check` 通过，生产两板完整构建输入与当前合格网表指纹匹配。本轮没有修改生产 RTL，因此未重跑全套系统聚合回归；没有宣称完成实板验证。

## 证据与复现

[机器证据](evidence/slice-optimization-round4-2026-10-12.json) 包含每个候选的完整源文件哈希、综合/物理资源及时序。实验目录为 `build/slice-round4/`，包含候选输入、生成脚本、原生仿真日志及构建原始报告。

[实验归档](../../build/slice-round4/experiments.zip) 的逐项 SHA256 已重新读取校验；压缩包 SHA256：`ca46ed539ae3c177cd86893e9bf4e22c8983f9025bdea48cc5d5cd64c6f99a0f`。归档用于复现算法实验，不是新的推荐烧录包。继续使用[第三轮配套合格包](../../build/slice-round3/slice-optimization-release.zip)。

准备脚本应在干净的新实验目录执行，已存在的候选目录拒绝覆盖。独立综合/物理实现示例：

```powershell
pwsh -NoProfile -File build/slice-round4/spectrumthreshold/render/build/run.ps1 -Stage syn -RunTag fresh_spectrum
pwsh -NoProfile -File tools/dual-board/run-area-physical.ps1 -Board render -BoardRoot build/slice-round4/spectrumthreshold/render -SynthesisRunTag fresh_spectrum -RunTag fresh_spectrum_seed3 -PlaceSeed 3
python build/slice-round4/check_spectrum.py
python build/slice-round4/check_time.py --bar-width 340
python build/slice-round4/check_crc.py --candidate crcflat
```

下一轮更应寻找能消除较大状态存储或重复功能的等价架构；本轮常数除法和 CRC 的结果说明，单纯减少算术表达式复杂度已难以稳定降低整板 Slice。不能通过更换近似频谱、降低色彩/字体精度或放宽时序来兑现资源目标。
