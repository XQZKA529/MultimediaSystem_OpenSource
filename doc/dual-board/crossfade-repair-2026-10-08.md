# 交叉淡化版本排障记录（2026-10-08）

用户已确认第二轮 `crossfade_busyfix` bit 上板正常工作，先前 ERROR 5 已消失；尚未确认 30 分钟轮播与 WAV 长测。下面保留故障分析与历史构建记录。GUI 曾因使用空的默认策略而在 Hold 修复布线时发生 PHY-8023 / RUN-8102；现正验证持久保存优化策略后的原生 GUI 流程。

## 第二轮：第一轮产物上板仍报 ERROR 5

用户报告第一轮产物启动后先黑屏约 5～15 秒，再显示 ERROR 5。此前完整像素测试使用固定延迟读返回模型，未覆盖厂商控制器的 busy 语义，因而遗漏了一个关键缺陷。

双路读调度器原先在已准入的突发内部逐字检查 `!Sdr_busy`。实际厂商控制器服务读请求期间也会拉高 busy，这不代表已准入的流式突发需要逐字停顿。现在仅在突发准入处检查 busy，突发内部连续发出目标数量的字，仍等待全部返回排空后交接。真实控制器短测试中，256 字的发送到最终返回耗时降至 267 个内存周期，准确返回 256 字。

负向对照脚本 `render/sim/reproduce-sdram-busy.ps1` 在临时副本中恢复旧门控，接入实际厂商控制器、实际 SDRAM App 仲裁器和生产 FIFO，第一行第 680 个新图像素复现欠载（`new pixel 680 valid=0`）。日志保存在 `render/build/evidence/sdram-busy-old-underflow.txt`。欠载将触发过渡失败；media 丢弃本次事务后由提交期限及重试流程报告 ERROR 5。用户报告的时长与此流程相符，但具体实板归因仍须由第二轮产物复测确认。

`tb_frame_read_dual` 默认改用真实加密 SDRAM 控制器及真实仲裁器的返回时序，包括页/行切换和控制器刷新；生产异步 FIFO、解包器、混合器及完整 720p 扫描保持不变。TD 提供的 `EG_PHY_SDRAM_2M_32` 是空仿真原语，DQ 不驱动，因此仅返回数据内容由请求地址生成，不能把该测试称作实物 SDRAM 数据存储验收。`tb_sdram_read_contract` 同时约束突发周期数，避免只检查返回数量而再次漏掉吞吐退化。

本轮仅修改 render 生产 RTL。第一轮 media 产物继续使用；新的 render 构建标签为 `crossfade_busyfix`，布局种子 1。完整产物 `render/Runs/phy_crossfade_busyfix/MultimediaSystem_render.bit` 已通过输入指纹和工具门槛：Setup +106 ps、Hold +3 ps、Setup/Hold 零违例，Slice 66.20%，BRAM9K 55。bit SHA256 为 `9926f6105ad72ffa93fa01456aaba20966260d6d564205308dcd5060edd9d29c`。

真实控制器时序下的完整 720p 测试通过全部四帧：两帧双图、单图模式、中断后恢复，逐像素验证通过；`tb_sdram_read_contract`、切换事务、图片提交和 128 字双板图片联合测试均通过。本轮证据和最新配对清单位于 `evidence/crossfade-busyfix-2026-10-08/`。本节优先于下方第一轮产物记录；用户随后确认本轮 bit 上板正常工作。

## 已修复的确定性问题

- 双路读控制器原本每路只读半帧。交叉淡化要求旧图、新图每路各读完整的 691200 字；现已修正。
- 突发启动未按 FIFO 空间准入。现在为整个 256 字突发保留空间，按最低占用调度，读返回全部排空后再切换所属通道。原帧即使因 FIFO 满而停住，也能在排空在途突发后响应下一帧。
- 原调度器的组合地址累加造成 render GUI 构建 setup WNS −1782 ps。改为每路寄存下一地址和剩余字数，移除突发仲裁后的长加法路径。
- 混合 RGB 的一拍延迟没有匹配 HS/VS/DE，欠载判定也使用了不同时刻的有效信号。现在统一延迟时序，并在输出对应拍检查两路像素有效。
- 过渡请求和结果跨时钟域没有完整握手。现在同步请求、保持 ACK/完成/失败直到请求撤销；旧缓存释放等待真实的单路读者接管，不按固定等待帧数猜测。
- 显示选择存在两个来源；首图在淡入期间仍被 display_valid 屏蔽。现在视频域控制器统一维护显示索引，首图从黑色开始混合。
- 两板链路 CRC 路径包含包 RAM、字节选择和 CRC 计算。增加寄存字节及地址稳定周期，RAM 保持保护直到预计算结束；重传、CRC、会话和实际 TEMAC 联通测试通过。
- 音频 seek 流水线使用上一拍位置。联合测试复现冻结位置 3355 时实际跳到 243254，而正确目标为 243355。现在请求与对应位置计算结果一起延迟，消除 101 帧误差，并保留与 SD 流完成同拍的已接受请求。
- media 的提交等待虽增加了 3 秒计时器，仍同时检查 1 秒加载 watchdog，导致 3 秒期限没有生效。现在 C_COMMIT 使用独立提交期限，并保留整次事务总时限。新测试通过真实探测、许可和文件完成进入提交，检查超过加载期限的延迟成功以及提交超时 ERROR 5。
- render 音频剩余长度判断进入控制长路径，改为随实际消费更新的剩余标志，保留精确尾帧。

