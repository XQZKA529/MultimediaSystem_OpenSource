# media 时序继续优化实测

用户要求：现有功能与逐拍接口行为保持不变，Setup/Hold 零违例，资源不超过器件容量，然后交付 bit。80%/95% Slice 目标不是本次硬门槛；不修改时钟和时序例外。

## 对前一份记录的核查

- `phy_probe4_rt_20261026` 最差路径确实在 `fat32_ro`：`root_cluster` 到 `geom5_bad`，8 级 LUT，cell 4.047 ns、net 7.465 ns，WNS -1.792 ns。其余主要违例也在 FAT 内。
- “net 占比高，所以只能降低物理密度，拆逻辑无效”并不成立。低扇出比较树也可能同时具有逻辑深度和局部放置问题。应以同配置的完整布线验证改写效果。
- 历史比较混用了综合参数、种子和 route effort，不能用这些结果直接推导单一改动的收益；place WNS 也不能代替 routed WNS。
- 反复阻塞是改写比较器后 TD 在 elaborate 之后崩溃。此前八种写法失败并不意味着所有等价 RTL 写法均不可综合。本次 8 位分组比较写法完成综合，越过了该阻塞；尚未据此确定旧崩溃的底层原因。
- 增加可见周期、缩短 nonce 计数器等建议不用于本次优化。

## 候选 cmp8

只替换 `root_cluster>max_cluster`、`cluster_x4>fat_bytes` 两个表达式。比较器按四个字节并行生成 greater/equal，再按高字节优先关系合并。不增删状态、寄存器、握手或时钟周期。

相对于本次开始时保存的 E4 工作树：综合 Total LUT 14469 → 14568，器件 LUT 16657 → 16756，REG 10462 不变，DSP 26 不变。这里增加的面积是否值得，必须由布线结果决定。

验证证据位于 `build/timing-closure-20261026/`：

- `fat32_ro.baseline.v`：修改前快照，保留用户已有 E4 修改。
- `prove_comparator.py` / `comparator-proof.txt`：从 RTL 提取分组表达式，用 SMT 验证全部 2^64 组二值输入均等价于无符号 `>`，结果 UNSAT。
- `check_cycle_equivalence.py` / `equivalence/`：原版和候选版同时接受现有 FAT 测试刺激，每周期比较全部已连接输出。`tb_fat32_ro`、`tb_fat32_directory`、`tb_fat32_map`、`tb_fat32_timeout` 均通过。
- `cmp8-fat-sim.log`：现有 `tb_fat32_ro -SingleSector` 通过。
- `full-regression.log`：完整双板回归执行日志。

## 物理试验

所有本次物理试验均使用 `route effort routability`、原 SDC/ADC、集成 hold 修复及原 flow 的额外 `fix_hold`。每次保留独立 settings、输入指纹、最终报告与数据库。

- `syn_close_cmp8`：medium / shared arithmetic / min ripple 16。
- `phy_close_cmp8_s4`、`phy_close_cmp8_s10` 等：完整布线，不能将 place-only 结果视作达标。
- `syn_close_cmp8_high`：与历史较好结果相同的 high 综合配置，另行验证，避免仅扫描同一种综合策略。

首轮完整布线：

| 配置 | Seed | Slice | Setup WNS/ns | TNS/ns | 违例端点 | Hold 端点 |
|---|---:|---:|---:|---:|---:|---:|
| cmp8 / medium | 4 | 9393 | -2.878 | -310.948 | 640 | 0 |
| cmp8 / medium | 10 | 9420 | -3.138 | -303.493 | 555 | 0 |

这两次整体时序均变差，不能认定候选已成功。最差路径转到其他模块，也不能单靠默认前十条路径判断 FAT 的实际收益。

因此对 seed4 的最终 `pr.db` 单独执行 `report_timing_path -to [get_regs -hier -full_hier {*fat32_ro/geom5_bad*}]`：该寄存器的最差 Setup slack 为 **-0.138 ns**，7 级 LUT，cell 3.246 ns、net 6.612 ns。对比原同类路径 -1.792 ns / 8 级 / cell 4.047 ns / net 7.465 ns，局部比较锥确有改善，但全设计仍未闭合。证据：`cmp8-s4-geometry.timing`。

另外核对历史 `phy_timing_v4_high8_20261022/settings.cfg`，发现其中还有 **`place relaxation 0.85`**。前一份记录遗漏了这一物理参数，因此历史结果与新试验的差异并不只有综合选项、种子。后续增加同参数对照；原 SDC/ADC 保持不变。

隔离 `geom5_bad` 写入的 private 候选已完成综合：Total LUT 14495、器件 LUT 16683、REG 10462、DSP 26；四组逐周期输出对照均通过。放在独立副本中布线，尚未替换当前工作树。

后续结果待最终布线报告更新。此处未宣称时序已达标。

## 进一步核对与试验

