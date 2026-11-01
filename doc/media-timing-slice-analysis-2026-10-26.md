# media 板 Slice 与时序优化分析（2026-10-26）

目标按用户要求：**保留全部现有功能**，压低 Slice 占用并把 Setup/Hold 违例降到 0。
本文是分析与实测记录，未产出 bit。文中数字均来自 `media/Runs/` 下的实测报告，虚构项已标注。

---

## 0. 结论摘要

1. **9379 Slice 这个"最佳点"从未按 canonical 参数布线。** 它只有 place-only；唯一的完整 route 用的是 `route effort normal`（`tools/dual-board/run-media-placeonly.ps1` 第 24 行硬编码），而不是 `run.ps1` 默认的 `routability`。该次结果 −10.157 ns / 2145 端点，最差路径 net 延迟 17.9 ns、wire length 3.10 M（基线 2.73 M），属于路由器未收敛，**不能当作 9379 版本的时序结论**。
2. **时序主因有两个。** 其一是 `resource_fat_dsp_hold` / `db_sequence_hold` 把 DSP 当寄存器用，在寄存器 D 端硬插了 3.56 ns 的组合 MULT18；其二是 95.7% Slice 造成的布线拥塞，中位违例路径 70–80% 是 net delay。
3. **面积已到"减 LUT 不等于减 Slice"的阶段**：17850 LUT 中有 9930 个与 FF 共用同一 LE，删掉这类 LUT 只把 LE 从 `lut&reg` 变成 `reg-only`，LE 数和 Slice 数都不变。真正要压的是 **LE 总数**。
4. 逐模块看，最大的三块是 `fat_bmp_controller`(2610)、`fat32_ro`(2551)、`db_link`(2234)，它们同时也是三条最差路径的所在，属于"面积与时序同源"。
5. **DSP 当寄存器是一个"1 LUT/bit 换 3.5 ns"的有意取舍**，本轮已实测（§8）。整体撤销要付 +112 Slice 的代价，只撤销最差路径上的 `u_maximum` 是可接受的最小交易。
6. **CLI 复现阻塞已解决**：`run.ps1 -Stage syn` 必然先跑 `project.tcl` 重建 `.al`，重建后 `<LABEL>` 变空会导致 TD 6.2.168116 崩溃；跳过该步、直接对现有 `.al` 跑 flow 可 1:1 复现基线（§7）。
7. **已采纳的最小改动（E4）**：只把 `u_maximum` 从 DSP-hold 换成普通 FF。+5 Slice、LUT −10、place Setup WNS +0.218 → +0.399、wire −7%。完整布线后**违例端点 213 → 110、TNS −31.6 → −22.9**，Hold 零违例；WNS 记为 −1.792 是因为最差路径换成了 `fat32_ro` 内一条 8 级、65% net 的路径，且种子与基线不同（§8.1）。
8. **瓶颈已重新定位**：去掉 MULT18 尾巴后，前七条违例全部落在 `fat32_ro` 内部且 net 占 46–82%。下一步是压这块的密度或扫种子，而不是继续拆逻辑。

---

## 1. 事实核对：先把"能跑的基线"找回来

| 运行 | 参数 | Slice | Setup WNS | Setup TNS | 端点 | Hold | wire |
|---|---|---:|---:|---:|---:|---:|---:|
| `phy_timing_v4_high8_20261022`（唯一合法全布线基线） | seed8 / high / **routability** | 9401 | −0.522 | −31.641 | 213 | +0.022 | 2.73 M |
| `phy_area95_bit_20261026`（9379 唯一一次全布线） | seed4 / high / **normal** | 9379 | −10.157 | −3494.7 | 2145 | +0.030 | 3.10 M |
| `phy_area95_final_audit_20261026`（place-only） | seed4 / high / — | 9379 | +0.218 | — | — | +0.059 | — |

同源 9379 版本在布局阶段是 +0.218 ns，布线后掉到 −10.157 ns，唯一变量是 `route effort`。
`route_flow.status` 显示 route 只跑了 1 次、23m54s，且中间某个阶段曾报 `Congestion: {78.62, 75.54, 73.94, 72.78}; Timing: {-0.805ns, -123ns, 424}`——即路由器中途还算正常，最终却收敛到 −10 ns，属于典型的 effort 不足 + 拥塞不收敛。

