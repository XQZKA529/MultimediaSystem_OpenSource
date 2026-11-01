# 双板 HDMI 多媒体播放系统

基于两块 HX4S20 / 安路 EG4S20BG256 的纯 RTL 多媒体终端。**media** 读取 SD 卡、解析文件和组织播放，**render** 接收图片与 PCM、管理 SDRAM 并输出 HDMI 音视频。系统不使用 CPU、操作系统或 IP/UDP 软件栈，两板通过 RTL8211E 千兆网口直连。

本说明以 `media/`、`render/` 的实际顶层、源文件清单、参数和约束为准。

[接线与操作速查](README-dual-board.md) · [media 工程](media/README.md) · [render 工程](render/README.md) · [源码功能索引](doc/dual-board/source-map.md) · [文档导航](doc/README.md)

## 系统结构

```text
SDHC/SDXC 卡（FAT32） + media 板载 KEY2/3/4
        │
media：SDIO → FAT32 只读 → BMP 缩放 / WAV 解包 / TXT 首行
       图片目录、音乐列表、文件浏览器、设置、配音与应急音频恢复
        │  自定义 Ethernet 协议 1.14，EtherType 0x88B5
render：SDRAM 双帧 → 转场 / 对比度 / 饱和度 → 图层合成 → HDMI
        PCM 缓冲 → 48 kHz 播放 / 音量 → HDMI 内嵌音频
        ▲
TM1650 矩阵键盘 + 两路应急 GPIO + 本地日期时钟
```

| 项目 | 实际配置 |
|---|---|
| FPGA | 每板 EG4S20BG256，9800 Slice、19600 LUT、64 BRAM9K、16 BRAM32K、29 DSP、4 PLL |
| 板级输入时钟 | 两板均为 50 MHz |
| media 总线 / SD 时钟 | 50 MHz / 初始化 200 kHz、读卡 25 MHz，SDIO 4 位只读 |
| render 总线 / SDRAM 时钟 | 100 MHz / 125 MHz，SDRAM 另有相移时钟 |
| 网络 | RGMII 125 MHz，千兆全双工，固定 MAC |
| 视频 | RGB888，1280×720；75 MHz 像素时钟，1650×750 总时序，约 60.606 Hz |
| HDMI | 375 MHz 五倍时钟、TMDS；48 kHz PCM 音频，文件样本为 16 bit 单/双声道 |
| 帧缓存 | render 的 2M×32 SDR SDRAM，8 MiB；两个 RGB888 帧共 5,529,600 字节 |

`top_render` 保留 VGA RGB/HS/VS 信号，但 ADC 全部设为 **virtualIO**，没有可直接连接的物理 VGA 输出。HDMI DDC 用于 DDC/CI 亮度控制；EDID 自动读取关闭，分辨率固定。

## 功能

### 图片、缩放与轮播

- 上电挂载根目录，按目录枚举顺序缓存最多 **256 张普通 BMP**，自动加载首张；**自动轮播默认关闭**。
- 接受宽高各 **1–4096**、24 bpp、`BI_RGB`、正高度、自下而上的 BMP；检查文件头、像素偏移、行对齐与文件长度。
- 最近邻等比 `contain` 到 1280×720，居中补黑；极窄/极扁图片至少保留 1 像素。网络始终传完整 720p RGB888 帧。
- 支持上一张、下一张、浏览器指定图片；加载/动画中的切图请求合并为一次待执行请求，保留最后方向。
- 转场可选 **FADE、SMOOTH SLIDE、GRID DISSOLVE、RANDOM**：交叉淡化、平滑上推、8×6 网格错峰消隐；RANDOM 循环使用固定 64 项效果表。动画按 30 帧推进，约半秒，另有提交与读通路交接。
- 轮播间隔 **5–300 秒**、步进 5 秒、默认 5 秒；至少两张图片才可开启轮播。菜单、配对查找、台标加载及应急等占用期间暂停推进。
- 加载时保留旧图；完整像素数、整帧 CRC32、实际 SDRAM 写完成及视频域交接通过后才回复 `IMG_PRESENTED`。加载有超时与有限重试，失败不提交半张图。

### 音乐、图片配音与音量