1. **历史基线输入并不相同。** `syn_timing_v4_20261022/inputs.json` 与本次输入有 25 项哈希差异，包括 `db_link.v`、`seam_media.v`、`media_core.v`、多个音视频模块和构建脚本。哈希差异不等于已证明逻辑差异，但足以说明不能只按“综合参数和种子不同”解释历史结果。`syn_probe4_20261026` 与本次相比则仅 FAT 源文件不同，适合作为近期对照。
2. **carry 候选可综合。** 用 `{1'b0,b}-{1'b0,a}` 的 bit32 实现 `a>b`，保持 unsigned/32 位/逐拍接口，SMT 全输入空间检查及四组 FAT 逐周期全输出对照通过。综合 Total LUT 14479、器件 LUT 16719、REG 10462、DSP 26。此写法没有复现旧记录中借位重构的综合崩溃。
3. **one-hot 没有直接获益。** 综合识别 25 个 FSM，布局 9664 Slice（98.61%）；其后路由冲突长时间不收敛，停止该试验，保留 `trial-aborted.json`。不能把其布局时序写成最终时序。
4. **五组生命周期复用未显示明确面积优势。** Total LUT 14590、REG 10345：相对 carry 版少 117 FF，却多 111 LUT，印证“减 FF 不等于减 LE/Slice”。仍仅保存在隔离候选中，未采纳。
5. **按本次容量要求重新评估 DSP-hold→FF。** 本次不设 95% Slice 硬限。`allff` 候选去除剩余 FAT/context/sequence 的 x1 DSP 寄存用途，保留时钟沿、异步复位、enable、clear 优先级和全部数据位。四组 FAT 周期对照、链路功能、1,800,021 次序号 carry/stall/clear 比较均通过。最终取舍看资源及完整布线。
6. **完整回归未通过，未隐瞒或改业务 RTL。** 原脚本在 `tb_emergency_system.v:148` 的 `incomplete business completion` 失败；该测试实例未使用 FAT 模块。此前真实 FAT/media_core/WAV 的多种 emergency integration 测试均通过。继续执行其余单元回归时，`tb_media_source.v:82` 因 UI 完成超时失败，该测试也未实例化 FAT。日志分别为 `full-regression.log`、`remaining-regression.log`。不能将这两次执行记作完整回归 PASS。

全部本次最终布线结果由 `build/timing-closure-20261026/summarize.py` 汇总至 `routed-results.json`；失败或提前停止的运行不冒充最终时序结果。

## 2026-10-27 继续收敛（进行中）

目前最好的无工具错误结果是隔离候选 `pipe/media/Runs/phy_pipe_s7h100`：最终 Setup WNS **-0.692 ns**、TNS **-8.103 ns**、**33** 个违例端点；最终 Hold WNS **+0.037 ns**、TNS 0、0 个违例端点；9478/9800 Slice。尚未达标，不能交付为零违例 bit。注意 `final_timing.rpt` 在最后一次额外 hold 修复之前生成，最终 hold 数字应核对修复之后的 `MultimediaSystem_media_phy.ts` 和 `final.qor`，不能混用不同阶段的统计。

`pipe` 基于本次开始的 E4，而非 cmp8：在已有 GEOM4C 中预计算 root/max 的高低 16 位比较，GEOM4D 使用三个比较位。原状态转移、接口时刻及几何合法性检查保留。比 E4 多 4 个 Total LUT、3 FF，DSP 数不变。数学比较全输入空间检查通过，四组 FAT 输出逐周期对照通过，并在比较周期断言操作数与预计算值一致。主工作树 FAT 已恢复本次开始时的原始快照；所有候选独立存放，避免把未获益试验混进交付源文件。

这次最佳版本的最差路径已经变成播放列表 BRAM→32 位簇号相等比较→游标寄存器（5 级 LUT，cell 5.612 ns，net 4.728 ns），另有 BMP 写控制路径。因此“目前只需继续降低 FAT 物理密度”已不准确。当前正在验证播放列表并行比较（32 位选择器移到相等比较之后），以及簇号 bank 单独使用分布式 RAM 的候选。两者均保留原同步读写和全部状态周期；深度 4/16/64、饱和计数、扫描中每拍变化的 restore target、重叠控制和复位的随机逐拍输出/内部状态对照均通过。物理收益尚待完整布线验证。

另有几点取舍：全 FF storage 候选最佳 WNS -0.867 ns，未超过 pipe；综合 balance_explore 虽减少 Total LUT，却因器件映射/打包导致 Slice 超限或严重拥塞，未采纳；TimingUltra 有运行在日志中出现 `PHY-8103 ERROR: x_offset.size() <=0`，即使留下报告也不纳入可交付结果。种子扫描保留每次独立报告，既检查时序，也检查工具错误和资源。

### 全部违例与新的对照

重新从最佳 seed7 的最终 `pr.db` 导出 500 端点报告（`pipe-s7-all-violations.rpt`）：33 个 setup 违例中，播放列表 17 个、BMP 9 个、其他 5 个、FAT 2 个。FAT 两个端点分别仅为 -0.013 ns 和 -0.005 ns。此次完整展开支持“主要问题已经转移”的判断，避免只看前十条路径。

截至 01:50，新试验均尚未超过最佳版本：

| 试验 | Seed | 最终 WNS/ns | TNS/ns | Hold WNS/ns | 说明 |
|---|---:|---:|---:|---:|---|
| pipe / high | 9 | -2.278 | -175.938 | +0.030 | 完整布线 |
| pipe / high | 10 | -1.876 | -107.442 | +0.024 | 完整布线 |
| pipe / 官方 TimingHigh | 7 | -0.692 | -8.103 | +0.037 | 复现既有最佳，未产生额外收益 |
| playlist 并行比较 / high | 7 | -2.435 | -264.746 | +0.024 | 最差转为 emergency/BMP 长连线，不能采纳 |
| playlist 簇号 DRAM / high | 7 | -4.631 | -986.193 | +0.024 | 少 2 BRAM 也未带来整体收益 |
| allff / 禁止跨模块优化 / CongestionHigh | 7 | -9.494 | -1082.109 | +0.024 | 停止该方向 |

官方 TimingHigh 的 seed8 与原 high 的整个布局时序报告（仅去除时间戳）完全一致，因此停止重复布线；不能把换策略名称算作独立收益。带有 PHY-8103 错误、持续数小时拥塞不收敛的旧 ultra seed5 也已停止并写明原因，保留日志。

