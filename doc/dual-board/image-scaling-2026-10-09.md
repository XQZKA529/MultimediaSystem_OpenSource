# BMP 自动缩放（2026-10-09）

media 接受宽、高各 1–4096 的 24bpp、BI_RGB、自下而上 BMP；加载时自动等比例缩放到 1280×720，居中补黑。JPG/PNG、负高度 BMP 和压缩 BMP 仍需转换格式。原单板基线与 PC 预处理脚本未改动。

## 显示规则

几何与 `tools/convert_fpga_bmp.py` 的 contain 模式一致：限制较先达到边界的方向，另一方向取最近整数，恰好半数时取偶数，最小为 1。左、上边距向下取整，奇数余量位于右、下。例如 640×480→960×720、720×1280→405×720、1365×767→1280×719。

首版采样为最近邻，屏幕坐标使用 `floor((2*d+1)*S/(2*D))`。它与脚本的 Lanczos 插值画质不同。底向上行号使用 `floor(((2*d+1)*H-1)/(2*DH))`，保证翻转后上下取样与奇数补边位置正确。

补边写入 RGB=0，仍参与现有交叉淡化及整帧对比度处理：100% 对比度时为黑边，降低对比度后可以变灰。OSD、设置菜单和全局亮度规则沿用当前系统。

## 模块与扩展契约

板内 `rtl/image/` 分为 `bmp_header_parser`、`bmp_pixel_unpack`、`image_scale_geometry`、`image_scale_nearest`、`image_row_store`、`bmp_image_pipeline`。控制器只协调目录、探测、加载、提交、重试和重放，不再在自身 FSM 中进行逐字节像素处理。

- 头解析器使用有界 512 字节探测，读取前 54 字节并校验签名、DIB/planes/bpp/compression/尺寸。偏移与 payload 使用33位累加防溢出（13位尺寸的行数据乘积用28位计算），有效性仍校验完整32位输入，验证 DIB 不与像素重叠、文件长度足够，接受扩展头和尾随数据。
- 解包器跳过头部和每行 `(width*3+3)&~3` 的填充，提供 RGB888 ready/valid 流；最后像素被消费后才完成解包。
- 几何模块的 `start` 启动计算，输入几何须保持到 `done`；控制器在探测启动时锁存 `scale_mode`。目前 mode=CONTAIN(0) 可用；COVER(1)/STRETCH(2) 及其他值均返回 `ok=0`，在 IMG_BEGIN 前拒绝，不静默回退。不新增菜单。
- 缩放器接底向上 RGB 流及稳定的帧几何，提供 `out_valid/out_rgb/out_ready`；暂停时保持像素和坐标，输入、输出只在握手时推进。采样算法独立于文件系统和网络，后续可替换插值实现。
- 几何计算使用启动时串行除法，像素路径使用余数递推。配置乘积最大29位，串行除法的余数最大14位；舍入比较、加一和最小尺寸选择分别寄存，避免形成长组合路径。在几何、头解析和行缓存/采样模块中，由启动流程初始化的数据寄存器省去重复复位，复位有效性与控制状态仍保留，减少无效复位扇出。目标宽度需为 4 的倍数；生产尺寸固定为 1280×720，测试可覆盖较小尺寸。

## 缓存、反压与提交

缓存仅有一条缩放并补边后的目标行：1280 RGB888 像素紧密打包为 960×32 位，综合为四块 BRAM9K。输入 FIFO 为 1024×8 位，占一块 BRAM9K。没有整图缓存，也不随原图尺寸分配行缓存。

`fat32_ro.FILE_MAX_BURST` 默认 4，经 `storage_service/glue_storage` 传递；media 图片链设为 1。空间许可经一级寄存：比较上一拍空闲≥529字节，保证下游使用许可时仍有至少528字节。每次启动 SD 突发须有至少 528 字节输入空间，突发内不暂停。网络独立提供 `image_pixel_ready`，发送 FIFO 至少空出 16 字时允许缩放像素交付；原 `image_burst_ready` 保留兼容。WAV 的独立读取链不变。

`load_success` 必须等待文件成功、解包完成、全部目标像素交付、输入 FIFO 排空及末尾打包字排出；完成判定检查经过一拍寄存的网络接收许可，隔离网络占用量与事务 FSM 的组合路径。四拍排空等待已覆盖末尾字交付，末尾像素之后发生会话取消仍不会误报成功。文件完成本身不能触发成功。网络 END 继续等待全部 691200 字发送、CRC 收尾及发送 FIFO 排空；render 继续校验整图 CRC、真实写完成和帧界过渡后回复 PRESENTED。线格式、协议版本和渲染 RTL 不因缩放变化。

文件错误、截断、溢出、打包错误或超时发 `load_failed`，取消远端事务、复位本地流水线和打包器，执行有界重试；失败保留已显示图片。重连重放重新探测、重新计算几何。加载看门狗计入原始输入消费和缩放输出进展，保留 15 秒加载上限。进入提交时重新开始计时，给予独立的 3 秒提交超时，即使加载已接近 15 秒也不挤占提交预算。

