# media：SD 存储、媒体解析与播放控制

原生工程为 [MultimediaSystem_media.al](MultimediaSystem_media.al)，顶层 [top_media](rtl/top_media.v)，器件 EG4S20BG256。独立构建只读取本目录 RTL/IP/约束；系统接线和操作见[主 README](../README.md)与[速查](../README-dual-board.md)。

## 职责与结构

```text
top_media
├─ board_sys_pll / board_reset / reset_sync
├─ db_ethernet + db_link               千兆 MAC / 可靠传输
├─ media_core
│  ├─ sd_card_sdio                     唯一 SD 引脚所有者
│  ├─ glue_storage → storage_service → fat32_ro
│  ├─ fat_chain_map + lba_stream1      WAV 段表与独立读流
│  ├─ fat_bmp_controller → BMP探测 / 几何 / 解包 / 缩放 / 行缓存
│  ├─ rgb888_word_packer              RGB888 紧凑打包
│  ├─ fat_wav_controller → WAV头 / PCM解包
│  ├─ wav_playlist / audio_transport / volume_controller
│  ├─ file_browser / settings_menu_text_rom / 按键语义
│  ├─ sd_subtitle_controller / txt_prefix_parser / subtitle_ram
│  ├─ sd_overlay_controller
│  └─ emergency_media_controller      历史快照、应急音频与恢复
└─ seam_media                        图片/台标、PCM、UI、字幕与状态分发
```

本板不生成 HDMI、不访问 SDRAM、不扫描像素、不计算频谱；render 承担这些输出功能。日期时钟和本地 Text OSD 内容也在 render，media 只持有其菜单入口/页面生命周期。

## 时钟、复位与接口

| 信号 / 时钟 | 配置 |
|---|---|
| `sys_clk` | 50 MHz 输入 |
| `clk` / `bus_clk` | 50 MHz，文件系统、解析/缩放、菜单与链路总线 |
| `mem_clk` | 125 MHz，MAC 发送；不是 media SDRAM 时钟 |
| `tx_clk_90` | 125 MHz 相移，RGMII TX |
| `rgmii_rxc` / `rx_clk` | PHY 提供的 125 MHz 接收时钟 |
| SD | 初始化 200 kHz，读卡 25 MHz，4 bit，`DIV_INIT=125`、`DIV_FAST=1`、`SAMPLE_DLY=0`、`SPEED_TARGET=0` |
| 板载输入 | KEY2/3/4 低有效，消抖约 50 ms，长按 2 秒 |
| LED1 | 逻辑值 `~link_up` |

`board_reset` 等待系统 PLL 锁定，`reset_sync` 在各使用域释放复位。PHY 状态必须稳定且满足千兆全双工才允许建会话；MDC 固定低、MDIO 高阻，本工程不通过 MDIO 配置 PHY。

SD 初始化/挂载不依赖 render 上线，图像数据通过链路信用反压。卡控制器要求 SDHC 块寻址；SDSC 被拒绝，SDXC 需准备为 FAT32。更换卡或素材后复位 media，未实现自动热插拔挂载。

## 存储与文件系统

`sd_card_sdio` 在突发边界仲裁两个读者：ch0 为 FAT/目录/BMP/TXT/台标，ch1 为 WAV `lba_stream1`。突发开始后不允许任意字节停顿，因此各层先预留整段缓冲。

- `fat32_ro`：512 字节扇区，支持无分区 FAT32 卷或 MBR 四个主分区槽中首个匹配 FAT32 分区（0B/0C/1B/1C）；校验 BPB、簇几何和根目录，沿簇链读取。
- 文件名：8.3 与校验过的 LFN；可打印 ASCII 可显示，LFN 中其他字符映射为 `?`。浏览器/自动配对仅处理根目录，不递归。
- 保护：非法簇、提前 EOC、循环/跳数上限、I/O 超时、段表溢出及协作 abort 均有结束/错误返回。
- `storage_service`：锁存挂载、目录、BMP/TXT、map 请求并串行分派；目录一次授权持有到完成，浏览器优先于图片目录、字幕目录。
- 普通文件最大 4 扇区突发，BMP 头探测上限 512 字节，TXT 上限 260 字节。
- `fat_chain_map`：双 bank、每 bank 256 段 `{LBA,扇区数}`，合并连续簇。当前 WAV 固定使用 bank1；bank0 / `lba_stream0` 在 core 中保留但未启动，不是另一路已启用的视频播放。
- WAV 独立流最大 **1 扇区**；单声道每扇区产生 256 个左右声道帧，源端按 260 帧缓冲预留。只对尚未交付数据的可重试请求重试，不把任意流中错误宣称为无损恢复。

## 图片与台标

`fat_bmp_controller` 建立最多 256 个普通 BMP 的元数据目录，按枚举顺序加载首图；轮播默认关闭、默认间隔 5 秒，至少两张图才允许开启。文件浏览器可选择未进缓存目录的文件；确认显示后反查目录位置，使上一张/下一张继续按目录顺序工作。