- 浏览器选择 WAV 播放；支持暂停/恢复、双击下一首、板载键长按快进 5 秒、矩阵 `9` 退出播放。
- WAV 格式为 **RIFF/WAVE、PCM format 1、48 kHz、16 bit、单声道或立体声**，单声道复制到左右声道。支持跳过未知 chunk 和奇数字节填充，`fmt ` 必须先于 `data`。
- 开机缓存最多 **64 首普通 WAV** 供“下一首”循环选择；普通选曲播完即停，不自动连播下一首。没有 BMP 的卡仍可通过菜单播放 WAV。
- 图片实际显示后自动查找同主文件名 WAV，**配音查找不依赖 SD 字幕开关**。有配音且轮播开启时等实际播完才切图；轮播关闭时循环该配音。无配音时已选背景音乐继续，轮播使用间隔设置。
- 配音前保存背景音乐、render 确认的消费位置和暂停状态，切出图片时停止配音并恢复背景音乐。显式选曲/下一首改为用户选择的音轨。
- 矩阵 `9` 停止音轨、清空待播缓冲、隐藏播放卡片，并取消当前配音循环及此前背景音乐恢复；下一张图片或重新选曲可再次启动音频。
- 快进依据实际消费位置加 240000 帧，保持暂停态，钳位到曲尾前 1 秒；短于 2 秒或已到最后 1 秒时忽略。
- 音量 **0–100%**、步进 5%、默认 100%，使用平滑数字增益。关窗矩阵 `2/8` 调音量并显示约 2 秒提示，边界操作也提示。音量为 0 时进度仍可继续。
- render 使用 8 KiB BRAM 播放环，通常预填 1024 帧，短曲 EOF 可提前播放。48 kHz 节拍连续运行，暂停、断线或欠载时静音。PCM 信用按实际消费位置控制，不把网络接收量当作已播量。

### 菜单、文件浏览与字幕

设置主页十项依次为：**FILE BROWSER、BRIGHTNESS、CONTRAST、SATURATION、TEXT OSD、VOLUME、SD SUBTITLE、CLOCK、TRANSITION、INTERVAL**。

文件浏览器只列根目录文件，每页缓存 **8 项**，名字显示前 **32 字符**，跨页重扫目录；不进入子目录。BMP、WAV、TXT 分别交给对应加载器，错误留在状态行。保留名 `OVERLAY.BMP` 从浏览器和普通图片目录隐藏。

| 文字来源 | 使用方式 |
|---|---|
| 本地 Text OSD | render 保存最多 256 字符；方向键移动、5 确认，输入 A–Z、SPACE，支持 DEL、CLR、ON/OFF；初始为空且关闭 |
| 手动 SD TXT | 浏览器选中 TXT，实际显示提交成功后关窗，开启 DISPLAY、关闭 AUTO；空文件可清空手动字幕 |
| 自动 SD TXT | 打开 AUTO 同时开启 DISPLAY；按当前 BMP 主文件名匹配 TXT，切图更新绑定，缺失、歧义、非法名称有状态提示 |

SD SUBTITLE 的 **DISPLAY、AUTO 默认均关闭**，还提供 CLEAR MANUAL。DISPLAY 开启时 SD 字幕优先于本地文字；关闭 DISPLAY 回到本地 Text OSD。两套存储独立，清除手动缓存不删除本地编辑文字。

TXT 最多检查前 **260 字节**，接受可打印 ASCII、TAB、CR/LF，可有文件头 UTF-8 BOM；TAB 转空格，仅显示首行、最多 256 字符。超长标记 `TRUNCATED (256)`，多行标记首行状态；检查范围内含中文等非 ASCII 字节会拒绝。

主屏文字位于 **y=64、x=192–1087** 的 896 像素窗口；74 字符以内居中，75 字符起每两帧左移 1 像素，首尾各停 61 帧后循环。自动字幕与图片 ID 绑定、转场时隐藏；菜单、应急、诊断画面隐藏主屏文字。编辑器显示长度和末尾预览；菜单与字幕使用抗锯齿字模、双银行缓存和帧界提交。

### 图片调节、台标与播放界面

| 功能 | 范围 / 行为 |
|---|---|
| BRIGHTNESS | 10–100%，步进 10%，默认 100%；优先读写并验证 DDC/CI VCP `0x10`，失败回退 RGB 缩放并周期重探测 |
| CONTRAST | 0–200%，步进 10%，默认 100%；围绕 128 调图片 RGB，0% 为中灰，补黑边也受影响 |
| SATURATION | 0–200%，步进 10%，默认 100%；只调图片，0% 灰度、100% 原色 |
| 台标 | 根目录 `OVERLAY.BMP` 转 RGB565，64×64、不透明，x=1200–1263、y=16–79；失败隐藏、不影响主图 |
| 播放卡片 | 左上时钟下方，x=8、y=88、136×52；已播/总时长、进度条、播放/暂停图标 |
| 频谱 | 底部 y=624–711，80 根玻璃条；条宽 12、节距 16、最大高 88 像素，四行圆头和顶部高光 |