新增 `catalogmux` 独立候选：目录表 `catalog_write` 必须处于 C_DIR，而 `ctx_ready` 排除 C_DIR。因此保留原写使能，地址/数据选择使用单独的 C_DIR 解码，去掉长授权表达式对 RAM 数据路径的影响。不增加周期或状态。`prove_catalogmux.py` 从原 RTL 提取状态常数及七个排除条件，SMT 验证所有二值状态、控制、地址、数据与原存储内容下 next-memory 恒等。BMP 重试/保留、CancelGlitch、keypad 目录/恢复/自动播放测试均通过。综合 REG/DSP 不变，Total LUT 14519，最终布线进行中。

`playlist-proof.txt` 保存并行比较全输入空间及拆分 memory bank 的归纳关系检查；它不冒充全设计形式等价证明。`catalog_dram` 是已独立验证的目录表写口与播放列表 bank 改写的组合候选。

另以相同 RTL 测试 `rtl seq_max_fanout 32` / `merge_seq_honor_max_fanout on`，综合 REG 仍为 10465，因此尚不能说实现了寄存器复制或降低了寄存器扇出；仅在独立目录中评价物理结果。固定最佳布局的 normal 与 routability 布线、额外 4 轮 post-route 优化也在独立目录中对照，原最佳数据库保留。

02:00 补充结果：目录表写口候选 seed7 为 -3.456 ns / TNS -375.032 ns / Hold +0.023 ns，9366 Slice，整体未获益，最差转到 link 控制长连线。DRAM 候选 seed8 为 -1.679 ns / TNS -123.697 ns / 395 setup 端点 / Hold +0.021 ns，9494 Slice，仍未超过 pipe 最佳，暂停这两个方向的后续队列。固定最佳布局的 normal+额外轮次为 -2.230 ns，routability+额外轮次则精确复现 -0.692 ns，未观察到改进。

另外验证原生 `phys_opt -post_route -mode relocation -effort high`：直接加载最佳 pr.db 后在 abnormal timing path check 阶段 coredump，未得到有效最终报告；已记录 trial-aborted，不能采纳。另行尝试先从最佳 place.db 完整布线，再在同一进程立即调用该命令，核查是否与导入后的工具内部状态有关。此为待验证推测，尚未确定根因。

## 03:40 进展：等周期 RAM 读路径改写

尚未闭合，最佳仍为 `phy_pipe_s7h100` 的 -0.692 ns / 33 个 setup 端点；不能将以下布局估算或试验当作已达标 bit。

- `pipe-full54-equivalence.log`：重新执行四组 FAT 对照，包含全部已连接输出及诊断计数，均 PASS；GEOM4C/D 操作数与预比较值一致断言保留。
- 主工作树 FAT 仍为本次开始时的 E4，SHA256 `a6382733a94f6edceb4e6c636ce9731ec7738e52387f25c504c82173de3188b0`。在此基线上重跑两项原有失败：`baseline-emergency-system.log` 仍在 385515 ns、`tb_emergency_system.v:148` 失败；`baseline-media-source.log` 仍在 500 us、`tb_media_source.v:82` 失败。未修改业务逻辑或测试来绕过它们。
- 原生 post-route phys_opt 在“同进程完整布线成功之后”仍再次 coredump，排除了仅在导入时发生的解释；根因未确定，试验排除。post-place 强制复制在导入数据库、单网 typed 对象以及同进程 place 后三种方式下均报告复制 0；不把这些调用视为有效时序改进。权重 1.25 的 seed7/8 完整时序精确复现原结果，seed3 整个布局时序报告（去时间戳）也与原版相同，已停止重复扫描。
- `min_ripple_len 24` 的 seed7 为 -3.747 ns / TNS -532.369 ns；seed8 为 -0.995 ns / TNS -19.578 ns / Hold -0.011 ns。自然数 FSM 编码的 seed7 布局崩溃，seed8 为 -1.035 ns / TNS -43.596 ns / Hold -0.020 ns；仍均不合格。不能只以 setup 判断达标。

### wavprefetch

不改变状态机、寄存器更新周期或输出周期。在原有地址等待拍内，用精确的 `tab_addr` 下一状态方程提前读 RAM；在 RAM 后增加数据寄存器，上一拍同地址写入通过转发补偿。零号项影子在写入零号项时同步更新，并保留跨复位数据，用于异步复位改变地址后的首次读取，避免把复位前预取的旧地址数据送出。

`wavprefetch-proof.txt` 包含地址下一状态、read-over-write、影子一致性的局部关系证明及其假设。`wavprefetch-async-equivalence/` 在深度 4/16/64 下验证全部输出、原状态寄存器、`nxt_r` 和 `tab_q` 逐拍一致，包含 X 请求/数据、扫描中变化的恢复簇号以及时钟之间的短异步复位脉冲，并断言预测地址等于实际地址下一值，均 PASS。这不冒充全设计形式等价证明。

综合 Total LUT 14621、器件 LUT 16809、REG 10665（+200）、DSP 26、BRAM9K 58 / BRAM32K 1。seed7 布局为 9476 Slice、setup +0.149 ns / 0 端点；**此为布局估算，最终布线进行中**。增加 FF 并没有使此次 Slice 超限，但不能据此预测 routed WNS。

### catalogsplit / catalogbram

目录普通条目使用 256×64 bank，上下文保留页使用独立 16×64 bank。原写入优先级原样保留；两路同步读取后，用同拍寄存的原读选择条件选择 `cat_q`。未知选择器显式输出 X，与原共享 RAM 的未知地址读取一致。端口授权条件、FSM、全部接口和状态周期不变。上下文 bank 分别试验 DRAM 与 BRAM 映射，两版业务 RTL 仅存储属性不同。

