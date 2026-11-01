# media 零违例版本（V4）可行性分析（2026-10-30）

> 目的：回答"到底怎么才能做出 Setup/Hold 零违例、资源不超限的 media 版本"。
> 输入：`README-dual-board.md`、`doc/dual-board/handover-media-timing-2026-10-30.md`、
> `doc/media-timing-slice-analysis-2026-10-26.md`、`doc/media-timing-closure-followup-2026-10-26.md`、
> `doc/media-zero-2026-10-28.md`，以及当前工作区 `media/Runs/phy_m2/` 实测报告。
> 本文只做分析与方案，**未修改任何源码、约束、时钟**。

---

## 0. 结论摘要

1. **在 100 MHz bus_clk + 现有全部功能的前提下，这块 EG4S20 无法收敛。** 这不是"再改几处 RTL"的问题：
   布线后 70–80% 的路径延迟是连线，而连线延迟由 98% 的占用率决定。历史最好成绩是
   `phy_timing_v4_high8` 的 −0.522 ns / 213 端点，以及 `pipe` 的 −0.692 ns / 33 端点，
   **40+ 候选、100+ 种子从未出现一次零违例**。
2. **本轮 m2 的现场证据更差**：布局 9643/9800（98.40%），比历史 ctx66 的 9339 多 304 Slice；
   布线迭代已出现典型发散（冲突 1117 → 2368，线长 3.31 M → 3.55 M，基线 2.73 M）。
   说明"LUT −151"没有换来可布线性，**面积口径必须是 LE/Slice，不是 LUT**。
3. **零违例只有两条现实路径**：
   - **A（可预测）**：把 bus_clk 从 100 MHz 降到 83.33 或 76.92 MHz，直接增加 2.0 / 3.3 ns 预算；
   - **B（有功能代价）**：砍掉约 1500–2000 LE 的功能，把占用率压到 88–90%，再赌布线与种子。
   两条路都必须叠加 **C（占用率与热点收口）**，否则路由器连"收敛"这一步都过不去。

---

## 1. 当前实测数据（本轮）

### 1.1 综合（`media/Runs/syn_m2`，AreaEffort high）

| 项 | 数值 | 容量 |
|---|---:|---:|
| LUT | 17154 | 19600 |
| 寄存器 | 10757 | 19600 |
| BRAM9K / BRAM32K | 49 / 5 | 64 / 16 |
| DSP | 25 | 29 |

### 1.2 布局（`media/Runs/phy_m2/place.qor`、`*_phy.area`）

| 项 | 数值 | 说明 |
|---|---:|---|
| Slice | **9643（98.40%）** | LE 18688 = 7968 lut-only + 10234 lut&reg + 486 reg-only |
| LUT（映射后） | 18202（92.87%） | 比综合多 1048，属 TD 映射/packing 膨胀 |
| 寄存器 | 10720（54.69%） | 只有 54%，寄存器从来不是瓶颈 |
| Setup WNS / TNS | **−1.660 ns / −20.652 ns** | 仅 25 个违例端点（路线前） |
| Hold WNS | +0.059 ns | 零违例 |
| Top1% tile util | 84.72% | Over-100% tile = 0（拥塞是"分布式的、到处都是"，不是局部热点） |
| 分析端点 / 路径 | 20362 / 171613 | 全部落在 bus_clk 域 |

时钟域（布局报告）：`bus_clk 100 MHz` 是唯一有违例的域；`rgmii_rx_clk +0.436`、`mem_tx_clk +2.753`、
`sys_clk +16.709`、`tx_clk_90 +1.036` 都有余量。**问题只在一个域里。**

### 1.3 布线（正在进行，`phy_m2/td_20261030_155535.log`）

```
Iter 11: len=3.31e6, over=1117
Iter 15: len=3.42e6, over=1750
Iter 19: len=3.55e6, over=2368      ← 冲突与线长同步上升
```

参考基线（`phy_timing_v4_high8`）线长 2.73 M、冲突收敛。**当前这次是典型的拥塞不收敛**，
按历史经验（`media-zero` §物理筛选）应判为 trial-aborted，不能作为时序结论。

### 1.4 历史布线成绩（同源可比部分）