**结论：在做任何 RTL 改动之前，先用 9379 的综合数据库按 `routability` 重跑一次 route。** 否则无法判断后续改动是改善还是噪声。

```powershell
# 复用已有的 phy 数据库，只重跑 opt_route，新的物理目录名
./media/build/run.ps1 -Stage phy -RunTag area95_rt2_20261026 `
    -AreaEffort medium -ShareArithmetic -MinRippleLength 16 `
    -PhysicalEffort high -PlaceSeed 4 -RouteEffort routability
```

---

## 2. 面积账本：Slice 由 LE 决定，不由 LUT 决定

放置报告（`phy_area95_bit_20261026/MultimediaSystem_media_phy.area`）：

| 项 | 数值 | 说明 |
|---|---:|---|
| LUT | 17850 / 19600（91.07%） | 每个 LUT 占 1 个 LE |
| 寄存器 | 10398 / 19600（53.05%） | 只有 468 个是"独占 LE" |
| LE 合计 | 18318 | 7920 lut-only + 9930 lut&reg + 468 reg-only |
| Slice | 9379 / 9800 | LE/2 = 9159，多出 220 个是打包不上的"半个 Slice" |

由此得到三条硬结论：

- **删一个"带 FF 的 LUT"＝ 0 Slice**（LE 仍是 1，只是从 `lut&reg` 变成 `reg-only`）。2026-10-26 那轮"固定字段候选少 186 个寄存器、LUT 只从 14049 降到 14035"就是这个机制。
- **只有减少 LE 总数才减 Slice**：要么删掉成对的 LUT+FF，要么删掉独占 LE 的 FF。
- **寄存器只有 53%，把 DSP 里的状态搬回 FF 通常不增 Slice**（FF 可以塞进 7920 个空着 FF 的 lut-only LE），但要实测，最坏情况 +0.5 LE/bit。

因此"再压 69 Slice 到 95%"这条路的性价比已经很低。真正值得追的是 **−300 ~ −500 LE**，把 Slice 拉到 91–92%，让布线有喘息空间——这一条同时也是时序问题的解药（见 3.2）。

---

## 3. 时序账本：三条根因

### 3.1 根因一：DSP 被当成寄存器，凭空多出 3.56 ns

`fat32_ro.v:1462-1485` 的 `resource_fat_dsp_hold` 与 `db_link.v:546-565` 的 `db_sequence_hold`，都用 `EG_PHY_MULT18` 的 `a × 1` 来实现一个"带 CE 的寄存器"：

```verilog
EG_PHY_MULT18 #(.INPUTREGA("DISABLE"), .INPUTREGB("DISABLE"), .OUTPUTREG("ENABLE"), ...)
```

`INPUTREGA=DISABLE` + `OUTPUTREG=ENABLE` 意味着 **组合乘法器串在 D→Q 通路中间**。实测代价（`phy_timing_v4_high8` 最差路径逐元件）：

```
clk2q data_sectors[9]        0.146
LUT4/LUT5 ×3（变量移位与比较） 1.374
ADDER ×8（32 位加/进位链）    2.268
net                         0.808
MULT18 (reg)                3.563   ← 一个"寄存器"吃掉 35% 的时序预算
------------------------------------
Slack  −0.522 ns
```

两条最差路径完全同构：

| 路径 | Slack | 逻辑级 | 其中 MULT18 |
|---|---:|---:|---:|
| `fat32_ro/data_sectors_reg[10]` → `u_maximum/lane[1]$u_hold.a[10]` | −0.522 | 6 | 3.563 ns |
| `db_link/sequence_bank[0]$u_tx/u_low` → `u_high.a[12]` | −0.483 | 3 | ~3.5 ns |

**DSP 用量账**：`db_link` 12 个（3 通道 × tx/rx × 2 lane）、`fat32_ro` 10 个（`u_geometry` 4 + `u_maximum` 2 + `u_pending` 4）。合计 **22 / 28 个 DSP 只是寄存器**，只有 6 个在干算术。

三个改法，按代价排序：