`catalogsplit-proof.txt` 验证全部可访问地址的读值和 next-memory 归纳关系，含两类写请求同时出现时的原优先级。`catalogsplit-memory-equivalence/` 使用从改写前后 RTL 提取的实际存储片段，30000 拍随机测试通过，覆盖同地址读写旧值、优先级以及 X 控制/地址/数据。BMP 重试/保留、取消毛刺、目录/恢复/自动播放现有测试亦均 PASS。

DRAM 组合版综合 Total LUT 14527、器件 LUT 16811、REG 10730、DSP 26、BRAM9K 58 / BRAM32K 1；相对 wavprefetch 的 Total LUT 减少不等于已证明物理时序改善，最终资源和时序仍待布线。BRAM 版本另行综合，以剩余 RAM 容量换取 LUT/FF 余量，严格按实际容量检查。

## 09:45 进展：依据最终关键路径预计算 seek 判定

夜间各 RAM 组合及 catalogff 多种子试验尚未超过 pipe seed7 的 -0.692 ns；布局估算达标不能替代最终布线结果。catalogbram seed7 最终 -2.604 ns / TNS -236.972 ns / Hold +0.024 ns，其最差路径转到 `fat_wav_controller.seek_target[16]` 至状态/错误输出：6 LUT、cell 2.590 ns / net 9.734 ns，第一段扇出仅 7 的网线就有 7.029 ns。不能据此继续认定 FAT 是唯一瓶颈，也不能用总 LUT 减少推断全设计收益。

新候选 seekcut 保留原控制器状态机与全部接口周期，仅预寄存 seek_target 非零判定及头完成时的目标范围判定。解析器增加内部完成事件与长度预览线；原解析器时序 always 块逐字节保持相同。特别处理同拍目标更新优先级，使用当拍实际写入的目标和新长度，避免比较上一拍尚未更新的 data_len。seekbase 仅将此改写叠加于 pipe；seekcut 叠加于 catalogbram，以分别评价局部与组合收益。

- `seekcut-equivalence/`：原/新控制器 27 个输出、状态、目标及新增标志关系逐拍比较，EXTERNAL_POSITION=0/1 均 PASS。
- `seek-preview-equivalence/`：65536 组四态控制组合、未知尺寸字节及未知状态检查 PASS；预览事件等于原解析器下一拍 payload_start，预览长度等于实际新长度，相关声道位在完成拍稳定。
- `seekcut-proof.txt`：对全部二值 32 位目标和控制优先级验证非零标志归纳关系，以及预览完成拍范围判定使用实际 next-target；这是局部关系证明，并非全设计形式等价证明。
- seekbase 综合 Total LUT 14657、器件 LUT 16845、REG 10467、DSP 26、BRAM9K 58 / BRAM32K 1；seekcut 对应为 14755 / 16943 / 10668 / 26 / 62 / 1，均在容量内。两版从 seed7 开始独立完整布局布线，尚未获得新最终结果。

仍未达成零 setup/hold 违例，因此尚无可交付的合格 bit。主工作树业务 RTL 未用这些未达标候选替换。

09:54 补充：seekcut seed7 布局估算为 +0.244 ns / 0 setup 端点、Hold +0.059 ns、9558 Slice；最终布线仍在执行，不能写作收敛结果。WAV 原有头部边界单测与实际解析/PCM 控制器测试均 PASS。

另有 seekmux：原目标赋值优先级不变，将相同 next-target 选择结果复用于单个范围比较器，替代多个 RHS 范围比较。两种定位模式下 27 输出与状态逐拍对照均 PASS；综合 Total LUT 14688、器件 LUT 16876，相对 seekcut 减少 67 LUT，REG/DSP/RAM 不变；完整物理试验启动。过程中 ModelSim 检出组合块位于相关声明之前，已移动至声明之后并重新通过编译、等价对比和完整综合，先前中断综合不作物理输入。

依据本地官方 User Guide 中 `route timing` 的说明（normal 达标即停、greedy 继续争取余量，适用 ALL），从 pipe seed7 原 place.db 启动固定布局、routability + timing greedy 对照，仅更改布线目标，SDC 不变。尚无最终收益结论。手册的 `pack_mode` 属 PH2，不适用于当前器件，未据此试改。

## 10:10 进展：上下文读口与握手关系

新增最终结果：seekcut seed7 为 -3.822 ns / TNS -1010.114 ns / Hold +0.024 ns；seekmux seed7 为 -1.730 ns / TNS -410.556 ns / Hold +0.024 ns，均未达标。固定 pipe seed7 布局的 greedy 路由仍精确复现 -0.692 / -8.103 / +0.037，未改善。seekbase seed7 在布局 -1.366 ns 后布线拥塞持续增大、单轮达 200 秒且冲突仍约 1300，已暂停该方向并记录 trial-aborted，不冒充最终结果。pipe 开始扫描 16、17、23、31 等更高种子；两个组合版继续其他种子。

BRAM32 独立厂商模型测试在有效采样时刻对照 30000 拍双口 old-data 行为通过，但直接用于播放列表后的原/新模块对照在 170 ns 出现已定义读值不一致，原因未确定；因此 ram32 候选未综合、未布线、未采纳，不能用独立探针 PASS 替代完整模块等价。

seekmux seed7 的最差路径从普通 `catalog_data_q[39]` 经共享读选择器到 `context_tag_match`，4 LUT，cell 4.864 ns / net 6.586 ns。emergency 真正消费该标志的两个分支均位于 LOOKC；唯一进入 LOOKC 的路径是 LOOKQ 接受 `control_grant && q_current`，其中 q_current 包含上一拍 control_q_valid。control_q_valid 蕴含 BMP 的已寄存上下文选择条件，因此有用的标签比较实际总读上下文 bank。

