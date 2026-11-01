# render 链路发送 CE 预寄存（2026-10-31）

频谱圆头改动后 render 重新布局布线始终无法复现签核版的 +0.052 ns。逐路径分析发现，最差路径不是频谱逻辑，而是链路模块 125 MHz 发送域里的一个字头预取使能。本次只改这一条路径的控制时序，不改变任何字节流。

## 问题路径

`high effort + seed 4` 那一轮的最差路径：

```
u_link/byte_count_reg[7]  →  u_link/tx_header_word_reg[18].ce
时钟 mem_tx_clk (125 MHz, 8.000 ns)
数据路径 7.966 ns：单元 2.118 ns (26%) + 线延迟 5.848 ns (74%)
逻辑级数 6（LUT3×4 / LUT5 / LUT4），最后一段 fanout 26 的 CE 网 2.505 ns
```

`tx_header_word` 是 32 位寄存器，使能条件 `byte_count==13 || (tx_header_region && header_index[1:0]==3)` 是从计数器出发的六级组合锥，再扇出到 26 个 CE 引脚，且被布局到离寄存器很远的位置。

## 修改

[db_link.v](../../render/rtl/link/db_link.v) 的发送状态机里，`byte_count` / `header_index` 在 state 3 每个周期确定性加一，因此**下一拍**的预取条件可以提前一个周期算好并寄存：

```verilog
wire [7:0] tx_bc_next = (tx_state==1) ? 8'd1 : (tx_state==2) ? 8'd2 : byte_count+1'b1;
wire [4:0] tx_hi_next = (tx_state==1) ? 5'd19 : (tx_state==2) ? 5'd20 : header_index+1'b1;
wire tx_hr_next = (tx_state==3 && byte_count==13) ? 1'b1 :
                  (tx_state==3 && byte_count==45) ? 1'b0 : tx_header_region;
wire tx_next_state3 = (tx_state==2 && mac_tx_ack) ||
                      (tx_state==3 && (byte_count+1'b1!=total_bytes));
wire tx_header_ce_next = tx_next_state3 &&
    (tx_bc_next==8'd13 || (tx_hr_next && tx_hi_next[1:0]==3));
always @(posedge mac_tx_clk or posedge tx_rst)
    if(tx_rst) tx_header_ce_q<=0; else tx_header_ce_q<=tx_header_ce_next;
```

`tx_header_word` / `tx_header_word_index` 的装载改用 `tx_header_ce_q`。CE 引脚现在直接由触发器驱动，原来六级组合锥退到触发器 D 端（只有 1 个负载，8 ns 内轻松满足）。寄存器总数不变，综合 LUT 反而少 19 个（共享锥被拆掉）。

只改了 render 的副本；media 的 `db_link.v` 保持不动（媒体板 50 MHz 已签核，不需要动）。两份实现内部结构不同，但 MAC 线上字节流完全一致。

## 行为等价

- `tb_link`、`tb_link_keepalive`、`tb_session_stability`、`tb_temac_gate` 全部 PASS。
- `tools/dual-board/check-link-wire-equivalence.py --board render --reference-revision HEAD`：**PASS MAC bytes and timestamps**，两段抓取 39,320 B / 4,500 B，SHA256 与 HEAD 完全一致。

## 结果

同配置（area_prior、infer_fsm off、area effort high、physical effort medium、seed 4）对比：

| 指标 | 改前（仅圆头） | 改后（圆头 + CE 预寄存） |
|---|---:|---:|
| Setup WNS | −1.566 ns | **−0.311 ns** |
| Setup TNS | −24.763 ns | −0.348 ns |
| Setup 违例端点 | 50 | **2** |
| Hold WNS / 违例 | +0.022 / 0 | +0.022 / 0 |
| Slice | 9,640（98.37%） | 9,611（98.07%） |
| 综合 LUT | 13,071 | 13,052 |

125 MHz 的 `tx_header_word.ce` 已从最差路径列表消失。剩余 2 个端点都在 bus_clk：`u_link/u_receive/header_q_reg[24] → order_r_reg`，数据路径 10.031 ns（74% 线延迟），仍是长线 + 6 级逻辑。

## 签核结果（2026-11-01）

为避开工作树里另一会话未提交的帧缓存实验（`frame_read_write.v` BURST_SIZE、`frame_fifo_read_dual.v`、`build/run.ps1`），签核在隔离 worktree 中完成：`HEAD 618bd69` + 本文件的 `db_link.v` 与频谱圆头的 `osd_paint_anim.v`，其余文件与 HEAD 一致。

同一网表扫种子（medium effort）：

| seed | Setup WNS | 违例端点 | Slice |
|---|---:|---:|---:|
| 1 | −0.220 | 9 | 9,660 |
| 2 | −1.295 | — | — |
| 3 | −0.205 | 9 | — |
| 4 | −0.311 | 2 | 9,611 |
| 5 | −2.056 | — | — |
| **6** | **+0.104** | **0** | **9,605（98.01%）** |

seed 6 签核数据：Setup WNS +0.104 ns、TNS 0、0 违例端点；Hold WNS +0.022 ns、TNS 0、0 违例；BRAM9K 64、BRAM32K 16、DSP 29。逐时钟 Setup WNS：video +0.203、bus +0.104、mem_tx +0.136、rx +0.439、hdmi_5x +0.888。

| 项目 | 值 |
|---|---|
| bit | `render/Runs/phy_ce_s6/MultimediaSystem_render.bit` |
| SHA256 | `57ecdeae3401fa7fc04270513028868dccfd64d5756822b425538de4b170e1df` |
| 报告 | 同目录 `final.qor`、`route.qor`、`final_timing.rpt`、`phy_inputs.json`、`syn_inputs.json` |
| 构建配置 | `area_prior`、`infer_fsm off`、area effort high、physical effort medium、PlaceSeed 6 |
| 正式检查 | `check-reports.ps1` → **QUALIFIED**（需用 pwsh 7；Windows PowerShell 5.1 会在 `ConvertFrom-Json -AsHashtable` 处报错） |

构建目录保存在隔离 worktree `D:/AnLu_FPGA_project/MM_CE_SIGN/render/Runs/phy_ce/`。该 bit 与主工作树当前 render RTL 的两处改动一致，但**不包含**另一会话未提交的帧缓存改动。

## 状态

已签核（2026-11-01），可上板；media 侧继续使用签核版 bit，协议未变。实板验收另行记录。
