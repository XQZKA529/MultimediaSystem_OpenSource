# Render 板 TM1650 矩阵键盘

## 分层与接口

参考 MCU 工程 `C:/ti/mspm0_sdk_2_08_00_03/myG3519code/MartixKeyBoard` 的 `Project/tm1650.c`、`Project/iic.c` 和按键表移植。驱动位于 render；media 统一持有菜单、图片目录与播放状态。

| 层 | 文件 | 职责与接口 |
|---|---|---|
| 器件驱动 | render/rtl/driver/tm1650_keypad.v | 独立开漏 IIC 状态机，初始化、轮询、连续两次采样消抖、合法键解码、超时与恢复；输出 down/key_id/online/cancel |
| 输入事件 | render/rtl/driver/keypad_event_encoder.v | 无菜单知识；方向键连发、8 项寄存器 FIFO、故障取消、等待松键；输出 valid/ready/6bit data |
| 传输适配 | render/rtl/seam/seam_render.v、media/rtl/seam/seam_media.v | 复用可靠控制通道；发送时锁存元数据；接收校验后输出单拍事件；不解释操作语义 |
| 业务适配 | media/rtl/clock/keypad_action_router.v | 根据只读 UI 上下文映射语义动作；处理矩阵 5 单击/双击；取消跨页面手势 |
| 原业务模块 | file_browser / fat_bmp_controller / audio_transport | 接收动作脉冲；菜单、目录、图片加载和暂停状态仍由原模块唯一持有 |

键盘模块均使用原有 100MHz 总线时钟与时钟使能，不增加时钟域、BRAM 或 DSP。为减少 media 的组合逻辑，固定菜单文字单独放入 1 块 BRAM9K，文件浏览器采用两拍读写流水；该 ROM 不属于键盘驱动，也不承载业务状态。芯片驱动不知道网络和 UI；输入事件编码器不知道 TM1650 寄存器；业务模块不依赖 IIC 原始键码。

## 接线与器件时序

render J2 pin31 / GPIOB_26 / FPGA J12：SCL；pin33 / GPIOB_28 / K14：SDA；pin29：3.3V；pin30：GND。输出仅拉低或高阻，外部上拉连接 3.3V；不能直接接 5V 上拉。与 HDMI DDC 使用不同引脚和驱动实例。

上电等待 100ms，发送 `0x48,0x19`，等待 5ms 后开始约每 10ms 读 `0x49`，单字节结束发送 master NACK。每阶段间隔 4us，ACK 使用 SCL 释放前的同步采样值，避免例程指出的从机在上升沿后提前释放 SDA 问题。SCL 拉伸最多等待 2ms，失败后清输入；恢复最多 9 个时钟与 STOP，500ms 后重试。

行优先编号：`1 2 3 A / 4 5 6 B / 7 8 9 C / * 0 # D`。有效编码为 `0x44..47 / 4c..4f / 54..57 / 5c..5f`；松开码清 bit6。组合码和非法行不生成操作。启动和故障恢复必须先观察松键。

## 行为与边界