ctxdirect 候选保留原 ctx_q 和其他全部读口/消费者，另暴露同步上下文数据供标签比较使用；未设置新的时序例外。上下文 bank 选用已验证的 DRAM 存储属性。标签寄存器在 LOOKC 之外的无用值允许与原版不同，但消费者拍的值、原控制器输出与状态必须一致。`ctxdirect-proof.txt` 为这一局部握手蕴含证明，不冒充全设计形式证明。独立使用 emergency 模块时新增参数默认关闭，保留原接口行为；media_core 内显式启用专用标签读口。

`check_ctxdirect.py` 在真实 FAT32/双通道 SD/media_core/WAV/协议/GPIO/PCM 集成测试中并列实例化原 emergency 参考模块，逐拍比较 29 个输出、原 state/hstate，断言 LOOKC 的标签相同、LOOKQ 接受时两条数据口相同。测试仅把原目录保留页的物理调试索引 260/261 对应到拆分 bank 的 4/5，期望值与业务检查未改变。quick、loop、gpio、format、missing、read_error、reset、disconnect、empty 已 PASS，其余场景继续执行，完整综合正在运行。

10:11 补充：上述对照的 paused、reentry、render_reset、switch、paused_switch、restore_body_error、switch_many、pending_begin、cfg_race、mono 也全部 PASS，共 19 场景。完整综合 Total LUT 14757、器件 LUT 17041、REG 10732、DSP 26、BRAM9K 58 / BRAM32K 1，未超容量；已经从 seed7 开始完整物理运行。未因局部等价或综合容量通过而提前采纳。映射阶段的 95 个暂未约束点与既有 catalogsplit 相同，最终仍需核对布局/布线 STA coverage、时钟和路径统计，不能把漏约束当成收益。

## 10:28 进展：容量与重复试验排除

ctxdirect DRAM seed7 最终 -3.299 ns / TNS -983.558 ns / Hold +0.024 ns、9725 Slice，仍不合格。密度达 99.23%，因此增加 ctxbram 属性对照：其逻辑/接口/握手与已经通过 19 场景的 ctxdirect 相同，仅将 context_mem 的存储属性改回 BRAM。综合 Total LUT 14578、器件 LUT 16766、REG 10668、BRAM9K 62 / BRAM32K 1、DSP 26；相对 DRAM 版分别少 179 Total LUT、275 器件 LUT、64 FF，完整物理 seed7 正在运行。仍以实际 Slice 和最终时序判定，不把综合计数当作闭合。

seekcut/seekmux 的 seed8 在长时间迭代后连线总长、冲突继续恶化，已记录 trial-aborted 并停止队列，将算力给 ctxbram 与最佳 pipe 的后续种子；二者的有效最终 seed7 报告保留。pipe 的 high + place relaxation 0.85 从 seed7 开始对照，此前 pipe 的 0.85 试验使用 medium；SDC 原时钟周期不变。

nostruct 只关闭 `gate add_map_lut_struct`，仍使用最佳 pipe RTL。综合完成后，`compare_nostruct.py` 核对全部面积与全部时序报告（仅规范日期和试验目录），两份均完整一致，没有可测映射收益，因此不再重复布线。

局部 soft bound 探针发现 report_bounds 在此环境中 coredump，传 typed cells、显式名字、通配名字均未获得可核验报告，导出探针数据库也未找到新增区域名；是否器件支持或 API 前置状态问题尚未确定。没有据此宣称生效，也没有采用。探针数据库和日志保留，全部独立于有效候选。验收脚本另要求原五个分析时钟和频率完整存在、STA coverage 不低于原 99.96%，防止漏分析路径造成虚假零违例。

## 10:45 进展：较小的簇号预取与组合

pipe high/0.85 seed7 最终 **-1.274 ns / TNS -9.642 ns / 53 setup 端点 / Hold +0.030 ns / 9389 Slice**，没有超过最佳。过程中 dr_timing_opt_phase6 曾为 +0.101 ns / 0 端点，后续消除线路冲突的 dr_opt_phase6 又变为 -1.346 ns，原生最终选择 -1.274 ns；额外 fix_hold 前 setup 已经是负值，不能怪到额外 hold 修复，更不能用中间零违例生成 bit。该队列继续后续种子。pipe seed16 在超过 30 分钟、单轮 176.9 秒且拥塞不收敛后已记录未完成并停止，继续 seed17 等，后续该队列每种子 1800 秒上限。

原生 `phys_opt -post_route -mode reroute -effort high` 也在 Abnormal Timing Path check 阶段 coredump，与此前 relocation 相同；此结果排除。固定最佳 place.db 另单独试 `route post_route_opt ultra`（其余不改），仍待最终结果；不混入无效 phys_opt 调用。

clusterpipe 仅对播放列表的簇号 32 位做原 wavprefetch 的预测读/转发/零号影子补偿，文件大小 32 位保留原同步读地址与时刻。拆成两个 32 位 bank，总深度及写使能不变。相对原全宽预取，去掉大小半部不需要的预取寄存器。`clusterpipe-equivalence/` 深度 4/16/64、X 输入/数据、扫描中变化的恢复目标、时钟间短异步复位脉冲下，全部输出、原状态和完整 tab_q 逐拍一致，下一地址预测断言亦 PASS。`clusterpipe-proof.txt` 对 32 位转发/影子及地址宽度 2/4/6/10 作局部关系证明，并验证两个 32 位平面的读写等价于原 64 位 memory，仍有相应初始存储关系假设，不冒充全设计形式证明。