| 运行 | Slice | Setup WNS | TNS | 端点 |
|---|---:|---:|---:|---:|
| `phy_timing_v4_high8_20261022`（最好一次） | 9401 | **−0.522** | −31.641 | 213 |
| `pipe s7h100` | 9478 | −0.692 | −8.103 | 33 |
| `pipe seed61` | 9374 | −0.560 | −52.865 | 267 |
| `ctx66`（当前 RTL 基线） | 9339 | −1.291 | −358.687 | 823 |
| `lfn42` | 9307 | −3.631 | −1019.416 | 998 |
| `seam58` | 9338 | −5.067 | — | 1310 |

**读法**：Slice 从 9307 到 9478 都有，但 WNS 从 −0.522 到 −5.067 无规律摆动。
**面积与布线时序在这块器件上没有正相关**；差异主要由布局质量与种子决定（±1 ns）。

---

## 2. 为什么"再改 RTL"救不回来（机理）

### 2.1 违例的性质：连线主导，不是逻辑深度

`media-timing-slice-analysis` 已经逐元件量过：第 3–10 名违例的特征是
**7 级逻辑只值 2.8 ns，连线却要 7–8 ns**（正常满载设计 0.3–0.6 ns/根）。
`pipe` 最好那版的 33 个端点、`eqgroup` 的局部收益（10.34 ns → 9.55 ns）都证明：
单点拆逻辑能改善**那一条路径**，但会立刻把瓶颈推到别的模块（`seam`、`BMP`、`emergency`、`link` 轮流转）。
三天里 40+ 候选都是这个结局。

### 2.2 本轮 25 个布局违例集中在同一个结构缺陷上

`phy_m2` 布局报告前 10 条违例（−1.30 ~ −1.66 ns）**全部**是：

```
u_link/occupied_reg[6]  →  u_link/crc_acc_reg[*].ce        （7 条）
u_link/occupied_reg[6]  →  u_link/mux138_syn_*.ce          （2 条）
u_link/slot_seq_reg[12] →  u_link/ack_release_reg.a[1]     （1 条）
```

即：**一个 8 位槽位寄存器的位，经可变索引/译码后，直接驱动整整一片 32 位寄存器阵列的 CE。**
`db_link.v` 里 `occupied[send_slot]`、`sent[scan_slot]`、`slot_seq[scan_slot]` 这类可变索引
在 8 个槽位寄存器之间生成 8:1 选择树，而 TD 不会自动复制这些高扇出网。
这正是 render 侧 `ui_receiving` 修好的那一类问题（把宽 CE 从译码路径上摘下来）。
**这类修改便宜、零功能代价，但单独做最多把 WNS 拉回 0.3–0.5 ns，不足以补 1.3 ns 的缺口。**

### 2.3 98% 占用率是硬约束

LE 18688 装进 9800 个 Slice（每 Slice 2 LE），打包效率 95%，已经没有"塞一塞"的空间。
在 98.4% 占用下路由器没有绕行自由度，平均 net delay 从 0.4 ns 级跳到 1 ns 级 —— 这是 823 个
擦边端点的直接原因。**要么降低 LE，要么放宽周期，没有第三条。**

### 2.4 放大器效应

历史已多次验证：place WNS 不能预测 routed WNS（+0.399 → −1.792；+0.196 → −2.606）。
在 97–98% 占用下，布局差 0.2 ns 会在布线后放大成 0.8 ns 的反向差。
**所以"再扫一个种子碰运气"的期望值极低，且不可复现。**

---

## 3. 方案 A：降低 bus_clk（唯一可预测的零违例路径）

### 3.1 工程可行性：设计本身就是参数化的

所有与频率相关的常数都集中在一个宏：