- 关闭菜单：4 上一张、6 下一张；音频播放/暂停时仍切背景图，2/8 无动作；A 切轮播，保持现有轮播间隔。
- `*` 仅在菜单关闭时打开设置；`#` 在子菜单返回设置，在一级设置关闭。菜单 2 上、8 下、5 确认。
- 文件列表首尾循环，跨页重新枚举。扫描、绘制和加载时忽略导航/确认；返回可立即执行，已提交的目录/加载事务继续收尾，迟到 ACK 不改变返回后的页面。
- BRIGHTNESS 和 CONTRAST 的 4/6 分别减/增 10%；范围 10–100% 和 0–200%。返回保留值。上下、5 无调节作用。
- 有音轨且关闭菜单：5 单击暂停/继续、双击下一首；300ms 松开后窗口，双击不会先暂停；长按松开按一次单击处理。9（行优先编号 10）按下退出播放，暂停时也有效，松开和连发不触发。退出清空待播缓冲、取消待判定手势及当前图片配音循环/后台音乐恢复；新图片或重新选曲可再次播放。无音轨、菜单内、应急期间 9 无动作。矩阵键盘无快进/快退。
- 方向键按下立即操作，500ms 后每 150ms 连发。关闭菜单忽略 REPEAT；页面变化取消旧连发，重新按键后恢复。
- 图片加载/淡化忙时只保留一次切换方向，最后方向覆盖前一方向。显式选文件清空待切换；成功显示后用已有目录 RAM 顺序反查簇号/大小，以实际图片为上一张/下一张基准。超出目录容量时上一张从目录末尾、下一张从首项开始。
- 板载 KEY2/3/4 保留。同一菜单帧确认优先于方向；相反亮度调节方向优先采用矩阵输入。B/C/D/0 等未分配业务功能。
- 网络会话复位、IIC 故障和 FIFO 溢出清旧输入，优先发送 CANCEL，等待松键；离线不会不断发送 CANCEL。

## 验证入口

`tools/dual-board/run-regression.ps1` 包含新增 `tb_tm1650_keypad`、`tb_keypad_events`、`tb_keypad_router`、`tb_keypad_images`、`tb_settings_rom`。设置菜单回归补充矩阵动作、上下循环、亮度/对比度、加载中返回与迟到 ACK；`media/sim/run.ps1 -Test tb_settings_menu -SharedKeys` 验证生产工程共用板载按键消抖信号，覆盖关窗 KEY2 切图、菜单内不漏出切图、KEY4 长按不误确认。双板系统仿真补充控制通道上 16 个键盘事件的有序交付，同时继续覆盖图片/UI/音频协议。

首轮 render 物理构建发现原诊断保持计数器使能链时序失败（SWNS -0.977ns）。对 STATUS 刷新条件增加一拍寄存，并按保持周期缩小计数器位宽；原诊断/断线仿真通过。最终时序和资源结果以重新构建报告为准。

实板验收需连接真实键盘，确认 SCL/SDA 波形与上拉、16 键识别、菜单和音频手势、按住键拔插/断网恢复。软件仿真不代表已完成实板验收。

## 资源对照

比较三种独立构建：HEAD 基线、相同业务功能但驱动和事件队列全部放 media、最终驱动放 render。工具为 TD 6.2.168116，area_prior/high/routability；所有 media 对照均 seed3，render seed4。节省量使用两种同功能实现的 media 实测差，新增开销使用最终实现减基线；未接键盘的基线不计为“已节省”。

固定文本源为 `media/rtl/ui/settings_menu_text.json`，生成命令 `python tools/dual-board/generate-settings-menu-text.py`。生成的 ROM 使用显式 EG_PHY_BRAM 与 INIT_00–INIT_1F，避免 TD 对 inferred initialized RAM 的限制。`tb_settings_rom` 使用实际厂商仿真模型逐字符核对 3456 个菜单/后端组合，覆盖初始化位序、物理地址与同步读延迟。

资源对照准备：`python tools/dual-board/prepare-keypad-comparison.py build/new-comparison-directory`；新目录中的 baseline 和 all-on-media 均通过各自 `media/build/run.ps1 -Stage all -RunTag comparison -PlaceSeed 3` 构建，生产板用 media seed3 / render seed4。`report-keypad-comparison.py` 核对全部输入指纹、同功能业务源码、驱动源码及布局策略后输出实测差。物理 LUT/寄存器包含布局优化和 hold 修复，不能当作驱动本身的独立面积；综合差更接近移出驱动的逻辑开销。

## GUI 布线报错与资源策略

GUI 报错 `PHY-8023 / RUN-8102` 涉及文件大小信号与 `rst_dup_239_holdbuf` 的布线位置冲突，发生在综合完成后的 hold 修复阶段。报错运行的原生 `.prj` 仍为 seed1；已将原生工程与 project 脚本持久种子改为 media seed3 / render seed4。关闭旧窗口并重新打开 `.al`，Reset Syn/Phy 后 Run，避免继续使用旧缓存参数。