clusterpipe 综合 Total LUT 14497 / 器件 LUT 16685 / REG 10537，相比最佳 pipe 仅 +24 Total LUT、+72 FF；BRAM9K 58 / BRAM32K 1、DSP 26 不变，正在完整物理 seed7。布局 +0.169 ns / 0 setup 端点、Hold +0.059 ns，尚非最终结论。

clustercat 在 clusterpipe 上仅叠加此前已单独证明 RAM next-memory 恒等的 catalogmux 写口选择简化，不采用目录 bank 拆分、seek 改写或专用上下文读口。组合综合 Total LUT **14464** / 器件 LUT **16652** / REG **10537**，相对最佳 pipe 为 -9 Total LUT / +72 FF，RAM/DSP 不变；取消毛刺场景仍 PASS，完整物理队列已启动。ctxdirect DRAM seed8 的单轮迭代超过 120 秒且拥塞继续上升，已记录未完成并停止队列，优先上述更小的组合。ctxbram、原 pipe 后续种子仍各自独立评价。

目前最佳完整、无工具错误结果仍为 pipe seed7/high/1.0 的 -0.692 ns，仍无合格 bit；所有未达标 RTL 均未替换主工程。

## 13:00 后续扫描

packetfree seed8 布局估算曾到 setup +0.047 ns、hold +0.059 ns；但完整 route 在 30 分钟内始终未能排完最后约 20–50 条冲突网，按试验超时门写入 `trial-aborted.json`，没有 final STA，不能拿布局正 slack 代替。seed3 已自动开始，继续核查其他 seeds。

原 pipe 高力度 seed61 完整结果为 setup -0.560 ns / TNS -52.865 ns / 267 违例端点 / Hold +0.024 ns / 9374 Slice；seed67 为 -0.795 ns / -75.273 ns / Hold +0.020 ns。均资源合格但 setup 非零。seed73 详细布线继续进行。最佳有效最终结果仍为 seed61，仍不满足 bit 资格。

本轮所有完整报告均未同时达到 setup/hold 零违例。没有触发 bitgen 门，没有覆盖主工程 E4 RTL。 

## 后续局部优化与功能核对

固定最佳布局的 route post_route_opt ultra 最终仍精确复现 -0.692 ns / TNS -8.103 ns / Hold +0.037 ns，没有收益。`probe_effective_params.txt` 核实参数在数据库导入后仍保留 ultra、greedy 等设置，并非导入顺序把参数覆盖；配置被接受不能替代实际收益。当前所有结果均检查最终合法布线、额外 hold 修复后的统计。

### BMP 状态判定预译码

predstate2 保留原 4 位 state 和全部状态转移，只在每个原 state 写入处同步更新两个判定位（目录状态、上下文可用）。原 state==C_DIR 的消费者与 ctx_ready 使用这些同拍值。`prove_predstate.py predstate2` 核对全部 38 处写入的条件和优先级未变，撤销判定位包装与替换后，整个 RTL token 流恢复原版；每个 4 位状态、目标、写使能下关系均可归纳。`predstate2-equivalence/` 逐拍比较原控制器 39 个输出、原状态及判定位，PASS；原取消毛刺/6 帧与 5/10 秒自动轮播测试不改期望值亦 PASS。

曾试验第三个 READY 判定位，局部关系及正常输入对照通过，但原测试直接改写内部 state 的准备动作没有同步该冗余位，自动轮播检查因此失败；该可选缓存已删去，原测试未改，三位版本未进入物理队列。不能将三位版本的失败记作通过。

predstate2 综合 Total LUT 14483 / 器件 LUT 16671 / REG 10539，RAM/DSP 不变。有效最终 seed7 为 -2.132 ns / TNS -212.969 ns / Hold +0.037 ns，seed8 为 -3.541 / -543.590 / +0.030，仍不合格。seed7 最差路径实际从 seam tx_state 经 bus_write 到 link occupied，虽然单元名字带 keypad/pending，网表中的真实 net 并非该按键 pending 本身；分析时不能只看优化后的实例名。

### 链路序号高位缓存

clustercat seed7 的 8 级最差路径为 next_seq 的 DSP 输出→通道选择/低字节比较→24 位条件减法→send_seq。seqcache 随原计数器更新保存 upper_prev=next_seq[31:8]-1；仅在低字节进位时复制旧高位，复位/会话清除置全一。原计数器、包头捕获时刻和协议状态均不变。

`seqcache-proof.txt` 对所有二值 32 位计数、8 位选中序号、清除/递增控制证明归纳关系与包头重建等式，覆盖完整回绕；不声称任意 X 或全设计形式等价。`seqcache-equivalence/` 在原窗口/停顿/重传/CRC/会话恢复/32 位序号回绕场景中并列运行原模块，两端点各 22 个输出、send_seq/send_state 在核/MAC 时钟下逐拍一致。原测试的计数器预载仅同步给参考实例，未给新增缓存预载、未屏蔽输出断言。原链路测试 PASS，另有 1,800,021 次计数检查加缓存关系断言全部 PASS。

综合 Total LUT 14611 / 器件 LUT 16789 / REG 10609 / DSP 26 / BRAM9K 58 / BRAM32K 1。seed7 post-pack 优化 native access violation/coredump（返回 3221225477），无有效最终结果，已排除；其余种子继续。

### 播放列表 BRAM32 原生模型与转发

ram32 的直接替换未通过同地址读写对照，未采用。ram32fwd 将物理写延后一个时钟，对逻辑当前读遇到该写的地址时转发延后写的数据；原地址/状态机/读出时刻不变。`ram32fwd-proof.txt` 在地址宽度 2/4/6/11 下证明该转发对任意同地址 native collision 输出均给出原逻辑读值，有相应初始存储/队列关系假设。

