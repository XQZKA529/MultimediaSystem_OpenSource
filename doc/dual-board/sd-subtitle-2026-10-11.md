# SD 卡 TXT 静态字幕（2026-10-11）

## 当前扩展：256 字符居中滚动（协议 1.12）

当前 RTL 将两种字幕来源统一扩至 256 字符：本地手打 Text OSD、文件浏览器手动 TXT、按当前 BMP 名称自动匹配的 TXT。720p 字幕窗口为 x=192–1087、宽 896 像素、y=64；74 字符及以内按宽度居中，75 字符及以上在窗口内向左滚动，每两帧移动 1 像素。首尾停 61 帧后循环，提交新内容、切换来源或隐藏后重显时从开头开始。绘制和抗锯齿暗边均裁剪在窗口内。

TXT 前缀读取上限为 260 字节，覆盖可选 BOM、256 字符和超长判定字符；超出 256 字符会保留前 256 字符并显示 `TRUNCATED (256)`。媒体发送 264 字节快照，flags 长度为 bits8:0，显示/自动/截断/首行标志为 bits9–12，文本为 256 字节。两板必须配套使用协议 1.12。下文 2026-10-11 内容记录协议 1.7 首版的设计与验收证据；其中 106 字符和 110 字节数值属于历史版本。

本轮新增验证入口为 `./render/sim/run.ps1 -Test tb_text_osd_scroll`（滚动速度、两端停顿与复位）及 `./render/sim/run.ps1 -Test tb_text_osd_frame_ppm`（完整720p像素/同步参考）；parser、controller、SD视图、真实FAT和双板系统仍使用下方列出的原有命令。

本轮实现两板配套的TXT字幕功能，协议1.7。实现、仿真、工具签核与实板验证分别记录；配套产物状态见文末。新增存储优先使用每板一块BRAM32K，字体与像素叠加流水复用现有Text OSD。

## 文件和操作

使用FAT32根目录的`.TXT`文件，推荐UTF-8无BOM，兼容文件开头EF BB BF。支持ASCII英文大小写、数字、空格及0x20..0x7e符号，TAB转一个空格。第一行以CR、LF或EOF结束，最多106字符，超长截取并提示。最多读取110字节；这部分中的非ASCII、NUL及不支持的控制字符均判格式错误，第一行之后只做字符合法性检查。空文件、ASCII合法内容的空首行是有效空字幕。后续未读取的字节不参与校验。

自动模式按图片实际显示成功后的簇号和大小先取得完整BMP名称，再扫描完整同主名TXT；大小写不敏感，支持ASCII SFN/VFAT，不使用浏览器32字符预览或哈希替代比较。包含无法可靠比较字符的名称不支持；多个匹配判歧义。图片先显示，字幕随后出现，大目录可能需要两次完整枚举。

示例：根目录`PHOTO01.BMP`与`PHOTO01.TXT`，TXT写入`Welcome to the FPGA Multimedia System!`。可复制 [示例目录](../../examples/sd-subtitle/)。不增加中文、时间轴、滚动、分页、子目录或SD写回。

KEY3或矩阵*打开设置，第六项为SD SUBTITLE。矩阵2/8选择、5确认、#返回；板载KEY2单击选择、KEY4短按确认、KEY2双击返回、KEY3关闭。子页包括DISPLAY、AUTO、CLEAR MANUAL及状态。文件浏览器选择TXT使用独立字幕请求，收到VS提交成功确认后关闭浏览器，失败留在浏览器显示原因。

| 状态或操作 | 行为 |
|---|---|
| 上电/media系统复位 | 显示关，自动关，手动与自动为空 |
| 手动TXT加载成功 | 保存手动内容，显示开，自动关；切图保留 |
| 手动加载或业务提交失败 | 保留原内容、模式与显示开关 |
| 自动开 | 显示开，立即查找当前图片；以后随IMG_PRESENTED更新 |
| 自动关 | 恢复保存的手动内容，无手动则空 |
| 显示关 | 隐藏字幕，保留文本和自动设定；再次开启自动显示时刷新当前图片 |
| 自动匹配缺失/歧义/名称不支持/读取失败 | 当前图片自动字幕为空，显示具体状态 |
| 清除手动 | 清除保存的手动文本；自动内容不受影响 |
| SD显示开 | 独占顶部文字来源，空文本也抑制本地Text OSD |
| SD显示关 | 原Text OSD按保存的开关与内容恢复 |
| 菜单/诊断 | 隐藏主屏字幕，本地文字编辑器仍访问原缓存 |
| 淡化 | 自动字幕隐藏，成功换图等待新字幕；失败继续旧图字幕；手动字幕保持 |
| 断线/重连 | 保留media运行内存，重新发送当前完整配置 |

