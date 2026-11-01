# FAT32 挂载运算分步化实验（第五轮，2026-10-12）

**两种候选均未保留。** 挂载阶段的分步运算功能验证通过，受测读取链的吞吐保持一致，但整板 Slice 更高。生产版本继续为 media **9197 Slice（93.85%）**、render **8415 Slice（85.87%）**；本轮只尝试 media 的 FAT32 挂载运算，render 未改动。

## 实际改动范围

仅修改隔离候选中的 `media/rtl/fat/fat32_ro.v`，选择挂载地址准备里 `fat_sectors × num_fats + reserved_sectors` 的加法分步计算。原乘法保留，乘积直接存入已有的 `data_start_offset`，移除 32 位中间 `fat_area_sectors`。复用该结果寄存器，通过旋转和进位完成加法，不新增大块工作缓存。

- 8 位版使用四次 9 位带进位加法，挂载比原版多 3 拍。
- 16 位版使用两次 17 位带进位加法，挂载比原版多 1 拍。

结果保留原 32 位模运算语义，包括原乘法/加法的高位截断，不改变 FAT32 格式检查或错误码。目录、文件、映射的簇地址准备、块请求、逐字节读出、缓冲及实时图像/音频数据阶段保持原实现。挂载的内部工作数在中间拍不同，仅在结果完整、既有隔离拍结束后交给后续范围检查。

两板完整生产构建输入哈希与当前合格网表逐项匹配；每个候选相对 media 基线的完整输入指纹只改变 `rtl/fat/fat32_ro.v`。

## 整板测量

与 media 合格基线采用相同 area_prior、medium、seed 3、placement relaxation 0.85、原生 hold 修复及原约束。验收仍要求 Setup ≥ +0.100 ns、Hold ≥ 0、两个 TNS 和违例数为零，且最终 Slice 低于 9197。

| 候选 | 综合 LUT / FF 变化 | 最终 Slice | Setup / Hold ns | 挂载额外延迟 | 处理 |
|---|---:|---:|---|---|---|
| 8 位 / 四拍 | +51 / -29 | 9310 | -0.152 / +0.022 | 3 拍 | 面积更高、时序失败 |
| 16 位 / 两拍 | +25 / -30 | 9337 | +0.107 / +0.022 | 1 拍 | 时序通过，面积更高 |

BRAM 保持 56 BRAM9K + 1 BRAM32K，DSP 保持 7。四拍版 Setup TNS −0.152 ns、一个 Setup 违例；两拍版两个 TNS 和违例数均为零，但比基线多 140 Slice，不能保留。

原宽加法器缩小并不保证整板更省：分步结果与乘积共用寄存器增加了数据选择、旋转和阶段控制，且整板布局/布线会随输入改变。本轮只验证了这一小段挂载算术，尚未验证其他更大的 FAT32 架构改写。

## 读取速度验证

### FAT 功能与逐周期事件

两种版本各完成 `tb_fat32_ro`（多扇区及单扇区）、`tb_fat32_map`、`tb_fat32_directory`、`tb_fat32_timeout` 五项原生 ModelSim 回归。与冻结原版分别运行相同刺激，比较以每次挂载完成为零点的全部后续事件内容和时钟：块请求 LBA/长度、每个文件字节、文件完成、目录字符/元数据/完成、映射段及完成均一致。超时用例单独通过其原有断言，未把零事件的空轨迹当作吞吐证明。

普通 FAT 用例分别比较 35182 / 35230 个事件，其中多扇区用例包含 35066 个文件字节、36 次块请求；覆盖碎片化跨簇、所有合法簇尺寸、目录重扫、映射连续段合并、循环链、表容量溢出、取消和 IO 超时。

目录原测试用绝对仿真时钟 `%5` 生成 SD 停顿。挂载后移 3 拍会改变该外部停顿相位，原测试功能仍通过，但重扫轨迹有一个时钟的相位差。公平的吞吐对照在两份临时测试副本中都把该刺激计数器在挂载完成时归零；测试 DUT 不修改，此时全部 815 个目录事件的内容与时间戳一致。原未对齐日志也保存在归档中，没有隐去差异。

两种算术各通过 10197 组直接阶段测试，包含随机 32 位 FAT 大小、8 位 FAT 份数、16 位保留扇区数、各级进位及乘积/加法回绕；它们验证计算阶段，并不表示非法参数会通过完整挂载检查。

同一 FAT 块模型中，原有效挂载为 1049 拍，四拍版 1052 拍、两拍版 1050 拍；100 MHz 下只分别多 30 ns / 10 ns。挂载之前失败的参数检查不增加这段延迟。

### 实际 media_core 完整 720p 加载

四拍版与原版各执行真实 `media_core` 的 FAT、BMP 解析、缩放、打包和 seam 图像事务，SD 卡由行为模型供数。完整用例比较 **691200 个输出字** 与独立图像预期，经过 **42 次跨簇读取**，并验证 EOF、IMG_END、IMG_PRESENTED 和最终显示有效状态。

| 事件（100 MHz 时钟序号） | 原版 | 四拍版 | 差值 |
|---|---:|---:|---:|
| 挂载完成 | 545 | 548 | +3 |
| IMG_READY | 1947 | 1950 | +3 |
| 首输出字 | 13666 | 13669 | +3 |
| 末输出字 | 11293895 | 11293898 | +3 |
| IMG_END | 11293912 | 11293915 | +3 |

所有上述事件只整体后移 3 拍；IMG_READY 到首字、末字、IMG_END 的间隔完全一致。测试模型中的 IMG_READY→IMG_END 为 **112.919650 ms**，候选相同。没有降低分辨率、吞吐或缓冲容量，没有修改显示扫描链。

两拍版还通过真实 media_core 的启动/首 512 字及 SD 失败 STATUS 用例：挂载、IMG_READY、首字、末字分别从 545/1947/13666/15880 拍后移到 546/1948/13667/15881 拍，均只多 1 拍。其文件读取吞吐由上述 FAT 逐周期回归覆盖；本轮没有额外重跑两拍版完整 720p 用例。

这些是行为 SD 模型和 RTL 仿真证据，不是实卡测速或实板验收。未重跑全套双板系统回归；生产 RTL 没有保留本轮改动，推荐烧录包仍为第三轮合格版本。

## 证据与复现

[机器证据](evidence/slice-optimization-round5-2026-10-12.json) 包含基线与候选完整输入哈希、资源/时序、逐次挂载延迟及加载指标。[实验归档](../../build/slice-round5/experiments.zip) 包含两套候选输入、生成/验证脚本、读取事件轨迹和原始报告，逐项 SHA256 已读取校验；压缩包 SHA256：`5ff43281fb28a5570a25672b027e89893ed19960affee50ece5b690729b48fb0`。

```powershell
python build/slice-round5/check_fat.py --trial mounthalfword
python build/slice-round5/check_arithmetic.py --trial mounthalfword
python build/slice-round5/check_boot.py --trial mountbyte --full
pwsh -NoProfile -File build/slice-round5/mountbyte/media/build/run.ps1 -Stage syn -RunTag fresh_mountbyte
pwsh -NoProfile -File tools/dual-board/run-area-physical.ps1 -Board media -BoardRoot build/slice-round5/mountbyte/media -SynthesisRunTag fresh_mountbyte -RunTag fresh_mountbyte_seed3 -PlaceSeed 3
```

构建需新标签；算术和启动验证脚本的证据目录也需未存在。读取回归可在已完成、输入未改的证据目录继续未完成项。重现前先核对输入哈希，避免把旧日志用于修改后的候选。
