# 图片切换 NOT A BMP / ERROR 4 排查（2026-10-24）

## 当前结论

**尚未唯一定位实板根因，未修改功能 RTL，也未生成修复 bit。** 已排除本次实查 SD 卡上 BMP 文件头不合法这一解释；未在 RTL 仿真中复现“新增同名 WAV 覆盖图片描述符”。当前 GUI 实现有明确的时序违例，其中 FAT 工作簇号寄存器的写使能是重点检查对象。时序报告不能单独证明此次错误一定由该路径引起。

用户确认：首图正常，重新选择首图也正常，其余图片通过浏览器选择时提示 NOT A BMP，通过切图键则提示 ERROR 4；素材此前能正常使用。

## 提示的实际含义

- `file_browser` 的 NOT A BMP 包含图像控制器明确拒绝以及等待回应超时，不能仅凭文字认定文件不是 BMP。
- `fat_bmp_controller` 的 ERROR 4 可来自头/尺寸校验失败，也可由通用文件错误转换而来；FAT I/O 超时 10 也被转换为显示码 4。
- 同名配音查找使用已提交图片的描述符，在图片显示完成后启动。待切图片在头探测阶段失败，不能直接解释成该图片的配音提前替代了 BMP。上一张音频与共享存储操作的相互影响仍需结合板上信号核验。

## SD 卡只读实查

用户将 SD 卡接为 F:。卷为 FAT32，512 字节/扇区、64 扇区/簇，保留区 738 扇区、两份 FAT、每份 3727 扇区，根目录簇 2，卷内数据区 LBA 8192。Windows 分区信息显示物理分区偏移 32 扇区。

实际根目录首张普通图片为 `TEST.BMP`，并不是 1280×720 素材。共检查 20 个 BMP，包含保留小图，所有文件头均合法：`BM`、24 bpp、BI_RGB、正高度，声明长度和实际长度一致。使用 FAT 目录起始簇换算出的卷内扇区，读取到的 BMP 头与 Windows 文件接口读取一致。

| 文件 | 起始簇 | 字节数 | 尺寸 | 卷内首扇区 |
|---|---:|---:|---|---:|
| TEST.BMP | 6 | 21654 | 120×60 | 8448 |
| PixPin_2026-10-09_15-36-14.bmp | 7 | 12288054 | 2560×1600 | 8512 |
| cablecar_fpga_1280x720.bmp | 383 | 2764854 | 1280×720 | 32576 |
| bridge_fpga_1280x720.bmp | 4751 | 2764854 | 1280×720 | 312128 |
| OVERLAY.BMP | 4844 | 12342 | 64×64 | 318080 |

未改动卡上文件或文件系统。原始卷扇区快照保存在 `media/build/evidence/sd-card-image-probe/`，共 137 扇区，包含卷引导扇区、根目录、文件首扇区及首图文件内容。物理盘 MBR 读取因 Windows 权限被拒绝，快照以卷引导扇区作为 LBA 0，不声称覆盖实际 MBR 读取路径。

重新只读采集：

```powershell
python tools/dual-board/capture-sd-image-probe.py --volume F: --out media/build/evidence/sd-card-image-probe
```

## 已完成验证

新增 `tb_image_companion_switch`，连接生产 `media_core`、真实 FAT32 服务、BMP 头/缩放/打包、字幕查找、WAV 控制器和双通道 SD 数据模型。

- 合成素材有 TXT/WAV：首图、切图请求和浏览器加载请求共完成三帧，匹配三个 WAV，PCM 确有输出。
- 无同名 TXT/WAV：三帧完成。
- 实卡扇区：完整读取并提交 TEST.BMP，执行同名 TXT 查找，再接受下一张 PixPin 的 BMP 头和尺寸。
- 实卡扇区：分别从浏览器请求接口接受 cablecar（簇 383）与 bridge（簇 4751）的头和尺寸。
- `tb_bmp_header`、`tb_bmp_controller`、`tb_sd_subtitle_fat`、`tb_media_sd_boot` 通过；工程审计和 `git diff --check` 通过。
- 独立综合当前 `bmp_header_parser`，使用厂商逻辑单元及 DSP 模型运行功能网表仿真，19 组原有头校验用例通过；实卡全部 20 个 BMP 头也均被接受。
- 用户确认下载 `best_result` 后，进一步导出同一 GUI 综合数据库，按原样提取头解析器的 582 个映射单元及一个跨模块共用逻辑单元。适配器固定 `C_PROBE=1`、`overlay_busy=0`，提供时钟、复位和文件输入；全部 20 个实卡 BMP 头通过。该验证使用整工程已生成的映射单元，没有重新独立综合解析器。证据为 `parser-from-gui.v`、`parser-from-gui-boundary.json`、`parser-from-gui-sim.txt`。仍是无布线延时的功能验证，未覆盖控制器和 SD 实板读数据。

复现主要集成验证：

```powershell
./media/sim/run.ps1 -Test tb_image_companion_switch
./media/sim/run.ps1 -Test tb_image_companion_switch -NoCompanions
./media/sim/run.ps1 -Test tb_image_companion_switch -RealCard
./media/sim/run.ps1 -Test tb_image_companion_switch -RealCard -CardTargetCluster 383
./media/sim/run.ps1 -Test tb_image_companion_switch -RealCard -CardTargetCluster 4751
```