| 方案 | 改动 | 面积代价（实测，见 §8） | 时序收益 | 功能影响 |
|---|---|---|---|---|
| **A 局部换 FF** | 只把 `u_maximum`(32FF) 与 3 个 tx 序号(96FF) 改成普通 `if(ce) q<=d` | **+82 LUT / +128 FF / −8 DSP / +112 Slice** | 两条最差路径回到 ~6.5 ns，+3.4 ns 余量 | 无，逐拍等价 |
| **A′ 最小交易** | 只把 `u_maximum`(32FF) 换 FF | +43 LUT（mapping 阶段实测，最终值见 §8） | 最差路径 −3.5 ns | 无 |
| **B 全量换 FF** | 22 个 DSP-hold 全部改 FF | 约 A 的 2.5 倍 | 约 20 条路径同时去尾 | 无 |
| **C 输入寄存器 + 加一拍** | `INPUTREGA="ENABLE"`、`cea` 提前一拍 | 0 | 同上，但把 3.5 ns 推到 Q 端消费者 | 挂载/序号各多 1 拍 |

**实测修正了一条重要判断**：DSP-hold 不是"白送的优化"，而是**用约 1 个 LUT/bit 换 3.5 ns**——`EG_PHY_MULT18` 的 `cepd` 是专用 CE 引脚，换成普通 FF 后 `enable ? din : q` 的反馈 mux 要占用 LUT（32 位即 32 个 LUT，128 位即 128 个）。所以方案 A 在 95.7% 的占用下**不划算**：+112 Slice 把拥塞推得更糟，布局 WNS 反而从 +218 ps 掉到 +148 ps。C 会把乘法延迟转移到 `max_cluster` / `next_seq` 的 32 位比较树上，风险更高，不建议。**只有 A′ 这种"只动最差一条路径"的规模值得考虑。**

> 关键点：这 3.56 ns 是**与路由质量无关的固定损失**。即使布局再好，只要 D 端有组合运算，这条路就只能在 ~6.5 ns 的净预算里跑，任何 1 ns 的布线抖动都会打成违例。要救它要么付 LUT，要么把 D 端的运算从这一拍移走（例如把 `(max_cluster+1)<<2` 的加一放到前一个已存在的空状态里）。

### 3.2 根因二：95.7% 占用把中位路径的 net delay 推到 1 ns/根

不看最差两条，看第 3–10 名（−0.393 ~ −0.336 ns）就会发现特征完全不同：

| 路径 | Slack | cell | net | 逻辑级 |
|---|---:|---:|---:|---:|
| `occupied_reg[7]` → `file_browser/ext_play_size_reg[24].ce` | −0.393 | 2.804（27%） | **7.309（73%）** | 7 |
| `emergency/block_normal` → `DBG_WAV_STATUS` pad | −0.361 | 2.816（28%） | **7.193（72%）** | 7 |
| `fat32/control_state[6]` → `entry_size_reg[9].ce` | −0.360 | 2.066（20%） | **8.014（80%）** | 6 |
| `fat_bmp/unpack/skip[24]` → `x_reg[2].ce` | −0.342 | 2.324（23%） | **7.738（77%）** | 6 |

**7 级逻辑只值 2.8 ns，连线却要 7–8 ns**，平均每根 net 约 1 ns（正常满载设计 0.3–0.6 ns）。这不是 RTL 逻辑深度问题，是布线距离问题。对应地，32 位寄存器阵列的 CE 引脚被放在离驱动 LUT 很远的 Slice 上。

在这一层，任何"再拆一拍"的微优化都只是把 7 级变 6 级（省 0.4 ns），救不回来。**唯一解是给设计腾出 LE 余量**（第 2 节）**并改善放置**，而不是继续切逻辑。

### 3.3 根因三：跨模块 CE 锥仍然偏长

2026-10-22 那轮已经把"先分类再更新"的模式用在链路接收侧，但 `file_browser` 的素材分类还没做：

`file_browser.v:897-924`，一个 `S_LOAD_RD` 状态里用 4 分支 if/else 同时写 `ext_play_cluster/size`、`ext_load_cluster/size`、`pending_txt/play`、`status_kind`、`draw_return_hot`、`state_hot` 共 8 组寄存器，CE 直接从 `meta_q` 的分类结果铺开。改成：