频谱由 **12 频点、256 样本块、三角窗 Goertzel** 加峰值/衰减驱动，插值成 80 根显示条；不是 80 个独立频带，也不执行完整 FFT。暂停保持显示值，分析输入取音量增益前 PCM。台标和播放卡片/频谱在设置、应急、诊断和断线场景隐藏，台标不参与主图转场。

像素链的固定顺序：

```text
图片混合 → 图片对比度 → 图片饱和度 → 诊断 → 台标 → 菜单
→ 播放卡片/频谱 → 文字/SD字幕 → 音量提示 → 软件亮度 → 应急 → 日期时钟
```

软件亮度影响普通图像与 UI，应急和时钟在其后绘制；显示器自身 DDC 亮度仍影响整屏。

### 日期时钟与应急

render 独立计时，左上角显示 `YYYY-MM-DD`、`HH:MM:SS`，支持 **2000–2099**、大小月、闰年及世纪回绕。默认 `2000-01-01 00:00:00`，无 RTC/掉电保存。切图、暂停、应急、media 复位和板间重连不重置时钟，render 系统复位会重置。

CLOCK 页提供 YEAR→MONTH→DAY→HOUR→MINUTE→SECOND→APPLY：`2/8` 选字段、`4/6` 循环增减，只有 APPLY 上按 `5` 才提交草稿并清零亚秒计数。调整年月会钳位非法日期，编辑期间实际时钟继续走；返回、关窗、应急或连接/输入取消会丢弃未提交草稿。

应急三路来源为 **GPIOB0 高电平、GPIOB1 高电平、矩阵 C 键按下切换锁存**。GPIO 高低均经约 1 ms 稳定确认，任一来源有效即本地接管画面并屏蔽普通操作。

- 黑底红色左/右箭头、三角感叹号或组合图形；有效来源按确认顺序显示，同周期用 `=`、先后用 `→`。
- 每路保存 CLOCK 的触发年月日时分秒、最多三行；持续有效时不变，解除移除，重触发更新时间并排到末尾。
- 循环播放 `EMERG.WAV`，数字增益固定 100%，保留用户日常音量。缺文件、格式或读取失败时保留警报图并静音。
- 全部来源解除后恢复保存的完整图片、音轨实际消费位置、暂停和轮播状态。来源增减不重启应急音频，恢复中重触发沿用原快照。
- 无网络时仍能显示本地警报，远端音频和完整恢复依赖链路及素材有效。

## 快速开始

### 接线与素材

| 连接 | 接法 |
|---|---|
| SD 卡 | media；SDHC/SDXC，FAT32，512 字节逻辑扇区 |
| 网线 | 两板 RTL8211E 网口直连、千兆全双工 |
| HDMI / 声音 | render 接支持该视频时序和 HDMI 音频的设备；外接音箱接显示器音频出口 |
| TM1650 | render J2 pin31：SCL=`GPIOB_26`/J12；pin33：SDA=`GPIOB_28`/K14；pin29/pin30：3.3V/GND；两线外部上拉到 3.3V |
| 应急 | render J2 pin1/pin2：GPIOB0/P4、GPIOB1/N4；0/3.3V，与 render 共地，内部下拉 |

所有素材放根目录，英文长文件名和 8.3 名均可。文件系统支持 MBR FAT32 主分区或无分区 FAT32 卷；应用不递归子目录，非 ASCII 长文件名不能完整显示，也不适合自动配对。

```text
SD 根目录/
  PHOTO01.BMP      普通图片
  PHOTO01.WAV      可选同名配音
  PHOTO01.TXT      可选同名自动字幕
  MUSIC.WAV        手动选择的背景音乐
  MANUAL.TXT       手动字幕
  OVERLAY.BMP      可选固定台标
  EMERG.WAV        可选应急音频
```

台标必须是标准 54 字节头、64×64、24 bpp、BI_RGB、正高度、总长 **12342 字节**；普通 BMP 允许更大的合法像素偏移。`EMERG.WAV` 不进入普通“下一首”列表，文件浏览器仍可列出它。

离线工具从仓库根目录运行。图片工具依赖 Pillow；WAV 工具用 Python 标准库读取 PCM WAV，**不能直接解码 MP3/AAC**。

```powershell
python tools/convert_fpga_bmp.py photo.png -o PHOTO01.BMP --mode contain
python tools/convert_sd_overlay.py logo.png OVERLAY.BMP
python tools/convert_fpga_wav.py input.wav -o MUSIC.WAV --ch 2
python tools/inspect_wav.py MUSIC.WAV
```

