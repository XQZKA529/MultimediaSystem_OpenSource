# 两板 Slice 优化实施与筛选

**版本更新：7204 Slice产物已因实板黑屏撤回；当前推荐为7395 Slice实板恢复版，用户确认切图、菜单、文字和音频正常，见[调查与恢复记录](black-screen-investigation-2026-10-09.md)。下表保留原始优化测量历史。**


2026-10-09。按“保持功能、720p、音频吞吐与时序门槛，逐项测量再决定是否保留”的计划实施。**最终保留 render 的 Text OSD BRAM 重构；DSP、专用 FIFO 和仅迁移缓存的候选未进入发布版本。media 数据通路已恢复原实现。**

## 签核版本占用对比

| 指标 | media 基线 / 最终 | render 字库升级后基线 | render 最终 |
|---|---:|---:|---:|
| Slice | 8411 / 8411 | 8441 | 7204 |
| Slice 占比 | 85.83% / 85.83% | 86.13% | 73.51% |
| 可用 Slice | 1389 / 1389 | 1359 | 2596 |
| LUT | 15186 / 15186 | 14427 | 12490 |
| Slice 寄存器 | 10308 / 10308 | 11730 | 9544 |
| BRAM9K / BRAM32K / FIFO9K | 56 / 0 / 0 | 51 / 2 / 0 | 51 / 4 / 0 |
| 总 RAM 块数 | 56 | 53 | 55 |
| DSP / PLL | 7 / 1 | 13 / 2 | 13 / 2 |
| Setup WNS | +0.122ns / +0.122ns | +0.121ns | +0.104ns |
| Hold WNS | +0.003ns / +0.003ns | +0.003ns | +0.003ns |
| Setup / Hold TNS | 0 / 0 | 0 / 0 | 0 / 0 |

最终 render 相对已签核字库版本少占 **1237 Slice、1937 LUT、2186 个寄存器**，Slice 数减少14.66%，占比下降12.62个百分点。media 本轮没有保留可证明合格的 Slice 降幅。

这是两版签核产物的占用差值。两板使用相同 TD 6.2.168116、area_prior、高物理优化、routability、集成保持时间修复和既有门槛；media 保持 seed=3，render 发布种子由4改为5。seed=4 的 Text OSD 初版实际降到7124 Slice，但 Setup 只有+0.017ns，禁止生成bit；后续 seed=4 和旧源码 seed=5 遇到复位网增量布线冲突。**因此不把1237声明为同种子、排除布局影响的单模块收益。**所有失败结果都留在证据中，未放宽时序或RAM预算。

## 保留的 Text OSD 实现

- `text_osd_controller` 使用一块 BRAM32K 保存编辑内容；每字符占一个16-bit字的低8位。只在追加时写RAM，删除、清空与复位调整长度，超出长度的同步读返回NUL。
- `text_osd_view_cdc` 使用另一块 BRAM32K，划分为两个128字的前后台区域。串行复制107字，首字预读后每拍复制一字；32-bit编辑版本变化时丢弃并重试。
- 869-bit文本模型接口改为13-bit `{enable,focus,length}`、版本号及同步字节读口，删除整段文本/快照寄存器及宽动态字节选择。
- 完成复制后才发送请求；视频域只在VS提交前台bank与元数据。四阶段请求/应答结束前不复用后台bank，独立复位会重新发布最新内容。
- 绘制阶段A提供RAM地址，B得到同步字节，C选字符，D读字库；总延迟保持四个像素时钟，RGB/HS/VS/DE、106字符容量、菜单、退出保留与抗锯齿字形保持原行为。

对应源码：[控制器](../../render/rtl/ui/text_osd_controller.v)、[快照CDC](../../render/rtl/ui/text_osd_view_cdc.v)、[RAM原语封装](../../render/rtl/ui/text_osd_ram.v)、[绘制](../../render/rtl/ui/text_osd_overlay.v)。当前render物理剩余13块9K、12块32K；按总RAM≤56的现有项目预算只剩1块新增余量。

## 已测量但撤回的候选