```
S_LOAD_RD：只把 load_kind[1:0] 与 meta_size 寄存（1 级逻辑）
S_LOAD_APPLY（新增）：按已寄存的 load_kind 无条件写各寄存器（CE = 单状态位）
```

代价：菜单路径多 1 拍（按键 → 发请求，人眼不可见，不涉及任何链路握手）。
收益：一次砍掉 8 条 CE 链上的 5–6 级逻辑，正好覆盖 −0.393 / −0.343 / −0.338 三条路径。

同类还有 `fat_wav_controller.v:369-380`：`P_SEEK` 那一拍里同时做
`data_off + (seek_target << (channels?2:1))` 与 `cap_size - (data_off + (...))`——同一个变量移位和两次 32 位加/减挤在一拍，还要驱动 32 位寄存器 CE。把 `seek_bytes = seek_target << (channels?2:1)` 提前到 `P_SEEK` 入口状态寄存（加 1 个 32 位寄存器），该拍只剩两次加法。

---

## 4. 逐模块清单

按"面积 × 时序相关性"排序。行号对应当前工作树。

| 模块 | LUT | 位置 | 现象 | 改法 | 预期 |
|---|---:|---|---|---|---|
| `fat32_ro` | 2551 | `fat32_ro.v:1453-1459` | 10 个 DSP 当寄存器，`u_maximum` 的 D 端串 3.56 ns | 见 3.1 方案 A | 最差路径 −3.4 ns |
| `fat32_ro` | — | `fat32_ro.v:179-260, 467` | `control_state`(7b 稀疏码) 经 74 项 case 重新编号成 `state`，只喂 `dbg_fat_state`，而后者在 `media_core.v:186/367` 是悬空线 | ~~接常量可省 LUT~~ | **已实测：0 收益**（§8 E2），综合早已剪除，勿再动 |
| `fat32_ro` | — | `fat32_ro.v:963-1014` | 挂载几何拆成 GEOM1/2/3/3_CHECK/4/4B/4C/4D/4E/5 共 10 个状态，每个状态一次 32 位运算 | 这 10 个状态只在一次挂载里走一遍，可合并成 2–3 拍（挂载只在上电发生，多拍无感）；同时省 10 个状态译码项 | ~40–60 LUT |
| `fat32_ro` | — | `fat32_ro.v:434, 438` | 两个 32 位变量移位器（`(walk_cluster-2)<<cluster_shift`、`data_sectors>>cluster_shift`）+ 一个 32 位减法器 | 移位量只有 3 位且挂载期已知，可换成"预先算好的 4 个常移位 + 4:1 mux"或直接用 DSP 做（见下） | ~50 LUT / 个 |
| `db_link` | 2234 | `db_link.v:36-37` | `boot_counter` **56 位**自由计数器，仅用于生成 `session_nonce` | 24 位足够（非零熵，握手只看随机数），省 32 个 ripple LE | ~16 Slice |
| `db_link` | — | `db_link.v:527-543` | 3 通道 × (tx,rx) 全用 DSP-hold，共 12 DSP | 方案 A 只改 tx 三路（96 FF）；rx 侧保持 DSP | 路径 −0.483 消除 |
| `fat_wav_controller` | 1109 | `fat_wav_controller.v:369-380` | `P_SEEK` 一拍内两次 32 位运算 + 变量移位 | 提前寄存 `seek_bytes` | 见 3.3 |
| `file_browser` | 1357 | `file_browser.v:897-924` | 4 分支 if/else 同时写 8 组寄存器 | 拆出 `S_LOAD_APPLY` | 见 3.3 |
| `emergency` | 329 | `media_core.v:701` | `DBG_WAV_STATUS` 由 `emergency/block_normal` 起 7 级逻辑直出 pad，net 7.2 ns | 在 `media_core` 把该 8 位调试输出整体打一拍 | −0.361 消除 |
| `fat_bmp_controller` | 2610 | `pipeline/scaler` 825/631 | 最近邻缩放里的 `xrem/yden` 17 位比较、3 个 `row_x` 比较 | 边距/行边界提前算；收益需实测 | 未定 |