状态：READY、LOADING、TRUNCATED (106)、FIRST LINE ONLY、NO MATCHING TXT、FORMAT ERROR、READ/APPLY ERROR、NAME UNSUPPORTED、AMBIGUOUS NAME、APPLYING。状态短标签与菜单文本共用一块既有BRAM9K，实际960/1024字节。ROM地址先寄存再读取，菜单每字符等待三拍；浏览器状态行已有取字等待覆盖这两拍ROM延迟。

## 实现接口

- media：`txt_prefix_parser`处理有限前缀；`sd_subtitle_controller`在一块BRAM32K中分区保存完整名称、候选、手动、自动和冻结发送快照。手动文本在APPLIED成功前留在候选区，失败回滚；目录操作和业务提交复用互斥的超时计数器，提交确认必须对应当前已发布的revision。
- 存储：`storage_service`保留挂载、目录、BMP、TXT和WAV簇链请求，当前所有者完成FAT/SD收尾后才移交；目录请求使用候选grant，目录响应只送已接受并锁定的所有者，空闲期间各客户端数据面归零。TXT110字节有限读取至多一个扇区，新的图片任务在字幕忙时等待，既有PCM的独立SD读取继续运行。
- render：`sd_subtitle_view`校验固定116字节消息、ASCII和零填充，写非活动银行，在VS原子提交。可靠会话隔离旧包；已发布银行通过四阶段握手持有至收尾。自动文本与实际显示image_id关联，独立视频复位可重新发布成功配置。网络接收处将单字数据和结束标记一起寄存；包头检查阶段提前解码通道、等待条件和图片FIFO信用，保留既有可靠握手。信用寄存的一拍延迟由既有32字预留空间覆盖，每个载荷字仍检查FIFO满标志。
- 合成：`render_core`在SD和本地文本之间选择，复用同一个`text_osd_overlay`及共享字库。白字、四档抗锯齿、顶部居中和轻微暗边保留。
- 协议：可靠通道0的0x35 SET与0x36 APPLIED，详细116字节字段及结果码见 [协议1.7](protocol-v1.md)。两板必须配套更新。

## 可重复验证

在工程根目录执行：

```powershell
./media/sim/run.ps1 -Test tb_txt_prefix_parser
./media/sim/run.ps1 -Test tb_sd_subtitle_controller
./media/sim/run.ps1 -Test tb_sd_subtitle_fat
./media/sim/run.ps1 -Test tb_settings_menu -SharedKeys
./media/sim/run.ps1 -Test tb_settings_rom
./render/sim/run.ps1 -Test tb_sd_subtitle_view
./render/sim/run.ps1 -Test tb_sd_subtitle_view -PhysicalSubtitleRam
./tools/dual-board/run-system.ps1 -Test tb_sd_subtitle_system
./tools/dual-board/run-regression.ps1 -SkipSystem
python tools/dual-board/audit.py
```

解析21个用例覆盖BOM/无换行/CR-LF/CRLF/TAB/空行/106和107字符/超长/非法编码与控制符/有限读取失败，包括仅BOM空文件、BOM加106/107字符的110字节边界，以及首行结束后读取范围内的非法字节。控制器21个快照覆盖手动提交/解析失败、APPLIED失败与业务超时保持、自动模式下手动失败保持、大小写、134字节完整文件名、完整扩展名、同名前缀、缺失/歧义/不支持名称、快速切图请求保留、显示重新开启后匹配当前图片、延后与新开关操作的合并，以及重连时同拍DISPLAY/清除操作先更新再冻结配置。render覆盖106字符、提交前会话切换拒绝、视频域单独复位恢复，使用真实BRAM32K模型复核。真实FAT联合测试包括MBR、VFAT、TXT在BMP之前、碎片文件、BMP信用反压和WAV簇链请求并发。