按用户要求，Slice 80% 改为提示线，在 bitgen 前和签核 JSON 中记录超线状态，不因轻微超出阻止生成。完整布线、Setup WNS≥0.100ns、Setup/Hold 零违例、BRAM9K≤56、输入指纹一致仍为验收条件。没有关闭 hold 修复或放宽时序约束。

## 最终签核与同功能实测

| 实现 | media Slice | media 物理 LUT / 寄存器 | media 综合 LUT / 寄存器 | BRAM9K / DSP | Setup / Hold WNS |
|---|---:|---:|---:|---:|---:|
| 未接键盘 HEAD 基线 | 7769（79.28%） | 13972 / 9627 | 13301 / 9527 | 50 / 4 | +0.060 / +0.003ns |
| 同功能，驱动全放 media | 8020（81.84%） | 14257 / 9784 | 13579 / 9663 | 51 / 4 | -0.239 / +0.003ns |
| 正式方案，驱动放 render | 7853（80.13%） | 14043 / 9673 | 13371 / 9563 | 51 / 4 | +0.115 / +0.003ns |

同功能摆放对照，media 实测少 167 Slice（1.70 个百分点）、214 物理 LUT、111 物理寄存器；综合少 208 LUT、100 寄存器。BRAM9K 和 DSP 差均为零。80% Slice 为提示线；时序未通过的对照实现不生成 bit，其最终面积仍保留用于比较。

正式 render：Slice 6925（70.66%），BRAM9K 53、DSP 12，Setup +0.127ns、Hold +0.003ns。两板 setup/hold 无违例，输入指纹及 bit SHA256 已核对。[完整对照](evidence/keypad-resource-comparison.json)、[配对签核](evidence/keypad-qualification.json)。

正式产物：`media/Runs/phy_keypad_release/MultimediaSystem_media.bit` 与 `render/Runs/phy_keypad_release/MultimediaSystem_render.bit`；集中副本位于 `build/keypad-release/`，同时携带签核、输入指纹和报告。需同时烧录两板。复现分别用 `media/build/run.ps1 -Stage all -RunTag keypad_release -PlaceSeed 3` 和 `render/build/run.ps1 -Stage all -RunTag keypad_release -PlaceSeed 4`。

基线和全放 media 的 seed3 构建仅用于面积对照：基线 Setup +0.060ns、全放 media Setup -0.239ns，均未通过 +0.100ns 的时序门槛，不属于交付 bit。正式 media/render 均已通过当前门槛。

原生 GUI 物理流程复核已通过：在独立副本中使用相同的当前综合 DB，载入 GUI 的 `.prj` 参数与厂商 DefaultFlow，仅将原报错运行的 seed1 改为 seed3；完整布局、布线、hold 修复与 bitgen 均完成，Slice 80.13%、Setup +0.115ns、Hold +0.003ns。全部设计输入和综合 DB 哈希一致，无本轮 PHY-8023 / RUN-8102。[复核证据](evidence/keypad-native-gui-qualification.json)。该项验证原生物理流程，未操作用户 GUI 窗口；正式配对使用前述两板完整命令行构建。

## Text OSD 本地事件归属（v1.4）

render 在事件编码器与 seam 之间增加 `text_osd_event_router`，驱动和编码器继续不解释菜单。media 的完整 UI 快照 flags bit12 指示本地文字页；在确认 VS 提交后，本板消费 2/8/4/6 和5，#与CANCEL仍经原控制通道交付media。方向连发参数不变，5不连发。归属切换清队列并要求松键，故障取消同拍优先，#进入退出等待以拦截迟到页面快照。

文字页只接受矩阵编辑，板载KEY3与KEY2双击保留原退出语义。文字与开关由render保存，断线和media复位保留。详见 [Text OSD实现](text-osd-2026-10-08.md)。