BMP 转换器离线输出 1280×720，可选 cover/stretch；板上只实现 contain。示例见 [字幕](examples/sd-subtitle/README.md)、[台标](examples/overlay/README.md)、[应急音频](examples/emergency/README.md)。

### 烧录与操作

两板烧同一套配对，完整功能为 `MultimediaSystem_media` 与 `MultimediaSystem_render`；`*_linktest.bit` 仅用于 PRBS。发布入口为 [Second_Release_682b0ab](release/Second_Release_682b0ab/README-签核说明.md)，包含 bit、完整 SHA256、输入指纹和最终 QoR。资源与时序数字只适用于该固定构建，重新构建后按新报告验收。

| 场景 | media 板载键 | render 矩阵键盘 |
|---|---|---|
| 设置开关 | KEY3 打开/关闭 | `*` 打开；`#` 子页返回、主页关闭 |
| 主页/列表 | KEY2 单击向后、KEY4 短按确认 | `2/8` 上下、`5` 确认 |
| 子页返回 | KEY2 双击 | `#` |
| 亮度/对比度/饱和度/音量/间隔 | KEY2 增、KEY4 减 | `4` 减、`6` 增 |
| SD SUBTITLE / TRANSITION | KEY2 选行、KEY4 确认 | `2/8` 选行、`5` 确认 |
| Text OSD / CLOCK 编辑 | KEY3 关闭、KEY2 双击返回；不编辑字段 | `2/8/4/6` 移动或调整、`5` 执行 |
| 主屏切图 | KEY2 按下下一张，空闲时长按 2 秒切轮播 | `4/6` 上一张/下一张、`A` 切轮播 |
| 主屏有音轨 | KEY4 单击暂停、双击下一首、长按 2 秒快进 | `5` 单击暂停、双击下一首；`9` 退出 |
| 主屏音量 | — | `2` 增、`8` 减 |
| 应急 | — | `C` 切换键盘警报；GPIO 独立控制 |

矩阵排列为 `1 2 3 A / 4 5 6 B / 7 8 9 C / * 0 # D`；B、D、0、1、3、7 未分配常规动作。方向键按下执行一次，500 ms 后每 150 ms 连发；取消流程后先松键。菜单 KEY2 单击、关窗暂停单击等要等 300 ms 双击窗口。关窗 KEY2 按下就切下一张，因此长按可能先切图再切换轮播。

## 板间传输与恢复

协议定义在两板 `rtl/pkg/board_link.vh`，当前为 **1.14**。固定 MAC 为 media `02:00:00:00:00:01`、render `02:00:00:00:00:02`，EtherType `0x88B5`，无 IP/UDP/ARP。32 字节应用头、单包净荷≤1024 字节且 4 字节对齐，控制/PCM/图像通道分配 2/2/4 个发送槽。

链路检查 MAC/FCS、应用 CRC32、会话和每通道序号，按序交付、累计确认、有限重传。HELLO 约 20 ms、对端超时约 100 ms；**media 的半速重传计数配合顶层覆盖值得到约 1 ms，render 默认约 5 ms**。minor 字段不能视为可靠的混烧拦截：接收实现没有独立保留并严格校验它，始终按发布配对使用。

图片与台标有 BEGIN/READY/DATA/END 和最终显示确认；菜单快照为 **296 字节**，SD 字幕快照为 **264 字节**。音频以 epoch、暂停/冻结确认、实际消费位置反馈流控，未播窗口上限 1536 帧。断线取消未完成对象并静音；已进入转场的有效图片事务可继续完成，重连重新发送状态/设置、重放图片并按确认进度重启音轨。普通菜单/设置和本地文字的保留不等于掉电持久化。

## 构建与验证

使用 Tang Dynasty **6.2.168116**、ModelSim **10.5b**、PowerShell **7（pwsh）** 和 Python 3。TD 两板构建顺序执行，使用新的 RunTag 保留产物。

GUI 打开 [media](media/MultimediaSystem_media.al) / [render](render/MultimediaSystem_render.al)，Reset Syn/Phy 后运行至 Generate Bitstream，输出在各板 `MultimediaSystem_*_Runs/phy_1/`。CLI 输出在各板 `Runs/`。