```verilog
// media/rtl/pkg/video_bmp_params.vh:33
`define VBP_SD_CLK_HZ  100_000_000  // sd_card_clk
```

`media_core.v` 把它传给 `sd_card_sdio`、`file_browser`、`fat_bmp_controller`、
`audio_transport`、`emergency_media_controller`、`keypad_action_router`、`key_debounce`
（`CLK_FREQ_HZ` / `CLK_HZ`）。也就是说**改一处宏 + 重新生成 PLL，全设计的 ms/µs 语义自动跟随**，
不存在"某个模块偷偷假设 100 MHz"的隐患。

PLL（`media/rtl/clock/board_sys_pll.v`）当前：`FIN=50 MHz`、`FEEDBK_PATH=CLKC0_EXT`、
`FBCLK_DIV=2`、`CLKC0_DIV=10` → bus_clk 100 MHz，VCO 1000 MHz，`CLKC1..3_DIV=8` → 125 MHz。
**注意：外部反馈路径下 CLKC0 频率被 FBCLK_DIV 锁死（50×2=100 MHz），单独改 CLKC0_DIV 会把
VCO 一起改掉并连带毁掉 125 MHz 的 RGMII 时钟。** 必须改用内部反馈、固定 VCO=1000 MHz，
再设 `CLKC0_DIV`：

| 目标 bus_clk | CLKC0_DIV | 周期 | 相对 100 MHz 的预算增量 | 预计 Setup WNS（以 ctx66 的 −1.291 为基准） |
|---:|---:|---:|---:|---:|
| 100 MHz | 10 | 10.00 ns | 0 | −1.291（不达标） |
| 90.9 MHz | 11 | 11.00 ns | +1.0 ns | −0.29（仍不达标） |
| **83.3 MHz** | 12 | 12.00 ns | +2.0 ns | **+0.71**（勉强，抗不住 ±1 ns 种子抖动） |
| **76.9 MHz** | 13 | 13.00 ns | **+3.0 ns** | **+1.71**（推荐，留 1.7 ns 余量） |
| 71.4 MHz | 14 | 14.00 ns | +4.0 ns | +2.71（过度牺牲） |

`CLKC1..3` 保持 `DIV=8` → 125 MHz 不变；`media/constr/media.sdc`、`media.adc` **不需要改**
（`derive_clocks` 从 PLL 模型取周期）。

### 3.2 代价清单（全部可量化、可接受）

| 影响面 | 现状（100 MHz） | 76.9 MHz 时 | 判断 |
|---|---|---|---|
| SD 时钟 | `DIV_FAST=2` → 25 MHz | 19.2 MHz（DIV 不变即自动跟随） | 仍满足 Default Speed，读卡慢 ~23% |
| SD 初始化时钟 | `DIV_INIT=125` → 400 kHz | 307 kHz | 合规（≤400 kHz） |
| BMP 载入/解码吞吐 | — | −23% | 单帧 1280×720 解码约 12 ms→15 ms，远小于链路 22 ms，非瓶颈 |
| 链路吞吐 | seam 32 bit/拍 → 400 MB/s | 307 MB/s | 仍远高于千兆 125 MB/s |
| PCM 供给 | flow-control，render 消费 | 不变 | 无影响（media 只按请求喂帧） |
| 各类超时/去抖（1 s/15 s/3 s、50 ms、2 s、300 ms） | 按宏计算 | 宏自动跟随，墙钟时间不变 | **零行为变化** |
| 字幕滚动、转场帧数 | 按帧计 | 帧率由 render 决定 | 无影响 |
| 协议 | v1.14 字节级不变 | 不变 | 两板无需重新配对 |

### 3.3 但是：降频**不解决布线不收敛**

降频只增加 setup 预算，**不减少拥塞**。本轮 m2 的核心问题是路由器排不完（冲突越迭代越多）。
所以方案 A 必须与 §5 的"把占用率拉回 95% 以下"同时做，否则连 `final.qor` 都拿不到。

---

## 4. 方案 B：减功能换面积（100 MHz 保持不变时）

必须减 **1500–2000 LE**（≈ 750–1000 Slice）才能把占用率压到 88–90%，而这已经等于删功能。
按综合层次面积（`syn_m2`）可选的取舍：

| 功能 | 主要模块 | LUT（含 ripple） | 折算 Slice |
|---|---|---:|---:|
| SD 字幕（含滚动/解析/RAM 控制） | `sd_subtitle_controller 908+52`、`txt_prefix_parser 77` | ~1037 | ~520 |
| 图片配音 + 播放列表 | `fat_wav_controller 1368+65`、`wav_playlist 170+12` | ~1615 | ~810 |
| 64×64 OVELAY 小图 | `sd_overlay_controller 284+41` | ~325 | ~165 |
| 本地应急（GPIO/C 键） | `emergency_media_controller 308+8` | ~316 | ~160 |
| 长文件名 LFN | `fat32_ro` LFN 表与解码 | ~400（估） | ~200 |

- 砍"字幕 + OVERLAY + 应急" ≈ 1680 LE ≈ 840 Slice → **约 8800 Slice（89.8%）**；
- 再砍"配音 + 播放列表" ≈ 3295 LE → **约 8000 Slice（81.6%）**，但这已经是产品定义级的删减。

**即使压到 90%，也只是"有机会"**：`pipe` 在 96.7% 上做到 −0.692/33 端点，说明瓶颈已不在总面积而在
特定几条高扇出 CE/长连线。所以方案 B 的期望是"零违例概率从 ~0% 升到 ~50%"，不是确定收敛。

---

## 5. 方案 C：无论走 A 还是 B 都必须做的收口

按收益/风险排序，全部为"零功能变化"：

1. **`db_link` 的槽位 CE 扇出（性价比最高，直接命中当前前 10 条违例）**
   - 把 `occupied[send_slot] / sent[scan_slot] / slot_seq[scan_slot]` 这类可变索引的结果，
     在进入 `crc_acc`/`crc_address`/`sent[]` 的 CE 之前**寄存一级**（新增 2–3 个 1 bit 寄存器，
     在已有状态拍里完成，不加周期）；
   - 或者复制 `occupied[]`（8 bit × 2 份 = 16 FF），让 CRC 支路用独立副本。
   - 参照 render 的 `ui_receiving`：CE 从译码路径上摘下来。
2. **`u_link/slot_seq[12] → ack_release`**：`ack_release` 的置位条件里 `slot_channel()==m_hdr[31:24]`
   与 `seq` 比较同拍，改成在 ACK 头接受拍预寄存通道/序号，下一拍只用寄存器比较。
3. **找回配置性面积**：本轮 `-AreaEffort high` 的 9643 与 ctx66 的 9339 差 304 Slice，
   历史 E4/pipe 用的是 `-AreaEffort medium -ShareArithmetic -MinRippleLength 16`（器件 LUT 16657
   vs 本轮 17154）。**必须先做一次同源对比综合**，确认这约 300 Slice 是配置差而不是 RTL 差。
4. **`seam_media` 12 路 32 位 offset 选择树**（handover §5 列的第二梯队）：各 payload 在自己的状态里
   增量维护 offset，只保留 4:1 选择。
5. 不要碰：SDC/ADC/false path、DSP-hold 全撤（+112 Slice）、`fat32_ro` 挂载几何改写
   （历史上 8 种等价写法全部触发 TD elaborate 崩溃）。

---

## 6. 推荐执行顺序

**第 0 步**：等 `phy_m2` 结束（或按发散判定 trial-aborted），记录 Slice/WNS/冲突曲线，与 9339 对照。

**第 1 步（半日）**：同源综合对比。同一份 RTL 跑
`-AreaEffort medium -ShareArithmetic -MinRippleLength 16`，只比较综合 LUT/REG，
确认能否把器件 LUT 从 17154 拉回 ~16800。若能，后续所有物理试验都用这套综合参数。

**第 2 步（1–2 日）**：做方案 C 的 1、2 两处 RTL 收口 + 仿真（`tb_link`、`tb_link_*` 全组）。
目标是让布局前 10 条违例消失，布局 WNS 从 −1.66 拉回 0 附近。

**第 3 步（关键决策点）**：
- 若接受"不承诺 100 MHz"：按 §3 改 PLL（内部反馈、VCO 1000、CLKC0_DIV=13）+ 改一个宏，
  然后一次完整布线（seed 3/4，`routability`）。**这是唯一能给出"零违例 bit"的路径**，
  预计 WNS +1.5 ns 量级，Hold 不变（+0.024）。
- 若 100 MHz 是硬指标：走方案 B，由用户确认删减哪几项功能，然后按
  `place-only 初筛 → 前 2 名完整布线` 的流程筛种子。

**第 4 步**：签核门槛不放宽
（`SWNS≥0 / STNS=0 / 0 端点 / HWNS≥0 / HTNS=0 / 0 端点 / Slice≤9800 / LUT·REG·DSP 不超 / BRAM9K≤64 / BRAM32K≤16 / inputs.json 一致 / bit SHA256`），
然后补集中功能仿真与实板验收。

---

## 7. 风险与禁忌

1. **降频是产品决策，不是"绕过验收"**：它改变的是工作频率这一设计参数，SDC 与功能不变；
   但文档里所有"100 MHz"表述、以及"100 MHz 总线时钟产生每秒计时使能"（render 侧）需分别说明，
   两板不需要重新配对协议。
2. **不要用布局 WNS 判断达标**（历史 +0.399 → 布线 −1.792）。
3. **不要用 `route effort normal` 评估时序**（历史 −10.157 ns 假结果）。
4. **不要在 98% 占用下反复扫种子**：本轮已证明冲突发散与种子无关，先把占用率或周期解决。
5. **不要动 v1 工作区**（`D:\AnLu_FPGA_project\MultimediaSystem_v1`）与那里的构建进程。
6. `tb_volume_protocol`、`tb_emergency_system`、`tb_media_source` 的既有失败是测试激励位宽问题
   （见 followup 文档），不阻断本次工作，但不得记为"回归通过"。

---

## 8. 已实施：bus_clk 100 MHz → 83.333 MHz（2026-10-30 16:40 起）

用户口径：**"不能有明显速度降低前提下可以降频"**。据此选择 83.333 MHz（+2.0 ns 预算），
而不是更保险的 76.9 MHz（+3.0 ns / SD 慢 23%）。

### 8.1 改动（3 个文件，全部为零功能变化）

| 文件 | 改动 |
|---|---|
| `media/rtl/pkg/video_bmp_params.vh` | `` `VBP_SD_CLK_HZ `` 100_000_000 → **83_333_333** |
| `media/rtl/clock/board_sys_pll.v` | `REFCLK_DIV` 1→**3**、`FBCLK_DIV` 2→**5**、`CLKC0_DIV` 10→**12**、`CLKC0_CPHASE` 9→**11** |
| `media/rtl/top_media.v` | `db_link` 增加 `.CLK_HZ(``VBP_SD_CLK_HZ``)`（HELLO 20 ms / 超时 100 ms / retry 5 ms 保持物理时间不变） |