> 注：`media_core.v:186` 里 `dbg_dir_entry_count`（32 位计数器）同样悬空；按 E2 的结论，综合会剪除，不必处理。

---

## 5. 建议执行顺序（已按本轮实测调整）

**第 0 步（已完成）**：拿到可复现的综合入口（§7）。基线 1:1 复现，14479 / 16667 / 10430 / 28 DSP。

**第 1 步（已采纳，E4）**：只把 `u_maximum` 换成普通 FF。实测 +5 Slice、LUT −10、place Setup WNS +0.218 → +0.399、wire −7%；完整布线后违例端点 213 → 110、TNS −22.9、Hold 零违例（§8.1）。改动见 `fat32_ro.v` 的 `resource_fat_ff_hold`。

**第 2 步（待评估）**：3.3 的两处 CE 拆分（`file_browser` 的 `S_LOAD_APPLY`、`fat_wav_controller` 的 `seek_bytes` 预寄存）。这两处只动菜单/快进路径，各多 1 拍，不碰链路握手，理论上既省逻辑又削 L1–L3 级延迟，**必须实测 Slice 后再收**。

**第 3 步（不做）**：撤销其余 DSP-hold（E3 已证 +112 Slice 且 place WNS 变差）；收窄 `boot_counter` 之类的小改动（56→24 位只省 16 Slice，优先级低于前两步）。

**第 4 步（物理）**：在拿到第 2 步的面积结果后，对最终候选做 seed / effort 扫描，只跑 place-only 初筛，前 2 名再完整 route。

**验证门槛**（沿用现有脚本，不放宽）：
```powershell
./media/sim/run.ps1 -Test tb_fat32_ro -SingleSector
./media/sim/run.ps1 -Test tb_bmp_controller -CancelGlitch
./media/sim/run.ps1 -Test tb_link
./tools/dual-board/run-regression.ps1
./media/build/check-reports.ps1 -RunDir ./media/Runs/phy_<tag>
```

---

## 6. 风险与不做什么

- **不要再用 `route effort normal` 评估时序**：本轮的 −10.157 ns 就是这么来的。
- **不要靠"删 LUT"冲 95% 指标**：3.1 与第 2 节都表明 LE 才是口径；为凑 9310 而改逻辑，会把本来就紧的时序换成更差的布线。
- **不要把 DSP-hold 换成 BRAM-hold**：2026-10-26 已试（`phy_area95_bramhold_equiv`），布局 setup −2.560 ns，已撤回。
- **不要动时钟、SDC、false path**：现有 SDC 已处理 RGMII RX 的 phantom hold，再加 `set_min_delay` 会复现 −2.145 ns。

---

## 7. CLI 复现阻塞：原因与绕法

**现象**：`./build/run.ps1 -Stage syn ...` 连续 3 次失败（2 次 elaborate 后 `Oops! coredump`，1 次在 `SYN-2551 Post LUT mapping optimization` 静默退出）。同一参数 2026-10-26 17:49 曾成功，看似工具随机不稳定。

**真实原因**：`run.ps1` 在 `-Stage syn` 时**先执行 `build/project.tcl` 重建 `.al`**，重建后 `TOP_MODULE` 的 `<LABEL>` 变成空：

```xml
<TOP_MODULE><LABEL></LABEL><MODULE>top_media</MODULE></TOP_MODULE>
```

这个空标签使 TD 6.2.168116 在综合中崩溃。历史记录里"工具生成的 `.al` 空标签等临时改动恢复"讲的就是这件事，但没人把它和崩溃联系起来。

**绕法（已验证 1:1 复现基线）**：跳过工程重建，直接对现有 `.al` 跑同一个 flow。

```powershell
$run='media/Runs/syn_<tag>'
New-Item -ItemType Directory -Force $run | Out-Null
Copy-Item media/Runs/syn_area95_final_20261026/settings.cfg $run/
# entry.tcl：把下面路径里的 <tag> 换掉
@'
source ./settings.cfg
cd {D:/AnLu_FPGA_project/MultimediaSystem_v1/media}
open_project MultimediaSystem_media.al
cd {D:/AnLu_FPGA_project/MultimediaSystem_v1/media/Runs/syn_<tag>}
set singleRun 1
source {D:/AnLu_FPGA_environment/doc/scripts/DefaultFlow.tcl}
'@ | Set-Content $run/entry.tcl
Push-Location $run; & 'D:/AnLu_FPGA_environment/bin/td_commands_prompt.exe' entry.tcl *> console.txt; Pop-Location
```

