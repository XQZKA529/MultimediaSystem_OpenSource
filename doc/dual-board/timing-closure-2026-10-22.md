# 双板时序闭合优化（2026-10-22）

本轮在协议 1.12、720p、现有音频精度和全部功能上优化，没有降低时钟频率，没有新增 false path 或 multicycle。两板 ADC/SDC 共四个文件与开工快照逐字节一致。最终判定使用 TD 6.2 的 Routed、Slow/Fast 双角报告，并在布线后执行原生 `fix_hold`。

目标仍为 Setup WNS ≥ +0.100 ns、Setup/Hold TNS=0、Setup/Hold 违例端点=0。**本轮是否达到目标，以以下最终实测表为准；布局或综合报告不能作为闭合依据。**

<!-- FINAL_RESULTS_BEGIN -->
**最终结果：两板 Hold 均为零违例；Setup 尚未闭合，没有生成新 bit。**

开工基线来自冻结的 GUI 原始报告。它们是之前的观测，源码关联限制沿用原 README；最终结果来自本轮独立构建，输入指纹与最终源码逐项一致。

| 项目 | media 开工 | media 保留 | render 开工 | render 保留 |
|---|---:|---:|---:|---:|
| Setup WNS / ns | -3.838 | -0.522 | -10.116 | -2.638 |
| Setup TNS / ns | -1084.243 | -31.641 | -528.066 | -134.324 |
| Setup 违例端点 | 1414 | 213 | 360 | 260 |
| Hold WNS / ns | -0.025 | +0.022 | -0.052 | +0.021 |
| Hold 违例端点 | 8 | 0 | 13 | 0 |
| Slice / 9800 | 9552 | 9401 | 9559 | 9511 |
| LUT / 19600 | 17617 | 17544 | 17498 | 17279 |
| 寄存器 / 19600 | 10800 | 10857 | 11650 | 11961 |
| BRAM9K / 64 | 58 | 58 | 60 | 60 |
| BRAM32K / 16 | 1 | 1 | 15 | 15 |
| DSP / 29 | 28 | 28 | 29 | 29 |

以下运行使用相同最终 RTL；按最终 WNS 优先筛选，TNS 作为同 WNS 时的比较依据。

| 板卡 / 运行 | Slice | Setup WNS / ns | TNS / ns | Setup 端点 | Hold 端点 |
|---|---:|---:|---:|---:|---:|
| media / `phy_timing_v4_high8_20261022` | 9401 | -0.522 | -31.641 | 213 | 0 |
| media / `phy_timing_v4_high8_refine_20261022` | 9401 | -0.522 | -31.641 | 213 | 0 |
| media / `phy_timing_v4_medium3_20261022` | 9358 | -2.462 | -143.395 | 288 | 0 |
| render / `phy_timing_v5_high4_20261022` | 9620 | -3.367 | -194.967 | 254 | 0 |
| render / `phy_timing_v5_high8_20261022` | 9584 | -3.973 | -190.094 | 227 | 0 |
| render / `phy_timing_v5_medium3_20261022` | 9511 | -2.638 | -134.324 | 260 | 0 |

保留运行及输入清单 SHA256：

- media：`media/Runs/phy_timing_v4_high8_20261022`；`b838ebe45d4b9f750763076dfeb2b8ef1d3509718bfef3b2a30df101ed16a825`。
- render：`render/Runs/phy_timing_v5_medium3_20261022`；`002800fe7f5ddd88be3578912260ab217d3cb3317f029d1338b48db628e9a08b`。

主要剩余路径（原始最终网表名称，精确路径见报告）：