## 验证范围

`crossfade-regression-2026-10-08.log` 记录两板全部专项回归及依赖审计通过。完整 720p 测试使用生产异步 FIFO、RGB888 解包器和混合器，125 MHz 内存域、75 MHz 像素域，1650×750 时序；检查每路完整帧地址、逐像素颜色、同步延迟、FIFO 溢出、刷新暂停、单路模式以及未完成帧被下一帧接管。SDRAM 返回采用固定延迟及周期忙的行为模型。

原联合测试遗漏了过渡握手接口，现接入真实过渡控制器和 α 控制器，SDRAM 接管仍由显式模型模拟。128 字图像联合测试验证连续两次提交；音频联合测试验证实际 PCM 编码的绝对位置、暂停、快进、曲尾钳位、冻结反馈积压、单声道以及图像/UI/会话连续性。联合测试为缩短运行时间加快 VS，完整分辨率及真实扫描周期由上述 720p 测试覆盖。

厂商加密 SDRAM 控制器的真实访存吞吐、板级 PHY 及 HDMI 电气行为需要实板验证。现有两板 SDC 的 `set_false_path -hold -from [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]` 按起点排除了整个 RX 输入 Hold 路径，范围并非注释所称的仅 port→pad；TX 也未设置外部输出延迟。本次未新增或扩大例外。工具门槛通过只代表当前约束覆盖的路径通过，不能据此宣称 PHY 外部接口时序已经签核；后续须结合 PHY 配置、板级延迟及实测收口。

## 第一轮原生构建（历史记录）

签核仍要求 setup WNS ≥100 ps、setup/hold 零违例、Slice ≤80%、BRAM9K ≤56，未降低门槛。仅通过门槛且输入指纹匹配的脚本构建才生成 bit。失败轮次不用于烧录。

render 已完成原生综合、布局、布线及 bitgen：`render/Runs/phy_crossfade_fix2/`，布局种子 3；Setup WNS +123 ps、Hold WNS +3 ps，两者均零违例，Slice 66.74%，BRAM9K 55，DSP 8。`qualification.json` 已核对当前输入及 bit SHA256。完整产物为 `render/Runs/phy_crossfade_fix2/MultimediaSystem_render.bit`。

media 已完成原生综合、布局、布线及 bitgen：`media/Runs/phy_crossfade_fix4/`，布局种子 3；Setup WNS +108 ps、Hold WNS +3 ps，两者均零违例，Slice 77.61%，BRAM9K 50，DSP 4。完整产物为 `media/Runs/phy_crossfade_fix4/MultimediaSystem_media.bit`，输入指纹和 bit 指纹检查通过。种子 2 的 Hold 修复局部布线冲突失败日志保留在 `evidence/crossfade-2026-10-08/media-seed2-failed/`，不用于烧录。

| 板 | Setup WNS | Hold WNS | Setup/Hold 违例 | Slice | BRAM9K |
|---|---:|---:|---:|---:|---:|
| media | +108 ps | +3 ps | 0 / 0 | 77.61% | 50 |
| render | +123 ps | +3 ps | 0 / 0 | 66.74% | 55 |

报告、输入指纹及 qualification 保存在 `evidence/crossfade-2026-10-08/`；配对路径及 SHA256 见同目录 `release-pair.json`，属于本轮工具签核证据，硬件验收状态为待执行。render 新增 FIFO 实际占 2 个 BRAM9K，总数为 55。

完整专项回归后，最终 media 改动又通过 SD 启动、`tb_image_timeout`、WAV 控制器及实际文件流测试；联合图片测试通过，音频三个场景及单声道场景均通过。对应日志为 `media/build/evidence/tb_image_timeout.txt`、`tb_media_sd_boot.txt`、`tb_fat_wav*.txt`，以及仓库 `evidence/system-128.txt`、`audio-system-{0,1,2}-mono0.txt`、`audio-system-0-mono1.txt`。

## 实板验收待执行

使用最终签核的一对 bit，并记录完整路径和 SHA256。验证冷启动首图、连续手动切图、快速多次按键合并、轮播、动画期间播放/暂停/快进 WAV、拔线恢复及至少 30 分钟轮播。记录 ERROR 5 是否消失、图像是否撕裂/错位、动画是否中断、音频是否掉音；发生错误时结合 TX/RX 重传、拒绝、丢弃计数判断卡在加载还是提交。