`ram32fwd-native-equivalence/` 实际编译厂商 EG_PHY_BRAM32K 和 glbl，不启用 DB_BEHAVIORAL_RAM；深度 4/16/64 下全部公开输出和原状态无掩码对照通过，包含 X 控制/数据、变化恢复目标、短异步复位。每个原 RAM 读出的已定义 bit 也逐 bit 核对；原未初始化数组的 X/Z 位仍为未约束值，不冒充完整初始 RAM 形式证明。

综合 Total LUT 14572 / 器件 LUT 16760 / REG 10601，BRAM9K **54**、BRAM32K **5**、DSP 26，容量符合器件；原五个时钟不变。该方向使用空余的大 RAM 资源，而不是简单把 RAM 摊成 FF，完整物理队列正在运行。

### 包暂存数据取消无用使能

packetfree 针对 bus_write 扇出 60 的真实路径，保留 packet_write 的原时刻，packet_data/address 每拍采样。若下一拍 packet_write=1，数据/地址必来自同一原接受拍；若为 0，RAM 地址选 crc_address，写数据不使用。因此原 RAM 的每次读地址、写地址/数据和写使能均不变，仅无效拍暂存寄存器的私有值允许变化。

`packetfree-proof.txt` 验证这一二值局部关系，并核对源码除该处捕获门控外的完整 token 流相同，实际消费者只有受 packet_write 控制的 RAM 口。`packetfree-equivalence/` 两端点各 22 输出、发送状态/序号逐拍对照 PASS，还逐拍检查 packet_write、共享 RAM 地址、CRC 读口、发送读口以及有效拍数据/地址相同。原协议窗口、停顿、重试、CRC、会话恢复和回绕检查均保留。综合正在运行，后续仍需核对实际 CE 扇出及最终布线收益。

ctxbram seed7 长时间接近零冲突后又重新出现约千处冲突，超过 40 分钟仍无最终结果，已记录未完成并停止；未当作零违例或负裕量最终值。新增 `list_running_trials.py` 按进程创建时间与运行标记对应当前真正执行的种子，避免一直读取已超时/已结束种子的旧尾日志。当前最佳最终值仍为 -0.692 ns，主工程业务源码仍未用任何未达标候选替换。

## 2026-10-27 续：实际路径驱动的 RTL 对照

复核后的最佳 WNS 为 pipe seed61：最终 setup -0.560 ns / TNS -52.865 ns / 267 端点，hold +0.024 ns / 0 端点，9374 Slice；seed7 的 WNS -0.692 ns，但只有 33 个 setup 端点。两者都未闭合。seed61 最差路径经 seam 发送握手、link 的包写入逻辑到 peer_age，cell 3.276 ns / net 7.004 ns；其他前十条路径涉及描述符 BRAM、序号、字幕、浏览器和 BMP。所有时钟及约束保持不变。

- pipe seed97 完整布线 setup -2.014 ns / TNS -195.976 ns / 472 端点，hold +0.024 ns / 0 端点，9523 Slice。seed101 在用户要求停止单纯扫种子后中止，未产生最终报告。
- 从 seed61 违例报告提取的 75 个数据网络有 73 个成功赋权，seed61 权重 2 的完整对照为 setup -1.521 ns / TNS -39.438 ns / 93 端点，hold +0.030 ns / 0 端点，9355 Slice；比基准端点数少，但最差 slack 更差。seed7 的全部违例网络赋权对照发生 coredump，无有效结果。
- `filllast` 对 seed61 的包末字比较提前维护标志，不改变接口周期。全二值局部归纳证明及原/新双链路逐拍输出和标志关系对照通过；综合器件 LUT 16808 / REG 10466，相比 pipe 增 147 LUT / 1 REG。seed61 布线在冲突长期约 236–263、线长持续上升、单轮 35–45 秒时中止；无最终 STA，不采纳。
- `seqpipe` 仅把已证明的链路序号高位缓存叠加于 pipe；双链路逐拍对照通过。完整布线 seed61 为 setup -1.162 ns / TNS -184.083 ns / 574 端点，hold +0.030 ns / 0 端点，9500 Slice，不采纳。其最差起点实例名虽含 crc_byte，但实际发出的网为 session_reset，经按键取消门控和导航解码到文件浏览器，不能按名字误认 CRC 路径。
- `keylate` 基于实际 session_reset 路径，将按键输出的取消门控放到并行解码末端，不改变组合输出时刻或状态。100000 拍随机四态输入下原/新 14 输出及内部状态逐拍一致，原 keypad_router 和 settings_menu 测试通过；综合器件 LUT 16674 / REG 10465，RAM/DSP 不变。完整 seed61 为 setup -1.385 ns / TNS -77.215 ns / 295 端点，hold +0.024 ns / 0 端点，9386 Slice，不采纳。新最差为 seam image_ready 经发送仲裁到 len_r，数据路径 11.105 ns，net 8.851 ns；这只能说明整体放置及瓶颈已变化，不能证明原取消路径独立改善。

本轮候选及日志在 `build/timing-closure-20261026/`，主工程业务 RTL 未替换；当前仍无零 setup/hold 违例 bit。原有 emergency_system 和 media_source 回归失败尚未解决，不能宣称完整回归通过。

## 后续：发送长度并行选择与回归失败定位

`lenparallel2` 依据 `keylate` 最差的 image_ready→发送仲裁→len_r 路径，将原包长度优先选择独立为组合选择器，保持原仲裁、状态机与寄存器装载周期。初版按位 OR 在选中数据含 Z 时将其变为 X，四态检查失败并已排除；修正版用数据选择保留该四态行为。二值全部仲裁条件和任意 11 位数据的局部 SMT 检查、300000 组四态随机检查通过；检查脚本还核对原 RTL 中各分支顺序和实际长度赋值。overlay、metadata 和 volume 三个现有场景中原/新 48 个输出及包发送状态逐拍一致。综合器件 LUT 16710 / REG 10465 / BRAM9K 58 / BRAM32K 1 / DSP 26；seed61 因冲突长期停滞、上升且线长增加被中止，无最终时序；seed7 达到 1200 秒试验时限，第二轮刚消除冲突但尚未完成最终布线及 STA，因此也无有效最终结果。