| 候选 | 实测结果 | 决定 |
|---|---|---|
| 亮度 /10、对比度 /10 使用带输出寄存器的DSP | 独立综合各少48、41 LUT，各加3 DSP；整板与Text BRAM组合，seed4为7231 Slice、Setup +0.101ns、Hold +0.004ns，但seed5增量布线失败 | 不为独立LUT收益额外消耗6 DSP；选择占用更低且已签核的Text BRAM版本 |
| Text OSD /12 与余数使用DSP | 独立综合13→2 LUT，增加1 DSP；组合整板seed5为7311 Slice，视频坐标→DSP→列寄存器路径Setup −0.153ns | 撤回，保留原除法及像素流水线 |
| media 图片 / PCM 专用FIFO | 两个队列总计6 FIFO9K，仍占原9K池；单队列独立综合66→53 LUT、24→13 fabric FF。seed3整板8273 Slice，但Setup −0.205ns；seed5候选8395 Slice、Setup +0.102ns，同seed旧实现8347 Slice（旧实现该seed时序亦未通过） | 无同时满足“同配置降低Slice且通过时序”的结果，恢复原FIFO |
| media BRAM32K + 单占用计数器软FIFO | 独立综合102 LUT、33 fabric FF、2 BRAM32K，高于原66 LUT、24 FF | 综合筛选即停止，不宣称功能或整板收益 |
| render PCM环迁移32K | 精确水位与跨域指针保留，复位输出掩码计入成本；独立综合123→156 LUT、94→95 fabric FF，8 BRAM9K→2 BRAM32K | 释放RAM不等于降低Slice，未保留 |
| render PCM硬FIFO | 保留精确水位、双域影子指针及复位数据语义后，独立综合158 LUT、95 fabric FF、8 FIFO9K | 比原实现更大，未保留 |

独立综合的fabric FF不包含被吸收到IO的寄存器，不能用它直接换算整板Slice。读图/写图FIFO同样依赖精确usedw、跨域指针与show-ahead；没有确认能删除这些控制器的原语接口，保持现有实现。media FAT/BMP主要乘法已使用DSP或串行除法，未为利用空闲DSP改动文件系统/解析架构。SDRAM、ADC、PLL等不属于此次已验证的Slice替代方案。

media检查脚本已修正：分别读取BRAM9K、BRAM32K、FIFO9K，校验其和等于QoR总RAM数；总RAM≤56、Setup≥0.100ns、零Setup/Hold违例等门槛保持不变。

## 验证与交付

最终源码通过：120条焦点导航边、字母/空格、106字符容量、NUL、DEL/CLR、禁用编辑；异步CDC的复制中编辑、VS原子切换、尾部屏蔽、生产/视频独立复位和版本回绕；5,051,452次Text OSD像素检查与四拍同步；92,160次文字合成链和76,800次图像/菜单/诊断/音频合成链检查；真实双板菜单链路、退出/重入保留；原单板基线哈希与本地依赖审计。

FIFO候选额外使用厂商物理模型测试512/1024深度、满空、包括预取的精确占用、随机反压、溢出、清空、短异步复位脉冲与持续吞吐；DSP候选用物理模型穷举4096个/10输入、2048个/12商/余数和RGB全部等级。网络候选通过691200个720p RGB888数据字、288个UI字符、重连重发和音频/图片并行联合回归。这些用于筛选候选，**不把候选日志当成被撤回RTL的最终签核**。

两板最终资源/时序/输入指纹检查均通过，render已重新核对映射字库全部65536 bit INIT。当前源码与发布bit的输入清单一致；实板烧录已由用户执行并报告黑屏，功能验收失败；显示观感和30分钟混合轮播未通过。

- 已撤回推荐的[render 故障 bit](../../build/slice-optimization-2026-10-09/release/render/MultimediaSystem_render.bit)，已报告实板黑屏；恢复时使用用户确认正常的字库版本。
- [media同源复建bit](../../build/slice-optimization-2026-10-09/release/media/MultimediaSystem_media.bit)用于构建签核留档，数据通路未变化；本次不要求重新烧录media。
- [两板签核包](../../build/slice-optimization-2026-10-09/slice-optimization-release.zip)包括bit、最终/综合报告、设置、输入指纹、源码和校验清单。
- [实验与最终证据](evidence/slice-optimization-2026-10-09.json)及[发布校验清单](../../build/slice-optimization-2026-10-09/release/manifest.json)。失败/候选原始日志和源码留在`build/slice-optimization-2026-10-09/`及两板`Runs/`。

复建推荐版本（PowerShell，TD_ROOT可配置）：

```powershell
./media/build/run.ps1 -Stage all -RunTag slice_release -PhysicalEffort high -PlaceSeed 3
./render/build/run.ps1 -Stage all -RunTag slice_release -PhysicalEffort high -PlaceSeed 5
./render/sim/run.ps1 -Test tb_text_osd_cdc
./render/sim/run.ps1 -Test tb_text_osd_overlay
./tools/dual-board/run-system.ps1 -Test tb_text_osd_menu
python tools/dual-board/audit.py
```

发布render SHA256：`95f9fa79174b1f24d838dc68d3438b979b872fce2e1163ff4783c1ac4954f0d1`。
media复建 SHA256：`35920fb58e35ee33196e835b67098e5dfe7c06e974d42f874c5026bbca434f0a`。