- media -0.522 ns：`u_media/u_glue_storage/u_storage_service/u_fat32_ro/data_sectors_reg[10]_syn_4.clk` → `u_media/u_glue_storage/u_storage_service/u_fat32_ro/u_maximum/lane[1]$u_hold.a[10]`，6 ( LUT5=2  ADDER=2  MULT18=1  LUT4=1 )。
- media -0.483 ns：`u_link/sequence_bank[0]$transmit_dsp$u_tx/u_low.clk` → `u_link/sequence_bank[0]$transmit_dsp$u_tx/u_high.a[12]`，3 ( ADDER=2  MULT18=1 )。
- media -0.393 ns：`u_link/occupied_reg[7]_syn_114.clk` → `u_media/u_file_browser/ext_play_size_reg[24]_syn_4.ce`，7 ( LUT4=5  LUT5=1  LUT3=1 )。
- render -2.638 ns：`u_link/u_receive/header_q_reg[103]_syn_4.clk` → `u_seam/error_code_b[0]_syn_31.a[0]`，7 ( LUT4=7 )。
- render -2.192 ns：`u_link/u_receive/header_q_reg[100]_syn_4.clk` → `u_seam/audio_eof_reg_syn_5.d[1]`，5 ( LUT4=2  LUT3=2  LUT5=1 )。
- render -2.162 ns：`u_link/u_receive/header_q_reg[100]_syn_4.clk` → `u_seam/write_abort_reg_syn_11.b[0]`，7 ( LUT5=3  LUT4=3  LUT3=1 )。

复现时先综合，再以独立标签执行相同物理参数；保留目录已存在时须更换 RunTag，不能覆盖已有证据。

```powershell
& ./media/build/run.ps1 -Stage syn -RunTag timing_repro -InferFsm off -AreaEffort high
& ./tools/dual-board/run-resource-physical.ps1 -Board media -SynthesisRunTag timing_repro -RunTag timing_repro -PlaceSeed 8 -PhysicalEffort high
& ./render/build/run.ps1 -Stage syn -RunTag timing_repro -InferFsm auto -AreaEffort auto
& ./tools/dual-board/run-resource-physical.ps1 -Board render -SynthesisRunTag timing_repro -RunTag timing_repro -PlaceSeed 3 -PhysicalEffort medium
```

GUI 工程已保存选中的物理策略，需重新打开工程后重建；旧 `best_result` 仍是旧产物，没有替换。正式评估使用上述 CLI 的最终双角检查和额外原生 Hold 修复。
<!-- FINAL_RESULTS_END -->

## 实现变化

- **视频混合**：减法、乘法、舍入回加拆成三拍；网格延迟查表前移，与坐标一起寄存，收缩边界再分两拍准备。RGB、有效位、混合使能和 HS/VS/DE 完整对齐，总混合段延迟由一拍变为五拍，仍每拍输出一个像素。
- **频谱绘制**：将频带选择与插值/几何分到音频 OSD 既有的两拍中；相邻频带共用选择地址，提前限幅，平行加权求和替代比较、求差、乘法、舍入和回加的串联。80 根频谱的像素、切角、玻璃颜色和两拍外部延迟保持一致。
- **字幕高亮**：直接按编辑窗口内的像素范围比较，移除高亮判定对 banner 选择和 `/12` 字符列除法的依赖。
- **以太网收发**：提前寄存 RX 头部/负载字节区间、TX 负载字边界；先读取 32 位报头字，再选择其中的字节。render 同步采用 media 已有的末字索引和超时标志预计算。链路逐字节及时间戳等价验证通过。
- **media 控制**：对零长度、对象匹配、字幕回执、键盘事件等先分类再更新应用状态；字幕 applied 的修订比较先寄存。图片重试/小图开启时使旧分类失效，并阻止同拍接收旧对象回复。
- **SDRAM 读仲裁**：FIFO 选择与突发启动分开，新增 `S_ADMIT`，启动前重新检查共享 SDRAM 的写占用、busy 和刷新。FIFO 容量和整次突发预留不变。
- **小图校验**：新增 `O_VERIFY`，先寄存 CRC/长度比较，再决定 commit 或错误回复，切断 RAM 输出到整个错误对象寄存器的长使能链。
- **音频输入**：在音量乘法前寄存样本、valid、音量和强制满音量控制，隔离 epoch 比较/静音选择与乘法器；音频段增加一拍，样本数值不变。

## 物理实现筛选

比较了 media 的自动 FSM/普通面积综合与原 off/high 面积策略；自动 FSM 候选增加约 800 个 LUT，未保留。render 继续使用原 area_prior/auto FSM/普通面积策略。物理阶段对比 medium、TimingHigh、厂商 TimingUltra、不同 seed，以及在同一已布线设计上增加四轮 post-route 的增量尝试。更高 effort 不保证更好，选择以最终实测结果为依据。

所有试验均写入独立 `Runs/syn_timing_*`、`Runs/phy_timing_*`，没有覆盖旧发布包和 GUI `best_result`。中间候选与当前 RTL 不同的报告仅作为实验记录，不参与最终候选选择。`resource-experiment.json` 的 `experiment_pass` 是历史实验筛选门槛，不代表正式签核；应查看 `formal_timing_pass` 与最终 WNS/TNS/端点数。