## 验证入口

```powershell
./media/sim/run.ps1 -Test tb_bmp_header
./media/sim/run.ps1 -Test tb_bmp_controller
./media/sim/run.ps1 -Test tb_bmp_overflow
./media/sim/run.ps1 -Test tb_bmp_scale -ScaleFull
./tools/dual-board/run-system.ps1 -ScaleBmp
./tools/dual-board/run-system.ps1 -ScaleFull
./tools/dual-board/run-system.ps1 -Test tb_audio_system -ScaleBmp
./tools/dual-board/run-system.ps1 -Test tb_audio_system -ScaleFull
./tools/dual-board/run-regression.ps1
./media/build/run.ps1 -Stage all -RunTag bmp_scale_release -PlaceSeed 4 -PhysicalEffort medium -RouteEffort normal
./render/build/run.ps1 -Stage all -RunTag bmp_scale_release -PlaceSeed 4 -PhysicalEffort medium
```

独立 Python oracle 位于 `media/sim/bmp_scale_reference.py`，不依赖 Pillow；17 组输入包括 720p/480p/1080p/4K/方图/竖图/奇数/4096×4096/极窄极扁/单像素及四类行填充。`-ScaleFull` 比较每张图片全部 921600 像素，默认目标 32×18 加快输出验证；`-ScaleCase N` 只运行单组，N=0..16。最大源图仍完整读取，运行时间较长。

联合测试默认目标32×18便于快速回归，`-ScaleFull` 使用生产1280×720及691200打包字；并行WAV使用加速PCM消费速率，但保留链路空闲时隙，避免测试模型的人为加速挤占全部图片带宽。联合测试采用真实 BMP 控制器、解析器、缩放器、打包器及双方可靠链路，逐字比较 Python 生成的缩放帧，检查 CRC/写完成/PRESENTED 屏障；文件服务、MAC 和 SDRAM 时序为仿真模型。音频联合测试在相同路径并行运行真实 WAV/PCM 链。

当前工具签核与日志见 `evidence/bmp-scale-qualification.json`、media `build/evidence/` 和两板 `Runs/phy_bmp_scale_release/`。资源与时序门槛保持 BRAM9K≤56、Setup WNS≥0.100ns、Setup/Hold 零违例且输入指纹一致。实板烧录、实际大图加载耗时和 30 分钟混合尺寸轮播尚待用户操作记录，不能以仿真或 bit 生成替代。

## 本次验收结果

17 组生产尺寸输出的独立整数模型逐像素检查通过，共 15,667,200 个像素；注册输入空间许可后再次通过最大 4096×4096 源图的突发/反压测试。BMP 格式与长度边界、末尾阻塞/取消、失败重试、重连重新探测、旧图保留及接近加载期限时的独立提交计时均通过。临时仿真副本重新共用加载/提交期限时，该提交回归按预期检出失败。

真实 BMP 路径的双板联合测试检查全部 691200 个打包字、CRC、实际写完成与 PRESENTED；完整 720p 并行 WAV 也通过，图片加载期间 PCM 位置由 3000 推进至 301551，并验证实际样本、暂停恢复、快进钳位与尾部拒绝。菜单、Text OSD、切图、交叉淡化、并行音频及原单板基线审计通过。最后的提交计时拆分另以事务、近期限及 BMP/网络/WAV 快速回归验证；它不改变像素数据或网络格式。

| 板端 | BRAM9K | DSP | Slice | Setup WNS | Hold WNS | Setup/Hold TNS |
|---|---:|---:|---:|---:|---:|---:|
| media | 56 | 7 | 85.49% | 0.100 ns | 0.003 ns | 0 / 0 |
| render | 53 | 13 | 85.09% | 0.109 ns | 0.003 ns | 0 / 0 |

两板通过布线后报告与当前源码指纹检查。Slice 超过既有 80% 提示线的情况按原规则记录；BRAM 和时序硬门槛未改变。media 使用 seed=4、medium、normal 路由，render 使用 seed=4、medium、routability 路由。此前未达标/工具失败报告与测试模型的尾部快进预期修正均保留在验收记录中。

成对交付文件位于根目录 `build/bmp-scale-release/`，各板包含 bit、qualification、inputs、最终 QoR 和时序报告；根目录 `manifest.json` 记录两板 SHA-256 与构建参数。实板项目仍标为待验收。


## 实板回归与取消修复

`bmp_scale_release` 实板首张720p报ERROR 5，目录仍可读，原配对不再推荐。新增流水线已修正组合cancel直接驱动异步rst的缺陷；故障注入旧代码复现ERROR 5，新代码通过。完整差异、负对照及修复构建见 [ERROR 5修复记录](image-scaling-repair-2026-10-09.md)。异步复位只接系统rst，事务取消在所有阶段同步消费。实板恢复仍待确认。