首次复现结果与 `syn_area95_final_20261026` **逐项相同**（14479 / 16667 / 10430 / 28 DSP），耗时 2m41s。

**布局**：`run-media-placeonly.ps1` 需要该目录下的 `inputs.json`，先跑一次
`./media/build/input-fingerprint.ps1 -Output <run>/inputs.json` 即可，其后流程不变。

**待修**：`build/project.tcl` 生成 `.al` 时应写入正确的 `<LABEL>`，否则所有人跑 `-Stage all` 都会崩。这是构建脚本缺陷，不是工具缺陷。

---

## 8. 本轮实测记录（2026-10-26 19:00–19:50）

全部使用同一综合参数（`area_prior` / `infer_fsm off` / `add_map_lut_struct on` / `adder_mux_unsharing off` / `min_ripple_len 16`），布局统一 seed4 / high / `crit_path_opt off`。

| 探针 | 改动 | Total LUT | LUT | REG | DSP | Slice | place Setup WNS | place Hold WNS |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 基线 | 无（复现 `syn_area95_final`） | 14479 | 16667 | 10430 | 28 | 9379 | +0.218 | +0.059 |
| E2 | `dbg_fat_state` 接 0 | 14479 | 16667 | 10430 | 28 | — | — | — |
| E3 | `u_maximum` + 3 路 tx 序号换 FF | 14561 | 16749 | 10558 | 20 | 9491 | +0.148 | +0.059 |
| E4 | 仅 `u_maximum` 换 FF | 14469 | 16657 | 10462 | 26 | **9384** | **+0.399** | +0.059 |

E4 的布局其它指标（对比基线）：wire length 1,251,475 vs 1,344,237（−7%），Top1% tile 占用 75 / 77.24% vs 76 / 78.31%，`Over 100% util #tile` 均为 0。

### 8.1 E4 的完整布线（`routability`，seed4）

`media/Runs/phy_probe4_rt_20261026`，从 E4 布局数据库以 `opt_route → bitgen` 起跑：

| 指标 | 基线 `phy_timing_v4_high8`（seed8，原 RTL） | E4 `phy_probe4_rt`（seed4） |
|---|---:|---:|
| Slice | 9401 | 9384 |
| Setup WNS / ns | −0.522 | −1.792 |
| Setup TNS / ns | −31.641 | **−22.864** |
| Setup 违例端点 | 213 | **110** |
| Hold WNS / ns | +0.022 | +0.024 |
| Hold 违例端点 | 0 | **0** |
| Wire length | 2,725,296 | 2,962,752 |
| DSP | 28 | 26 |

**读法**：违例端点减半（213 → 110）、TNS 改善 28%，但 **WNS 反而变差**。两者不矛盾——去掉 MULT18 之后，最差路径换人了。新的前七条违例全部在 `fat32_ro` 内部，特征是：

| Slack | 逻辑级 | cell | net | net 占比 |
|---:|---:|---:|---:|---:|
| −1.792 | 8 | 4.047 | 7.465 | 65% |
| −1.433 | 7 | 2.884 | 8.269 | 75% |
| −1.051 | 5 | 5.363 | 5.408 | 51% |
| −1.041 | 6 | 5.854 | 4.907 | 46% |
| −1.018 | 7 | 4.010 | 6.937 | 64% |

也就是 §3.2 描述的现象在 `fat32_ro` 上集中爆发：**逻辑只有 5–8 级、2–6 ns，连线却要 5–8 ns**。FAT 这块 2551 LUT 的逻辑被铺得很散，CE 网和 32 位比较网横跨芯片。

> 注意：E4 用的是 seed4，基线最佳是 seed8，**种子不同不能直接比 WNS**。但端点数和 TNS 的方向性改善、以及"前七条违例全在本模块且 net 主导"这个结构特征，与种子无关。