```powershell
# 仓库根目录；显式配置的构建示例
$env:TD_ROOT='D:/AnLu_FPGA_environment'
$env:MODELSIM_BIN='D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem'
pwsh -NoProfile -File ./media/build/run.ps1 -Stage all -RunTag local -AreaEffort medium -ShareArithmetic -MinRippleLength 16 -PlaceSeed 9 -NoPostPlaceOpt
pwsh -NoProfile -File ./render/build/run.ps1 -Stage all -RunTag local -InferFsm off -AreaEffort high -PhysicalEffort medium -PlaceSeed 6
pwsh -NoProfile -File ./media/build/check-reports.ps1 -RunDir ./media/Runs/phy_local
pwsh -NoProfile -File ./render/build/check-reports.ps1 -RunDir ./render/Runs/phy_local
```

支持 project/syn/phy/all。单跑 phy 需要同 RunTag、输入指纹相同的综合目录。新增/改名源码同步维护本板 `build/sources.txt`、`build/modules.json`，再用 `-Stage project` 重建 `.al`。GUI/CLI 的配置和 bit 不保证相同。

两板脚本要求 **Setup/Hold WNS≥0、TNS=0、违例端点=0**，Slice≤9800、BRAM9K+FIFO9K≤64、BRAM32K≤16，LUT/寄存器/DSP 不超容量，并核对输入指纹与产物。80% Slice 只是提示线，不存在统一 RAM≤56 或 WNS≥0.100 ns 门槛。

```powershell
python ./tools/dual-board/audit.py
pwsh -NoProfile -File ./media/sim/run.ps1 -Test tb_bmp_scale -ScaleFull
pwsh -NoProfile -File ./media/sim/run.ps1 -Test tb_sd_subtitle_fat
pwsh -NoProfile -File ./render/sim/run.ps1 -Test tb_sdram_read_contract
pwsh -NoProfile -File ./render/sim/run.ps1 -Test tb_text_osd_scroll
pwsh -NoProfile -File ./render/sim/run.ps1 -Test tb_calendar_clock
pwsh -NoProfile -File ./render/sim/run.ps1 -Test tb_emergency_timestamp
pwsh -NoProfile -File ./tools/dual-board/run-system.ps1 -ScaleBmp
pwsh -NoProfile -File ./tools/dual-board/run-system.ps1 -Test tb_audio_system -ScaleBmp
pwsh -NoProfile -File ./tools/dual-board/run-regression.ps1
```

`run-regression.ps1 -SkipSystem` 跳过其联合系统组；脚本并非所有 tb/实验脚本的自动枚举器。用例参数、原语模式、应急场景和 PRBS 见板级 README。仿真、STA、实板功能与长期稳定性分开记录，见[验收文档](doc/dual-board/hardware-acceptance.md)。

## 诊断与边界

屏幕提供 WAIT DATA、LINK DOWN、ERROR n，浏览器/字幕页另有状态。相同 ERROR 数字可能来自 SD/FAT、加载或本地扫描故障，需结合调试信号定位。media `LED1=~link_up`，render `LED1=~display_valid`；这是顶层逻辑值。render 的 `DBG_LINK_UP`、`DBG_LINK_EVENTS`（重传/接收拒绝/丢弃）、`DBG_BMP_LOAD_DONE`、`DBG_EMERGENCY_MODE/STATUS` 是 virtualIO 观察点。独立 [media PRBS](media/diag/README.md) / [render PRBS](render/diag/README.md) 用 `0x88B6` 测双向数据和错误计数。

系统不解码视频、JPG/PNG、MP3/AAC，不支持 exFAT、FAT16、SDSC、子目录播放、中文字幕、透明台标、板上 cover/stretch 或 RTC 掉电保存。SD 初始化/目录缓存主要在启动建立，更换卡或素材后应复位 media，不应假定热插拔自动挂载。网络不提供交换网络发现、多终端或普通网卡客户端。render 发布构建 BRAM/DSP 已满，扩展需重新评估资源与时序。

## 目录与文档维护

| 路径 | 内容 |
|---|---|
| `media/`、`render/` | 各自独立的 RTL/IP/约束/构建/仿真/诊断工程 |
| `release/` | 固定发布配对、校验和及签核材料 |
| `tools/dual-board/` | 依赖审计、联合仿真、专项验证与构建实验工具 |
| `tools/convert_*.py`、`tools/inspect_wav.py` | 离线素材处理 |
| `examples/` | 台标、字幕、应急 WAV 示例 |
| `doc/dual-board/` | 协议、源码索引、实现、验收和开发记录 |
| `doc/single-board/`、根目录单板工程 | 原单板基线，分开维护 |

README 记录用途、功能、输入约束、接线、操作与构建入口。开发时间线、逐轮资源/时序、排障与实验结论放在[开发与验证记录](doc/dual-board/development-history.md)及专题文档；发布 README 只描述固定配对。