PLL 推导（已由综合 elaborate 确认可用）：

```
C0  = FIN/REFCLK_DIV*FBCLK_DIV = 50/3*5 = 83.3333 MHz
VCO = C0*CLKC0_DIV             = 83.3333*12 = 1000 MHz   （与原来相同）
C1..C3 = VCO/8                 = 125 MHz                 （RGMII TXC / 90°，保持不变）
PFD = FIN/REFCLK_DIV           = 16.667 MHz             （原 50 MHz）
0° 相位要求 CPHASE = DIV-1 → CLKC0_CPHASE = 11
```

**必须注意**：外部反馈 `FEEDBK_PATH=CLKC0_EXT` 下 C0 频率由 `FBCLK_DIV` 决定，
单独改 `CLKC0_DIV` 会把 VCO 一起改掉、连带毁掉 125 MHz 的 RGMII 时钟。
本次是靠 `REFCLK_DIV/FBCLK_DIV = 5/3` 得到 83.333，VCO 与 C1..C3 完全不动。

`media/constr/media.sdc`、`media.adc` **未改动**（`derive_clocks` 从 PLL 模型取周期）。

### 8.2 综合结果（`media/Runs/syn_v4`，medium + share_arithmetic + min_ripple 16）

| 项 | m2（100 MHz, `-AreaEffort high`） | v4（83.33 MHz, medium/share/min16） | 差 |
|---|---:|---:|---:|
| LUT | 17154 | **16891** | −263 |
| REG | 10757 | 10756 | −1 |
| BRAM9K / BRAM32K | 49 / 5 | 49 / 5 | 0 |
| DSP | 25 | 25 | 0 |