实卡用例针对本次捕获的目录与簇号，不能用于任意其他卡的验收。仿真将输出缩小为 8×4；大图实卡用例停在头/尺寸通过并申请图像事务的阶段，没有宣称大图完整像素链通过。浏览器用例驱动其已解析的加载请求接口，未声称覆盖整个浏览器按键流程。独立头解析器功能网表也不代表整个 GUI 实现或布线后时序仿真。

## 当前 GUI 物理证据

检查文件为 `media/MultimediaSystem_media_Runs/phy_1/route.qor` 与 `final_timing.rpt`，生成时间 2026-10-24 22:26。

| 项目 | 结果 |
|---|---:|
| Slice | 9643 / 9800（98.40%） |
| Setup WNS / TNS | −3.390 ns / −1654.031 ns |
| Setup 违例端点 | 1793 |
| Hold WNS / TNS | −0.068 ns / −0.201 ns |
| Hold 违例端点 | 16 |

除最差 FAT I/O 超时判断路径外，报告直接列出：

- `fat32_ro/control_state[2] → walk_cluster[11].ce`：−3.355 ns；`walk_cluster[15].ce` 同样 −3.355 ns。
- `walk_cluster[19].ce`：−3.220 ns；`walk_cluster[10].ce`：−3.082 ns。
- `fat_bmp_controller/cat_addr[1].ce`：−3.126 ns。
- 浏览器元数据 RAM 写数据存在 −0.020 ns Hold 违例。

这些都是文件簇号、图片目录地址或元数据相关路径，存在实板采样错误的可能性，且与“格式正确、仿真通过、实板读其他文件失败”的现象相容。该关联是排查方向，**不是已捕获的错误读地址证据**。`media/MultimediaSystem_media_Runs/best_result/MultimediaSystem_media.bit` 与 `phy_1` bit 逐字节 SHA256 相同：`E860EBD0DCB6E234EF80A7C5DADFE6998F9730CD3E011E3ED8C13F051AA8DF05`。用户随后确认故障时烧录的就是 media `best_result` bit，因此本地现存候选与上述 GUI 报告已对应；尚未读取设备配置进行独立核验，也未核验全部综合输入指纹。

## 剩余定位点

需要板上捕获失败时的 `{文件起始簇, 文件大小, 请求 SD LBA, 返回头字节, hdr_ok, geometry_ok, fat_error_code}`，或用同一张卡对比已确认可用 bit 与当前 bit。这样才能区分簇号/元数据采样错误、SD 返回数据异常和校验计算异常。现有两条屏幕提示不足以进一步区分，不应通过删除配音功能、放宽 BMP 校验或修改素材来宣称问题已修复。

## 用户要求的换种子试板包

用户随后要求重新生成不同种子的 bit 作实板对比。本轮冻结并复用故障版本的 GUI 综合数据库，没有重新综合或修改 RTL。seed=11 和 seed=3 的原配置布线均因持续不收敛而主动停止；单独关闭 `post_route_opt` 的重复尝试也未避开同一耗时阶段，已停止。以上未完成尝试不记作通过。

最终在同一份 seed=3 放置结果上采用 `route priority congestion`、`route timing off`、`route post_route_opt off`，于 **2026-10-24 23:44** 完成全路由和 bitgen。`route timing off` 只关闭路由器的时序驱动搜索；原时钟约束、最终 STA 和 Hold 修复配置仍保留。最终报告覆盖率 99.96%，bus_clk 仍为 100 MHz、两路链路时钟仍为 125 MHz。该版本还改变了路由策略，因此不是只改变一个种子的严格单变量试验。

| 项目 | 原 best_result | 新试板 bit |
|---|---:|---:|
| Slice | 9643 / 9800 | 9681 / 9800 |
| Setup WNS / TNS | −3.390 / −1654.031 ns | −6.288 / −3492.854 ns |
| Setup 违例端点 | 1793 | 2722 |
| Hold WNS / TNS | −0.068 / −0.201 ns | −0.020 / −0.126 ns |
| Hold 违例端点 | 16 | 12 |
| BRAM9K+FIFO9K / BRAM32K / DSP | 58 / 1 / 28 | 58 / 1 / 28 |

**新版本 Setup 比原版更差，仍有 Hold 违例，仅用于用户要求的功能对照，不作为修复成功或正式签核的证据。** 正式签核脚本和门槛均未修改。71 项 RTL/IP/约束/构建脚本的本轮快照复核一致；原 best_result bit 哈希保持不变。

- 新 bit：[media_IMAGE_SWITCH_SEED3_CONGESTION_TRIAL.bit](../../build/image-switch-seed3-congestion-trial-20261024/media_IMAGE_SWITCH_SEED3_CONGESTION_TRIAL.bit)，640106 字节，SHA256 `0ed03fd8f91435118cb1d2289e1d7b3154fb6d7be8109c488a353adb5dab5761`。
- [试板包 ZIP](../../build/image-switch-seed3-congestion-trial-20261024.zip) 含新 bit、原 bit 备份、最终资源/时序报告、日志和构建配置。ZIP CRC 与打包后 bit 哈希复核通过。
- 只更新 media，render 沿用故障时版本，用原 SD 卡验证下一张和浏览器选图；实板结果待用户反馈。
- 完整输出：`media/Runs/phy_image_switch_seed3_congestion_20261024/`；冻结综合网表：`media/Runs/syn_image_switch_seed11_20261024/`。
