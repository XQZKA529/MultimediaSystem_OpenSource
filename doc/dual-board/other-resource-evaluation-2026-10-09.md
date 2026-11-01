# BRAM 之外的器件资源核对

日期：2026-10-09。板卡为康芯HX4S20，FPGA为EG4S20BG256；[安路教育板卡目录](https://www.anlogic.com/support/university/apply/teaching-board)与本地板卡手册一致。器件能力以[安路DS303_1.3器件概览，2026.01](https://anlogic.oss-cn-shanghai.aliyuncs.com/web_doc/%E5%B7%A5%E5%85%B7%E4%B8%8E%E8%B5%84%E6%96%99%E4%B8%8B%E8%BD%BD/%E6%8A%80%E6%9C%AF%E6%96%87%E6%A1%A3/EG4/%E5%99%A8%E4%BB%B6%E6%A6%82%E8%A7%88/DS303_Eagle_FamilyOverview.pdf)为准，不能混用其他EG4封装或其他开发板的外设。使用量沿用media实板确认GUI产物及render抗锯齿CLI签核产物；本次没有修改RTL或生成bit。

## 能帮助降低逻辑占用的资源

| 资源 | 每板能力 | media当前使用 | render当前使用 | 判断 |
|---|---|---:|---:|---|
| 硬乘法器，TD记为DSP | 29个18×18，支持9×9模式 | 7，剩22 | 13，剩16 | BRAM以外最值得评估的独立运算资源 |
| 专用FIFO控制 | 器件支持，TD提供FIFO8K原语 | `#fifo9k=0` | `#fifo9k=0` | 可评估替代软FIFO的指针/满空控制；仍占相应BRAM资源 |
| 分布式RAM | 标称156800 bit，约19.14 KiB | 时钟域表LUT As Dram为0 | 时钟域表存在LUT As Dram | 与LUT/Slice共享资源，可提高小存储密度，不是独立空闲RAM池 |
| 合封SDR SDRAM | 2M×32 bit = 8 MiB | 当前未启用SDRAM控制器 | 用于图片双帧缓存 | media可用于大缓存，但需新增控制器；容量利用不等于省Slice |

乘法器原语可参考TD安装目录 `template/verilog/Device-Primitive/EG4/Arithmetic/eg4_arithmetic.v` 的 `EG_PHY_MULT18`、`EG_LOGIC_MULT`。物理乘法器具有输入/输出寄存器配置；在时钟、使能、复位及延迟兼容时，也可评估将外围流水寄存器吸收进硬块。它不是通用的加减/除法/FSM加速器，不能把任意逻辑直接搬进去。

现有设计已经使用DSP：media缩放几何、BMP头校验和FAT计算；render频谱、音频模型、对比度、像素混合及亮度。应先核查综合网表中尚由逻辑实现的乘法及常数除法，再做局部A/B综合。Text OSD的字符定位 `/12`、`%12` 等可评估精确乘倒数加移位，必须证明整个输入范围的整数结果等价，并对齐像素流水线；不能为增加DSP使用率而替换本来已很便宜的移位/加法。

专用FIFO可参考 `template/verilog/Device-Primitive/EG4/RAM,ROM/eg4_ram_rom.v` 的 `EG_LOGIC_FIFO`，模板使用 `MODE="FIFO8K"`。两板目前均没有映射为FIFO9K，但大量FIFO的存储已经是BRAM。优先比较PCM环和较深图片FIFO的完整存储加控制面积，核对深度、位宽、满空标志、show-ahead/同步读、跨域复位和水位信用。模板中的 `EG_LOGIC_RAMFIFO` 是另一类原语，不能仅凭名字认定也采用专用硬控制；最终以映射网表及面积为准。使用硬FIFO与迁移BRAM32K应作为不同实现比较，不能把两种收益直接相加。

分布式RAM可参考 `EG_LOGIC_DRAM` / `EG_LOGIC_DRAM16X4`。小表、浅FIFO可由寄存器阵列改为LUTRAM，可能减少寄存器及选择逻辑；但会占用可配置逻辑，读口/复位等限制也需适配。大文本及快照仍优先BRAM32K，避免继续挤占Slice。

render当前 `VBP_BUF0_ADDR=0`、`VBP_BUF1_ADDR=691200`，两帧各691200个32位字，合计5529600字节。按现有两帧布局，8 MiB中理论还有2859008字节（约2.73 MiB）未用于帧缓存，未计未来保留区；必须单独核查视频双路读、写图和刷新后的带宽。media使用自己的8 MiB需新增本板SDRAM控制器，两板内存不能直接共享。小文本及低延迟CDC不适合仅为容量充足而迁入SDRAM。

## 其他有余量但不能直接解决Slice瓶颈的资源

| 资源 | 每板能力 | media / render报告占用 | 用途 |
|---|---|---|---|
| PLL | 4 | 1 / 2，剩3 / 2 | 新增时钟、相位或频率；本身不提供逻辑计算空间 |
| 全局时钟GCLK | 16 | `#gclk=2 / 3` | 改善时钟分发；可用性还受入口及布线限制 |
| 普通寄存器 | 19600 | 10308 / 11730 | 仍有余量，但与LUT打包在Slice内，不能当独立Slice池 |
| ADC | 1个SAR ADC，8路模拟输入，概览标称1 MSPS | 生产RTL未例化 | 新增模拟采样，对现有数字逻辑降占用无直接收益 |
| IO/DDR/LVDS | BG256概览列193用户IO、42对真LVDS及44对模拟LVDS | 已用于RGMII和HDMI；其他接口依板上连接 | 扩展接口；I/O内寄存器有助边界打包，但不能容纳内部大段逻辑 |
| 内部振荡器、BSCAN、DNA | 器件提供 | 当前主数据通路未利用 | 配置、识别、调试或特定时钟用途 |

ADC不沿用旧宣传页的精度承诺：当前DS303已删除ADC精度说明，实际采样指标需另查当前ADC资料。器件概览未列CPU或硬核HDMI/MAC；本项目HDMI/TEMAC实例确实占用LUT和寄存器，不能把厂商IP当作隐藏的独立硬核资源。

板载Flash、UART、VGA、HDMI输入、蜂鸣器及扩展IO主要服务新功能或调试。Flash手册文字同时写“64M-bit”和“W25Q16”，标注不一致，本次不认定具体容量，按实物丝印/JEDEC再确认。配置Flash不是可替代片内并行逻辑的计算资源。

## 工程建议与核查入口

在已规划的Text OSD BRAM重构之外，优先做 **软算术到硬乘法器的映射审计** 与 **软FIFO/专用FIFO的局部面积比较**。两项当前均未完成候选实现或签核，不给出Slice节省承诺。PLL、ADC、IO及SDRAM的空闲量主要说明后续功能扩展空间。

报告入口：

- `media/MultimediaSystem_media_Runs/phy_1/MultimediaSystem_media_phy.area`：DSP7、PLL1、GCLK2、FIFO9K0。
- `build/aa-font-bram32-2026-10-09/render/MultimediaSystem_render_phy.area`：DSP13、PLL2、GCLK3、FIFO9K0。
- `render/rtl/pkg/video_bmp_params.vh`：双帧地址与长度。
- `doc/reference/board-support/wan_manual_dump.txt`：HX4S20板卡摘录，仅作板级连接参考，旧资源数字与型号冲突以当前器件资料/实物为准。

[BRAM优化评估](bram-optimization-evaluation-2026-10-09.md) · [根README](../../README.md)。