系统测试使用独立编译的media/render可靠网络端点，故意丢弃一个包以触发重传，真实FAT读取至字幕银行的VS提交，随后通过生产完整22拍合成链导出1280×720手动和自动字幕帧，并检查字幕读取期间的按键并发及断线重连配置重放。确定性PCM流与字幕共用生产可靠链路调度，256帧全部按序接收，其中255帧在字幕忙时发送；真实WAV读取和HDMI PCM播放由tb_audio_system -ScaleBmp另外覆盖。图片背景为确定性RGB图案；每个输出RGB像素与HS/VS/DE使用独立字模/整数混合参考检查。真实BMP完整720p读取和缩放另由tb_media_sd_boot -ScaleFull回归覆盖。

## 实板验收清单（待执行）

两板配套烧录并记录bit SHA256，先确认原图片/音频/菜单/文字编辑工作，再逐项记录：

- 手动TXT成功、空TXT、106/107字符、BOM、TAB、非法中文/NUL；加载失败保留原内容。
- 启动首图、浏览器切图、快速切图、轮播；TXT在BMP前后、大小写、长名、同名前缀、缺失与歧义。
- DISPLAY/AUTO/清除手动，本地Text OSD保存及恢复；菜单和诊断不漏字幕。
- 淡化时自动隐藏、成功换图无旧字幕串图、失败保留旧图字幕；手动字幕随切图保持。
- 读TXT期间连续播放WAV，暂停/切歌/快进并行；取消和全局关闭不提前释放目录/SD所有权。
- 拔插网线和两板分别复位，断线重连恢复配置，media复位默认关闭。
- 至少30分钟图片与音频混合轮播，无半行更新、旧字幕串图或错误；记录起止时间和素材。

## 构建与交付状态

构建要求Setup WNS≥0.100ns、Hold≥0、TNS=0，检查实际BRAM9K/32K类型、片上资源和完整输入指纹。media项目总RAM预算57，render56；器件物理容量是每板64块9K和16块32K。历史总RAM≤56不是器件上限。

原生构建在集成布线Hold修复之后再执行一次厂商`fix_hold`，最终检查修复后的报告；时钟和约束不放宽。WAV簇链段累计器提前准备写入使能，保持原有FAT操作所有权和段输出顺序。碎片段溢出立即进入错误收尾，不继续累计或发出下一段。

浏览器控制采用16位显式独热状态，返回状态也保存独热位，对外诊断仍保持0–15；菜单与翻页回归逐拍检查状态合法性。WAV未知块的补齐长度为零判断使用等价的原始长度比较，避免加法器串入控制使能，补充零、奇数、偶数、补齐及32位回绕测试。

FAT控制使用64位显式独热状态，所有对外诊断编号保持0–63；反向case声明并行分支，回归逐拍检查独热和编号一致性。FAT挂载范围、目录剩余扇区、文件跳数上限和字幕超时检查先落入单比特寄存器；文件初始簇在FILE_SELECT等待后校验，WAV初始簇在请求接受时分类，后续簇先通过FAT合法性校验；DBR保留扇区字段使用独立捕获使能；挂载几何算术的宽寄存器使用前一状态准备的专用写入使能。目录、文件和WAV走查复用已寄存的簇起始LBA，发读请求时只加扇区偏移；文件剩余数据标志与逐字节计数同步更新。media可靠发送仲裁同时保存所选包的重试耗尽状态，发送前仍校验槽位和序号。共享移位器的输入先保存在同一个分子寄存器中，避免状态选择与移位、加法串接。文件完成及成功状态在存储协调层按所有者冻结一拍，再送往图片/字幕控制器。相关FAT、有限读取、256段溢出及可靠链路回归覆盖这些时序调整。