普通 BMP 为宽高各 1–4096、24 bpp、BI_RGB、正高度、自下而上。先读取有界头、校验尺寸/偏移/长度，再计算 contain 几何；不支持 top-down、压缩 BMP、JPEG/PNG、板上 cover/stretch。几何缩放采用整数除法及舍入，最近邻按像素中心取样，居中补黑，最小维度为 1 像素。

完整路径为 `bmp_header_parser → image_scale_geometry → bmp_pixel_unpack → image_scale_nearest + image_row_store → rgb888_word_packer → seam_media`。4 KiB 原始字节 FIFO 隔开不可暂停 SD 突发与可反压缩放器，行缓存保存紧凑 RGB888 行。每帧 921600 像素，4 像素打成 3 个 32 位字，共 **691200 字 / 2764800 字节**；行序仍为 bottom-up，由 render 写侧翻转。

成功需文件读完、解包/缩放完、最后打包字交付并得到 render 的 PRESENTED。无进展超时 1 秒、读阶段绝对上限 15 秒、提交单独 3 秒，最多两次额外加载重试；已有图片时出错保留旧图并短暂提示。加载/转场间的切图请求合并一次，菜单打开时不启动下一次切图。

`OVERLAY.BMP` 为保留文件，不进入普通图片目录/浏览器。`sd_overlay_controller` 在主图已显示且存储/图像通道空闲时加载，要求标准 54 字节头、64×64、24 bpp、BI_RGB、正高度、12342 字节；转换为 **2048 个 32 位字的 RGB565 像素对**。与主图复用源 FIFO，使用独立对象 ID、CRC、READY/APPLIED 和 watchdog；失败静默隐藏，取消/重连按状态重试，不锁死普通图片调度。

## 音频、配音与恢复

`fat_wav_controller` 先建段表，解析 RIFF/WAVE 的 fmt/data，接受 PCM format=1、48 kHz、16 bit、单/双声道，支持未知 chunk 跳过和奇数字节填充。单声道复制为 L/R，发送字为 `{L16,R16}`；render 再扩展到 24 位内部样本并嵌入 HDMI。

`wav_playlist` 缓存最多 64 个普通 WAV，排除固定名 EMERG.WAV；显式下一首按表循环。普通曲目自然播完停止，不自动下一首；浏览器仍可选择表外 WAV。`audio_transport` 处理暂停、单/双击与快进，菜单/应急时屏蔽普通音频动作。

快进先要求 render 冻结并确认实际位置，再前进 240000 帧，目标最多到曲尾前 48000 帧；不足 2 秒或已经处于末秒时忽略。复用现有段表按新偏移重启，保留暂停状态。断线后按最后确认进度重新开流；不承诺与真实播放瞬间逐样本连续。

图片提交后，`sd_subtitle_controller` 共享两次根目录扫描，识别同主文件名 TXT/WAV。**WAV 查找独立于字幕 DISPLAY/AUTO**；匹配唯一才启动配音。配音保存背景音乐 cluster/size、已确认 epoch/消费位置和暂停态，切出图片恢复；轮播打开时等实际曲尾换图，关闭时循环配音，无配音则继续背景音乐并使用 INTERVAL。

矩阵 `9` 经 `keypad_action_router` 发 stop，清空待播环、停止当前音轨，同时取消当前配音重复和背景恢复；新图提交或显式选曲解除退出保持。音量由 `volume_controller` 单独保存，21 档 0–100%、步进 5%、上电 100%；经 VOLUME_SET 和 UI 快照送 render，增益计算在 render。

## 菜单、字幕与板载按键

`file_browser` 缓存当前页 8 项、每项显示前 32 字符，跨页重扫根目录，不列文件夹和 OVERLAY.BMP。BMP/WAV/TXT 选择分别经过 ack/rejected；手动 TXT 要等视频域 APPLIED 成功再关窗。

十项主页：FILE BROWSER、BRIGHTNESS、CONTRAST、SATURATION、TEXT OSD、VOLUME、SD SUBTITLE、CLOCK、TRANSITION、INTERVAL。菜单文本 32×9=288 字节，经 flags、饱和度扩展字组成 **296 字节** UI 快照；render 绘制十卡主页、数值页、列表及本地编辑页。

- KEY3 开关菜单；菜单 KEY2 单击向后、双击返回，KEY4 短按确认；数值页 KEY2 增、KEY4 减。
- 主屏 KEY2 按下下一张；空闲长按 2 秒切轮播；KEY4 单击暂停、双击下一首、长按快进。
- Text OSD/CLOCK 的编辑由 render 矩阵键盘完成，板载键仅返回/关闭。
- 亮度默认 100%、范围 10–100%；对比度和饱和度默认 100%、范围 0–200%。退出菜单/切图/链路重连不重置 media 中的设置，media 复位恢复默认。