**结论**：DSP 尾巴不是最终瓶颈，`fat32_ro` 的物理密度才是。后续要么压这块的 LUT（让它铺得下），要么做 seed 扫描——而不是继续拆逻辑。

结论：

- **E2 收益为 0**，`state` 重编号译码已被综合剪除。今后不必再为调试别名做优化，也不必为它保留"未实测"的悬念。
- **E3 不划算**：+82 LUT / +128 FF / +112 Slice（96.85%），布局 WNS 从 +0.218 掉到 +0.148。理由是 DSP 的 `cepd` 是专用 CE，换 FF 后 `enable ? din : q` 的反馈 mux 要花 ~1 LUT/bit。
- **E4 基本免费**：LUT −10、只 +32 FF、DSP −2。这是唯一值得保留的版本，它只砍最差那条路径上的 3.56 ns。

> 注意：布局阶段的 WNS 只有 +0.15~0.22 ns 且不含真实 net delay，**不能用来判断 E3/E4 的时序价值**——本轮三条最差路径的违例全部出现在布线后，那里 cell delay 占 69%、MULT18 占 3.5 ns。E4 的价值必须用一次完整 route 才能确认。

---

## 9. 未完成项与下一步

1. **种子扫描**：E4 只在 seed4 上布过。基线最佳是 seed8；在 9384 Slice 的前提下扫 4 个种子（每个 place-only 约 8 分钟，只对前 2 名做完整 route），是最省力的下一步。
2. **压 `fat32_ro` 的物理密度**：E4 布线后七条最差路径全在该模块内，且 46–82% 是 net delay。有效手段只有减 LE 或改布局约束，拆逻辑无效（已经拆到 5–8 级了）。
3. 第 4 节表格中除 E2/E3/E4 三行外的"预期"列仍是按路径结构与级数推算的量级，**不是实测值**。
4. E4 通过了三项板内回归：`tb_fat32_ro -SingleSector`、`tb_bmp_controller -CancelGlitch`、`tb_fat32_directory`，均 PASS。完整回归（`run-regression.ps1`）与实板验收未做，**不能据此生成或发布 bit**。
5. 测量完成后对 `fat32_ro.v` 做了一处纯格式修整（把 `resource_fat_dsp_hold` 的端口声明从一个折行恢复为两行）。逻辑与网表不受影响，但**源码 sha256 已变**，若要复现 §8 的数字需重新生成 `inputs.json`（`input-fingerprint.ps1`）后再跑。

---

## 10. 第二轮：RTL 逻辑重构尝试与种子扫描（2026-10-26 19:40–22:10）

### 10.1 RTL 重构尝试记录（未成功，原因未定位）

目标：把 `fat32_ro` 里 32 位幅值比较（布线后 8 级 LUT、−1.792 ns 的最差路径）压到 4 级。

| # | 写法 | 结果 |
|---|---|---|
| 1 | 借位减法 `({1'b0,a} - {1'b0,b} - 1)[32]` | TD 崩溃 |
| 2 | 高/低 16 位分段比较 + 6 个中间寄存器（挂在 GEOM4D/4E） | TD 崩溃 |
| 3 | 同上 + EOC 判定改 `&fat_q[27:3]` | TD 崩溃 |
| 4 | 同拍分段表达式（无新增寄存器，6 级 vs 原 8 级） | TD 崩溃 |
| 5 | 比较全部移出主 FSM，放独立 always 块 | TD 崩溃 |
| 6 | 同上但第二块不再译码 `control_state`（无条件流水） | TD 崩溃 |
| 7 | 同上，16 位切片先落独立 wire 再比较 | TD 崩溃 |
| 8 | 封装成独立子模块 `fat_gt32`（模块边界隔离） | TD 崩溃 |
| — | 等价中介 wire（表达式一字不改，只起个名字） | 通过，+38 LUT，无收益 |

**对照实验（关键）**：在完全相同的目录结构、相同 `settings.cfg`、单进程、同一 `.al` 下，把 `fat32_ro.v` 恢复成 E4 版本（`syn_p10_20261026`）——**综合正常通过，且结果与 E4 检查点逐项相同（14469 / 16657）**，说明流程可复现、环境健康。所以不是环境退化、不是并发、不是 `.al` 状态。