保留了正式 bitgen 门槛和原资源门槛，没有为输出 bit 放宽判定。

## 功能与时序验证

| 验证 | 实测结果 |
|---|---|
| 生产网格/混合段，每拍更换输入 | 178,798 组 RGB/valid/HS/VS/DE/故障标志比对；覆盖 48 单元、31 步及边界两侧 |
| 原混合算术测试 | 端点、中点、舍入、通道独立、直通、有效位和复位通过，按三拍接口检查 |
| 完整 720p 双图读出 | 两路完整图片、真实 FIFO 反压、坐标、刷新、单图及中断恢复通过 |
| 80 根频谱/播放卡片 | 3,859,201 项完整画面检查，播放/暂停/零频谱/隐藏均通过 |
| 字幕绘制与滚动 | 5,591,656 项像素检查及 896 像素窗口、61 帧停顿、每两帧一像素滚动检查通过 |
| 图像/文字/亮度组合 | 76,800 像素及 HS/VS/DE 检查通过 |
| 生产音频新增寄存段 | 49,827 个立体声样本逐位相同，覆盖逐拍音量/静音/unity 变化、停顿和复位 |
| 两板链路等价 | 相对开工 Git HEAD，两方向 39,320/4,500 个 MAC 字节及时间戳完全相同；含 1024 字节负载、重传、CRC、回绕及重连 |
| RX 队列与头部提交 | 满队列保护、途中释放槽、0/最大负载、最小 IFG、延迟 MAC 完成、非法长度和错误 CRC 等通过 |
| 真实 TEMAC | 双向 HELLO、1024 字节负载、CRC/ACK 通过，零重传 |
| 小图真实双时钟与厂商 BRAM | VS 握手、CRC、立即重试、会话复位和取消恢复通过 |
| 图片提交/转场 | 写完成、VS、读所有权、整图 CRC、旧图恢复、重复事务和失败保留通过 |
| media 对象替换竞态 | 旧 READY/PRESENTED 落在分类前后两个边界均被拒绝；新对象回复正常；新增用例在保护加入前可复现失败 |
| 最终冻结源码字幕集成 | 真实 FAT、两板各自独立链路、VS 提交、文件/目录所有权、反压、重试、键盘并发、错误保留和重连通过；本次关闭帧文件导出 |
| 最终冻结源码图片/UI 集成 | 64 个 RGB888 打包字、288 字符快照、亮度/对比度、重连重发和后端反馈通过；完整 720p 扫描另由双路读出测试覆盖 |

修复了旧测试夹具：`tb_link` 对已改为 DSP bank 的序号注入真实 `held` 寄存器；`tb_media_source` 和 `tb_system` 连接已有 `transition_mode` 输入，避免 Z 阻止 UI 快照冻结，并更新前者过期的现有协议标志常量。这些修正没有放松像素、数据、时序或协议检查。

## 证据与复现

最终紧凑汇总：[timing-closure-2026-10-22.json](evidence/timing-closure-2026-10-22.json)。工作区完整证据在 `build/timing-closure-20261022/`：

- `baseline/`：开工 RTL、约束和原始 GUI 报告快照。
- `final-inputs/`、`final-source-sha256.json`：最终源码与集成仿真输入，184 个构建输入逐项匹配。
- `sim/`、`pixel-pipeline/`、`audio-pipeline/`、`wire-equivalence/`、`metadata-race/`：单元、像素、逐位、链路等价和竞态证据。
- `final-system/`：真实 FAT/字幕及图片/UI 集成日志和输入哈希。
- 各板 `Runs/phy_timing_*/`：`inputs.json`、`settings.cfg`、最终 `*_pr.timing`、`*_phy.ts`、`*_phy.area`、`final.qor` 和路由数据库。

像素和音频寄存段验证可分别运行：

```powershell
python tools/dual-board/check-timing-pixel-pipeline.py
python tools/dual-board/check-timing-audio-pipeline.py
```

最终实现的复现命令与未闭合路径见最终结果段。`report-timing-closure.py` 只接受 Routed 双角报告；综合、布局或某个中间路由阶段的正 WNS 不会被当作最终闭合。尚未进行本轮实板验收。