另定位之前两项基线测试失败：`tb_media_source` 的 3 位 ui_page 输入接到 4 位端口，ModelSim 使最高位为 Z，导致 UI 快照的稳定性比较为未知值。把测试常量补为 4 位后，原检查及期望值不变，原工程测试通过。`tb_emergency_system` 同样存在 ui_page 位宽问题，且 transition_mode 悬空；显式输入 4'd0 和 2'd0 后原完整应急双板场景通过，仍保留图像/UI/应急检查并给失败增加诊断输出。同类位宽错误在其他六处测试实例中也已修正，音频双板测试的 transition_mode 悬空同样导致业务完成检查失败，补充输入后原场景通过。元数据、覆盖发送、真实 media_core 覆盖端到端、基础双板和音频双板针对性测试均通过。这些是测试激励修正，未修改业务 RTL。完整回归重新运行后通过大量单元/集成及多个全分辨率场景，但在 `tb_media_sd_boot -ScaleFull` 期间主动停止；后续测试未执行，因此完整回归仍未完成，不得记作通过。日志 `full-regression-recheck.log` 保留已执行项目。

`eqgroup` 将播放列表 32 位簇号等值比较按字节分组再归约，恢复目标仍逐拍直接参与比较。深度 4/16/64 的输出及内部状态对照覆盖未知输入、异步短复位和变化中的恢复目标；另有 200000 组混合四态比较通过。综合器件 LUT 16698 / REG 10465 / BRAM9K 58 / BRAM32K 1 / DSP 26。seed7 完整布线 setup -1.987 ns / TNS -201.777 ns / 475 端点，hold +0.021 ns / 0 端点，9408 Slice，整体不合格。对两个最终数据库分别导出游标寄存器路径：原版最差 -0.692 ns，分组候选 +0.169 ns，候选的 BRAM→游标数据路径从 10.340 ns 降至 9.551 ns。这个局部比较有收益，但同时出现新的 seam image_active→metadata/发送控制路径，不能把局部改善视为全设计闭合，也尚未采纳。路径报告为 `eqgroup-base-cursor.timing` 和 `eqgroup-candidate-cursor.timing`。

`ownerdup` 在 eqgroup 上同步复制 image_active，仅将元数据所有权门控的一路扇出改接副本。六处写入均成对，恢复变换后的完整 RTL token 与原版相同；三个 seam 场景的 48 输出逐拍对照通过，综合数据库确认副本存在。seed7 最终 setup -2.024 ns / TNS -127.332 ns / 309 端点，hold +0.024 ns / 0 端点，9473 Slice；对同一 source_ok 终点单独导出，最差 slack 从 eqgroup 的 -1.987 ns 改善为 -0.433 ns，但全局最差转到 BMP 目录 RAM 写使能（-2.024 ns）。不能将端点收益当成全局达标。

`ownerpred` 在上述组合上叠加此前证明的 BMP 目录/上下文状态译码与目录 RAM 写口简化；39 输出逐拍对照及 38 处状态写入检查通过。seed7 在布局阶段 coredump，seed61 布线冲突长期反复且线长增长后中止；二者都没有有效最终时序。

`dirfast` 因此只增加目录状态预译码、保留原目录 RAM 写口。38 处状态写入的结构证明、39 输出逐拍对照、取消毛刺及目录/播放测试通过。seed7 最终 setup -1.729 ns / TNS -55.853 ns / 241 端点，hold +0.024 ns / 0 端点，9448 Slice；最差已转为 emergency save_position 到 BMP 上下文 RAM 数据口，仍不合格。日志含 DSP 级联引脚 PHY-5014 警告，原 pipe seed7 也有该警告，不能由此推断本次独有故障。

`savefast` 对上述实际路径中的 SAVE1 状态做同拍预译码。41 处状态写入的结构/二值归纳检查、应急控制器 29 输出逐拍对照和 19 个真实 FAT32/SD/media_core 集成场景通过，综合数据库确认标志寄存器保留。seed7 布局 coredump；seed61 最终 setup -2.164 ns / TNS -656.751 ns / 1244 端点，hold +0.024 ns / 0 端点，9326 Slice，最差转到 BMP scaler。不同种子的端点不能直接比较，所以不能据此宣称目标路径已改善。上述各业务候选仍未采纳。

`xterminal` 针对该 scaler 路径，将两处常量终点判断 `row_x+1==DST_W` 改为 `row_x==DST_W-1`。任意强制未知 row_x 下两种四态结果不完全等价；局部证明依赖正常复位及 ROW_START 初始化后的可达状态，不能宣称任意状态四态等价。七组原/新 scaler 输出及状态逐拍对照与独立像素参考通过，另通过一组 1280×720 像素/边框/背压测试。seed61 在 1800 秒时限内未完成最终布线，无最终 STA，不采纳。

`savedup` 回到 dirfast 的上下文 RAM 数据路径，复制应急状态并只把 save_position 数据口译码改接副本。41 处状态写入成对更新、恢复变换后原 RTL token 一致，29 输出逐拍对照及 19 个真实应急集成场景通过，综合数据库确认五位副本存在。seed7 布局 coredump；seed61 1800 秒后仍有约 53 条冲突并中止，均无有效最终 STA，不采纳。