另一个方向的对照（`syn_p11_20261026`）：只加一条 `root_cluster[31:16]>max_cluster[31:16]` 的 part-select 比较、接到一个调试输出口、**不参与 FSM 逻辑** → 也正常通过（14498 / 16686，+29 LUT）。也就是说 part-select 比较本身没问题，崩溃只发生在**把喂给 `geom5_bad` 的那个 32 位比较结果换成等价分解形式**时。

**已排除的因素**（逐项核对过）：

- `.al` 空标签：本轮全部跳过 `project.tcl`。
- 行尾/BOM：当前文件 1513 行全部 CRLF，无 BOM，与原文件一致。
- 编码：原文件与改写后均为 UTF-8；把新增中文注释换成 ASCII 后（#8）仍然崩。
- 并发实例：清空全部残留 `td_commands_prompt.exe` 后单进程复现。
- 综合选项：`-AreaEffort high`（#9）、去掉 `gate multi_thread_mapping partition`（#10）都同样崩。
- 代码合法性：以上每种写法都被 ModelSim 接受，`tb_fat32_ro -SingleSector` 全部 PASS（含全部簇几何、碎片化、环检测、超级软盘）。

**8 种写法全部崩溃、对照组全部通过。因此不能断言这是 TD 的缺陷**——更可能是我还没找到的某种写法或选项组合。三次崩溃都停在 elaborate 结束、"Inferred 16 RAMs" 之前，位置完全一致，说明是同一处内部处理。**留待 TD 支持或换版本验证**，本机不再试。

对后续工作的实际含义：`fat32_ro` 的挂载几何判定目前**改不动**。要继续推这条路径，建议改用模块边界隔离（把这段比较放进独立子模块），或直接向厂商提交 minidump。

### 10.2 种子扫描（E4 RTL，布局参数完全一致）

| seed | Slice | 占用 | place WNS | place Hold | wire | 布线 WNS | 布线 TNS | 违例端点 | Hold 端点 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **4** | 9384 | 95.76% | +0.399 | +0.059 | 1,251,475 | **−1.792** | **−22.864** | **110** | 0 |
| 8 | **9316** | **95.06%** | +0.196 | +0.109 | 1,288,324 | −2.606 | −221.635 | 527 | 0 |
| 12 | 9402 | 95.94% | −2.039 | +0.059 | 1,359,108 | 未跑 | — | — | — |

两条结论：

1. **place WNS 不能预测布线 WNS。** seed4 布局 +0.399 → 布线 −1.792；seed8 布局 +0.196 → 布线 −2.606。0.2 ns 的布局差在布线后被放大成 0.8 ns 的反向差。选种子必须看布线，不能看布局。
2. **Slice 少不代表时序好。** seed8 的 9316（95.06%，离 95% 目标只差 6 个）是三者最低，布线却是最差。面积与可布线性在这块器件上没有正相关。

### 10.3 两个参数问题

- **`place crit_path_opt` 在本流程里是空操作。** on / off 两版布局的 `place.qor` 数值逐项相同（WNS 399、wire 1,251,475、Slice 9384）。项目历史上曾为它反复调参，实际不起作用。
- **本文所有布线结果不能与 2026-10-22 的 −0.522 ns 直接比较。** 那一版是 `-AreaEffort high` + seed8；本文全部是 `-AreaEffort medium -ShareArithmetic -MinRippleLength 16`（9379/9384 这两个面积检查点用的就是后者）+ seed4。**综合参数不同 = 不同网表**。要做同源对比，还缺一次"原 RTL + medium 配置 + seed4"的完整布线。

### 10.4 当前最好结果

`phy_probe4_rt_20261026`：Setup WNS −1.792 ns、TNS −22.864 ns、**110 个违例端点**、Hold 零违例、9384 Slice。TNS/端点数 ≈ −0.21 ns/点，说明**绝大多数违例是擦边**，真正难看的只有前 7 条（全部在 `fat32_ro`，net 占 46–82%）。

距离零违例还差：把 `fat32_ro` 的物理密度降下来，或换一个能把这块逻辑铺开的种子。前者被 10.1 那组尚未定位的综合崩溃挡住，后者在 seed 4/8/12 里没有找到更好的。