SD 字幕保存手动、自动和冻结发送缓存，DISPLAY/AUTO 初始均 OFF；AUTO 打开会同时开 DISPLAY。手动选择 TXT 成功则 DISPLAY 开、AUTO 关；CLEAR MANUAL 只清手动缓存。读取前 260 字节、只显示首行、最多 256 字符，支持文件头 UTF-8 BOM、TAB 转空格；非法字符、首行、截断、缺失、歧义和读错误有状态。字幕快照 **264 字节**，自动模式绑定已提交图片 ID，等帧界 APPLIED 确认；匹配失败不显示上一图片的自动字幕。

## 应急与链路

应急来源和触发时间在 render；本板收到带 revision 的应急快照，`emergency_media_controller` 保存有效图像/音频历史，锁住常规操作并循环 EMERG.WAV。缺失、格式/读错误或上下文丢失有状态回报。解除后恢复图片选择、音轨的确认位置和暂停态，恢复中重触发沿用原快照。应急数字增益在 render 强制 100%，不修改本板用户音量。

业务协议 **1.14**，控制/PCM/图片通道，固定发送槽 2/2/4。media 顶层显式覆盖 CLK_HZ=50 MHz、RETRY_CYCLES=CLK_HZ/2000，内部重传计数半速，实际重传间隔约 **1 ms**；HELLO 20 ms、对端超时 100 ms。render 链路副本有自己的时序优化，不能假定两份 db_link 逐字节相同。

`seam_media` 优先调度应急/控制、音频再图像。图像流 FIFO 为 1024×32 bit，PCM 源 FIFO 为 512×32 bit；未播信用窗口 1536 帧，使用当前音频 epoch 的实际 POSITION，避免暂停时继续无限堆积。重连重发设置/状态、重放图片、重载台标并恢复音轨。minor 字段不是严格混烧拦截，按配对发布版本使用。

## 构建与检查

从仓库根目录运行，PowerShell 7：

```powershell
$env:TD_ROOT='D:/AnLu_FPGA_environment'
pwsh -NoProfile -File ./media/build/run.ps1 -Stage all -RunTag local -AreaEffort medium -ShareArithmetic -MinRippleLength 16 -PlaceSeed 9 -NoPostPlaceOpt
pwsh -NoProfile -File ./media/build/check-reports.ps1 -RunDir ./media/Runs/phy_local
```

脚本默认 area_prior、InferFsm=off、AreaEffort=high、PhysicalEffort=high、seed4；上例显式改为 medium 综合与共享算术配置，并关闭 post_place_opt。复制/新增源码后维护 `build/sources.txt`、`build/modules.json`，用 `-Stage project` 重建 `.al`。CLI 使用 `Runs/syn_<tag>`、`Runs/phy_<tag>`；GUI 使用 `MultimediaSystem_media_Runs/`。

签核要求 Setup/Hold WNS≥0、TNS/端点=0、器件容量不超限及构建输入指纹一致；Slice 80% 为提示，RAM 按 9K/32K 类型分别核算。发布构建的固定数字见[发布配对](../release/Second_Release_682b0ab/README-签核说明.md)，开发资源/时序过程见[独立记录](../doc/dual-board/development-history.md)。

## 仿真与诊断

```powershell
$env:MODELSIM_BIN='D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem'
pwsh -NoProfile -File ./media/sim/run.ps1 -Test tb_media_sd_boot -ScaleFull
pwsh -NoProfile -File ./media/sim/run.ps1 -Test tb_bmp_scale -ScaleFull
pwsh -NoProfile -File ./media/sim/run.ps1 -Test tb_fat32_directory
pwsh -NoProfile -File ./media/sim/run.ps1 -Test tb_sd_subtitle_fat
pwsh -NoProfile -File ./media/sim/run.ps1 -Test tb_image_companion_switch
pwsh -NoProfile -File ./media/sim/run.ps1 -Test tb_keypad_router
pwsh -NoProfile -File ./media/sim/run.ps1 -Test tb_settings_menu -SharedKeys
pwsh -NoProfile -File ./media/sim/run.ps1 -Test tb_temac_gate
```

用例清单和参数以 [sim/run.ps1](sim/run.ps1) 为准；包括 -SingleSector、-ExternalPosition、-CancelGlitch、-PhysicalOverlayRam、应急错误/重入/复位场景等。联合仿真入口见主 README；默认板内证据放 `build/evidence/`。独立链路实测见 [diag](diag/README.md)。core 中的 SD 初始化、错误码、状态、UI、WAV 重试/错误观察口未全部导出为顶层物理引脚，调试时沿层级观察。

## 源文件维护

实际构建清单为 [build/sources.txt](build/sources.txt)，包括 RTL、TEMAC IPC 和 ADC/SDC；目录里的未引用模块不代表顶层启用了相应功能。全量文件归属见[源码索引](../doc/dual-board/source-map.md)。协议副本见 [doc/protocol-v1.md](doc/protocol-v1.md)，开发历史和失效用法按[开发记录](../doc/dual-board/development-history.md)查阅。