同时验证了"配置性面积"假设：**同一份 RTL 把综合参数从 `high` 换到 `medium/share/min16`
就少了 263 LUT（约 130 Slice）**，这正是本轮 9643 与 ctx66 9339 之间那 304 Slice 的主要来源。

### 8.3 速度影响：只有 SD 读卡带宽会变

| 环节 | 100 MHz | 83.33 MHz | 说明 |
|---|---|---|---|
| SD_CLK（`DIV_FAST=2`） | 25.0 MHz | **20.83 MHz** | 读卡 12.5 → 10.42 MB/s |
| 720p 24bit BMP（2.76 MB）SD 读 | 221 ms | **265 ms** | +44 ms |
| 解码（921600 px @≈1 px/clk） | ≈9 ms | ≈11 ms | 与读并行，非瓶颈 |
| 链路发送（千兆 125 MB/s） | 22 ms | 22 ms | 不变 |
| **切图总时延（含 500 ms 转场）** | ≈0.75 s | **≈0.79 s** | **+5%，不可感** |
| 4096×4096 BMP（48 MB，极端） | 3.85 s | 4.60 s | +0.75 s，仅超大图可感 |
| 13 项 ms/µs 窗口（去抖 50 ms、长按 2 s、双击 300 ms、超时 1 s/15 s/3 s） | — | 宏自动跟随 | **物理时间不变** |
| 协议 HELLO/超时/重试 | 20/100/5 ms | 20/100/5 ms | 已传参，**不变** |
| PCM 音频、字幕滚动、转场 | render 驱动/按帧 | 同 | **不变** |