media的网络载荷写入在包RAM旁寄存地址、数据和写使能；已接收的最后一字在槽位仲裁与包头CRC阶段完成写入，载荷CRC及MAC读取保持原有顺序。MBR工作字段使用独立捕获使能，省去不相关文件取消路径的扇出。FAT名称RAM写口寄存地址和数据，现有名字输出等待阶段覆盖末字写入。图片看门狗使用独立计数器写入使能，探测重试启动拍抑制旧计数超时判定。浏览器默认8行页的捕获范围使用对齐高位比较，普通/共享按键回归新增跨第8/9项的重枚举和TXT簇号检查。发送包对象来源与互斥选择位在原派发拍同时寄存，宽选择位于寄存器之后；头部反压和载荷期间全部冻结，发送优先级不变。PCM FIFO空状态与每次推拉同时更新，发送仲裁不再现场解码指针相等；512/1024深度随机推拉测试逐拍核对80,000拍空状态。快进目标分为请求当拍加法和下一拍钳位，业务请求与允许状态同步流水；外部位置在请求当拍改变的用例确认准确起点。包窗口、重传、CRC、序号回绕以及真实TEMAC的1024字节载荷回归通过。

render已通过CLI签核：`phy_sd_subtitle_credit`，Setup +0.101ns、Hold +0.022ns、Setup/Hold TNS=0，51 BRAM9K + 5 BRAM32K，8515 Slice（86.89%）。构建命令为`./render/build/run.ps1 -Stage all -RunTag sd_subtitle_credit -PlaceSeed 3 -PhysicalEffort medium`。最终报告以`MultimediaSystem_render_pr.timing`和`qualification.json`为准；厂商自动生成的`final_timing.rpt`可能早于第二次Hold修复。Setup距0.100ns签核门槛余量为0.001ns。

media于2026-10-12通过最终签核：`phy_sd_subtitle_browserhot_relax85_seed5`，Setup +0.112ns、Hold +0.022ns、Setup/Hold TNS=0，56 BRAM9K + 1 BRAM32K，9392 Slice（95.84%）。综合使用area_prior、infer_fsm off、AreaEffort high；布局为medium、seed 5、原生place relaxation 0.85，路由routability，保留原始时钟及约束。完整构建参数与入口保存在该run的`settings.cfg`、`entry.tcl`，上游综合为`../syn_sd_subtitle_browserhot`。可在工程根目录用`./tools/dual-board/rebuild-sd-subtitle-media.ps1 -RunTag sd_subtitle_release`从综合重建相同参数的media版本；该脚本拒绝覆盖已有run，复用综合时核对完整输入指纹。已核对其生成的设置与签核run逐字一致。RAM统计按最终实际映射计数；Slice超过80%提示线，两板仍符合器件容量及严格时序门槛。

| 板 | Setup WNS | Hold WNS | Setup/Hold TNS | BRAM9K | BRAM32K |
|---|---:|---:|---:|---:|---:|
| media | +0.112ns | +0.022ns | 0 / 0 | 56 | 1 |
| render | +0.101ns | +0.022ns | 0 / 0 | 51 | 5 |

配套交付目录为`build/sd-subtitle-release/`，包括bit、最终时序/资源报告、构建输入指纹、仿真证据、示例TXT、帧预览、实板验收清单及SHA256清单。使用以下命令在新的输出目录重新打包。脚本会拒绝未签核、输入已经变更、或最终STA丢失/改变原始时钟域的产物：

```powershell
./tools/dual-board/package-sd-subtitle.ps1 `
    -MediaRun media/Runs/phy_sd_subtitle_browserhot_relax85_seed5 `
    -RenderRun render/Runs/phy_sd_subtitle_credit -Output build/sd-subtitle-release-copy
```

两板工具签核和仿真验证已通过。media bit SHA256为`834e850707f6af6442dff078fe0f491c05b392e5a7b218441f4ae52d6218e9c9`；render为`a4aa86b4849bb5faa3dc7e59325a576e5a881619bf54b3a35a81bb994b35f8fb`。以交付目录`manifest.json`为准，必须配套烧录。实板烧录、图片音频并行、自动轮播及至少30分钟运行仍待按上述清单执行；工具签核不代替实板验收。