结论：**唯一变慢的是 SD 读卡带宽（−16.7%），端到端切图时延只增加约 5%**。
若后续实测仍需更快，可改用 87.5 MHz（SD 21.9 MHz / −12.5%），但预算只剩 +1.43 ns。

### 8.4 仿真侧待办

`media/sim/*.v` 的时钟激励目前是 `always #5 clk=~clk`（10 ns = 100 MHz）。
宏改成 83.33 MHz 后，DUT 内部按拍换算的窗口在仿真里会被拉长 20%。
需要把实例化 media DUT 的 TB 半周期改为 `#6`（12 ns = 83.33 MHz），
涉及 `sd_boot_stub.v`、`sd_emergency_stub.v`、`tb_fat32_timeout.v`、`tb_media_overlay_e2e.v`
及 4 个实例化 `media_core/top_media` 的 TB；双板系统 TB 另议（render 仍是 100 MHz）。

---

## 9. 2026-10-30 降频与 RTL 优化实测汇总

### 9.1 时钟路线（同一份 RTL，`-AreaEffort medium -ShareArithmetic -MinRippleLength 16`）

| 总线频率 | PLL 配置 | Slice | 布线 Setup WNS | TNS | 端点 | 结论 |
|---:|---|---:|---:|---:|---:|---|
| 100 MHz | RD1/FB2/DIV0=10 | 9643（布局） | 布线发散（冲突 2368） | — | — | 基线，不可布 |
| 83.33 MHz | RD3/FB5/DIV0=12 | 9518 | −3.151 | −606 | 720 | Phase 6 清冲突 24 min 把时序打崩 |
| 76.92 MHz | RD13/FB20/DIV0=13 | 9361 | −3.061 | −63.5 | 66 | Phase 6 只用 12 s，但最差路径 18.4 ns |
| **50 MHz** | RD1/FB1/DIV0=20 | 9375 | **−0.244** | −0.244 | **1** | 只差一条路径（fat_wav 15 级锥） |
| 45.45 MHz | RD11/FB10/DIV0=22 | 9451 | 布局即 23 端点 | −18.2 | 23 | 卡在 SD 的 `set_max_delay 8.000` 例外路径，与频率无关 |

**关键教训：45.45 MHz 的 bus_clk 余量已达 +7.631 ns，仍"不通过"，说明继续降频无用**——
真正的阻塞是 SD 例外路径与工具崩溃，不是周期预算。

### 9.2 已合入的两处 RTL 优化（均有仿真）

| 文件 | 改动 | 依据 | 验证 |
|---|---|---|---|
| `media/rtl/link/db_link.v` | 描述符 RAM 读出口加 `header_q` 寄存一拍；`send_header` 改用寄存副本；状态 4 采样 | 66 个端点全部来自 `u_descriptors/u_ram.clkb → crc_address.ce`，15.78 ns / net 10.13 ns / fanout 8 | `tb_link` PASS |
| `media/rtl/audio/fat_wav_controller.v` | `want_stop` 预寄存一拍（`want_stop_q`），只用于屏蔽恢复分支 | 50 MHz 唯一违例：`play_status → nxt_cluster.ce`，15 级 / fanout 69 / net 13.84 ns | `tb_fat_wav_controller`、`tb_fat_wav_actual`、`tb_volume_transport` 全部 PASS |

> 注意：曾尝试"把 new/restore 两个使能整体寄存一拍"，`tb_fat_wav_controller` 出现 12 个 FAIL
> （FSM 在 `want_new` 当拍就要用 `nxt_cluster`），已回退为只寄存 `want_stop`。

### 9.3 当前真正的瓶颈：不是时序，是"布局运气"

96% 占用下，同一份网表不同 seeds 的表现分裂成三类：

- 布线收敛且接近零违例（v7 seed3：1 端点）；
- 布线发散（v6s6、v9：冲突从几百涨到一千，线长 3.5–3.7 M）；
- TD 在布局后优化阶段直接 coredump（今天 5 次：18:31、20:19、以及 v8s4/v8s5 等）。

因此**早筛必须看布局**：`place` 约 8 分钟即可判断（0 违例才放行布线），
不能再拿 40 分钟赌一次布线。v9（两处 RTL 优化后）布局是 **0 违例 / bus +4.394**，
但布线发散，属第一类之外的坏样本。

### 9.4 v1（`dual-source-pixel`）对照

v1 在 76 MHz 的三次完整布线为 −2.314 / −2.591 / −1.807 ns，端点 876 / 857 / 1065，
Slice 9423 / 9445 / 9450。**他们同样没有闭合**，只是布局阶段（+0.2~+0.4）看起来接近。
说明这不是本工作区独有的问题，而是该器件在 96% 占用下的普遍行为。



---

## 10. 成功：50 MHz 版本通过零违例签核（2026-10-30 22:30）

### 10.1 最终配置

| 项 | 值 |
|---|---|
| bus_clk | **50 MHz**（PLL: REFCLK_DIV=1, FBCLK_DIV=1, CLKC0_DIV=20；VCO 1000 MHz 不变） |
| SD_CLK | **25 MHz**（DIV_FAST=1，与 100 MHz 版本完全相同，读卡零损失） |
| SD 采样点 | SAMPLE_DLY=0 → 上升沿后 20 ns（50 MHz 下 1 clk），与原 div=2/SAMPLE_DLY=1 同一物理位置 |
| RTL 改动 | `db_link.v` 描述符 RAM 输出寄存一拍（`header_q`，状态 4 采样）；`fat_wav_controller.v` `want_stop` 预寄存（`want_stop_q`，仅用于屏蔽恢复分支） |
| SDC/ADC | 未改动 |

### 10.2 签核结果（`media/Runs/pv9s8`，seed 8）

| 指标 | 值 |
|---|---:|
| Setup WNS / TNS / 违例端点 | **+0.081 ns / 0.0 / 0** |
| Hold WNS / TNS / 违例端点 | **+0.024 ns / 0.0 / 0** |
| Slice | 9441 / 9800（96.34%） |
| LUT / 寄存器 | 16566 / 10846（综合 16623 / 10824） |
| BRAM9K / BRAM32K / DSP | 49 / 5 / 25（余量：15 / 11 / 4） |
| `check-reports.ps1` | **QUALIFIED**（含输入指纹一致性与 bit SHA 校验） |
| bit SHA256 | `bea01982301f1e0284ca1a1b2eb9a39e44d02fceaae9306ddbcf9c8612f8190a` |
| bit 路径 | `media/Runs/pv9s8/MultimediaSystem_media.bit` |

### 10.3 配套仿真（改动面相关，全部 PASS）

`tb_link`、`tb_fat_wav_controller`、`tb_fat_wav_actual`、`tb_volume_transport`、
`tb_bmp_controller`、`tb_settings_menu`。
完整双板回归（`run-regression.ps1`）与实板验收尚未执行。

### 10.4 交付说明与注意点

- 配对：render 用 `MultimediaSystem_v1/build/saturation-zero/reports/final/phy/MultimediaSystem_render.bit`
  （SHA256 `f03ca94b…d0281d30`，零违例已签核）。协议 v1.14 字节级不变，无需重新配对。
- 速度：读卡 25 MHz 不变；只有内部解码/打包时钟减半（本就有 10 倍余量）。
  链路 CRC 吞吐由约 26 MB/s 降到约 15 MB/s，仍低于 SD 读 12.5 MB/s 的主导地位；
  实板验收时需留意大图（4096×4096）加载时长。
- 本轮物理参数：TimingHigh 去掉 `place post_place_opt high`（该参数在 76.92/45.45 MHz
  下两次稳定 coredump），seed 8，`route effort routability` + `route fix_hold on`。
  配置保存在 `media/Runs/pv9s8/settings.cfg`。
- `slice_percent 96.34` 触发脚本的 80% 提示（advisory，非门槛）。
- 并行多实例的坑：4 个 TD 同时跑会在布线初始化阶段集体静默死亡（无 .dmp）；
  给每个实例设独立 `TEMP/TMP` 后 2 个并行可稳定存活。8 并行未验证。
