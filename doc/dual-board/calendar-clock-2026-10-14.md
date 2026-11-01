# 日期时钟（协议 1.9，2026-10-14）

本功能在 GPIO/C 组合应急版本上增加日期时钟。需要配套更新两板；日期和编辑草稿由 render 持有，media 只管理设置入口与页面生命周期。

当前使用接收时序修改配对 `clock_rxfix_v1_high8` render / `clock_v1_medium3` media。用户已确认当前版本可行，首次 CLOCK_TRIAL 的图片 ERROR 5 问题已恢复；最新下载和资源见 README，修改及实板状态见 [接收时序恢复记录](clock-rx-timing-fix-2026-10-14.md)。当前属于实板功能已确认、长期验收待完成的试板版本，尚未正式时序签核。

## 使用

- 上电或 render 系统复位显示 `2000-01-01 00:00:00`，支持 2000–2099 年；2099 年末回到 2000 年初。没有电池 RTC 或掉电保存。
- 设置主页新增第七项 CLOCK。矩阵 2/8 或板载 KEY2 选择，矩阵 5 或板载 KEY4 进入。
- 编辑页依次是 YEAR、MONTH、DAY、HOUR、MINUTE、SECOND、APPLY。矩阵 2/8 循环选择字段，4/6 调整数值，沿用 500 ms 后每 150 ms 连发。数值上下限循环；年月改变后日期超限时钳位到当月最后一天。
- 在 APPLY 上按 5 才生效，完整日期时间同时应用，并清零不足一秒的计数。确认后留在编辑页。其他字段上的 5 不应用。
- # 或 KEY2 双击返回，KEY3 关闭；未应用的修改丢弃。编辑页内板载 KEY2 单击、KEY4 不修改数值。
- 进入页的按键不会转为编辑事件；收到页面和编辑快照的视频呈现确认后才接受编辑。键盘故障取消草稿并屏蔽编辑，返回后重新进入恢复。应急、断线或 media 重启取消编辑；已应用时间保留。

左上角日期位于 x=16/y=16，时间位于 x=16/y=36。主屏、菜单、应急、诊断及板间断线均显示；播放暂停、轮播、切图、重连和 media 复位不会停止或清零计时。时钟在应急层和软件 RGB 亮度之后绘制；显示器自身 DDC 亮度仍影响整屏。Text OSD/SD 字幕移到 y=64，仍支持 106 字符。

## 首次 CLOCK_TRIAL 实板故障反馈（历史）

用户确认两板均下载首次 CLOCK_TRIAL，启动后始终没有正常图片，黑屏一段时间后显示 ERROR 5，其余功能正常；原包正常。首版包的图片功能实板验收失败，不作为当前使用版本推荐。既有 ZIP、bit、仿真记录和物理报告保留原样，失败状态另行记录，避免改动已交付文件的校验值。随后接收时序修改版已获用户功能确认，详见上述恢复记录。

排除换行差异后，与 GPIO 配套包源码相比，图片控制器、可靠链路、图片缩放和 SDRAM 读写 RTL 没有变化。media 新增菜单分支，render 新增时钟及相关菜单、字库和视频叠加逻辑；重新实现改变了全板布局。ERROR 5 可能来自 media 图片加载/提交超时，也可能来自 render 单路扫描像素欠载，屏幕错误码没有标明来源。

时序重点：media 的 −2.413 ns 路径涉及发送包序号选择；render 的 −0.551 ns 路径从 `u_link/u_receive/header_q` 到 `u_seam/payload_kind`，直接涉及图片接收分类。原包正常使本次版本变化成为重点，但原 media 本身也有 Setup 违例，不能凭 WNS 或错误码认定因果。后续定位需区分首图探测、READY、数据写入、提交和 PRESENTED 的停滞阶段。正式时序要求和原始超时保护不放宽。

## 实现与接口

100 MHz 总线时钟产生每秒使能，年偏移/月/日/时/分/秒共 33 位。支持区间内以年份偏移低两位判断闰年，2000 年正确包含 2 月 29 日。日历和编辑模型不依赖链路复位或播放进度。

显示数字由共享双重移位加三转换器准备；转换寄存器直接作为稳定邮箱，在完整请求/应答握手结束前保持。视频域只在帧界接收完整日期、草稿、焦点和编辑标志；视频域单独复位会重新发布快照。最终时钟层增加三拍，RGB/HS/VS/DE 等长，每拍一个像素。

共享字库第二端口按有效请求在音量提示与时钟之间复用。顶部时钟、中央时钟编辑卡片及下部音量提示的字形请求区域不相交。覆盖率采用 0、1/4、3/4、1 四档透明白字，底板保持半透明，避免增加独立字库或在像素路径执行日期转换。

协议 minor=9，UI 快照仍为 292 字节；flags[15:13] 的 page=7 表示 CLOCK，page=6 留给 media 内部字幕状态 ROM，bit12 仍仅表示 Text OSD。CLOCK 选择为 settings_sel=6/cursor_row=8。矩阵编辑事件本地消费，返回和 CANCEL 沿用既有可靠控制通道，不新增 opcode 或日期负载。

## 构建与验收

正式 `MyFlow.tcl` 和 `check-reports.ps1` 保持原门槛。Setup 未达门槛时原构建仍会阻止正式 bitgen。试板入口 `tools/dual-board/generate-clock-trial.ps1` 仅从最终保持修复后的路由数据库生成单独标记的 CLOCK_TRIAL bit，要求源指纹一致、物理资源合法及 Hold 零违例；不会写入正式资格状态。

当前选定候选、资源、两板时序和 SHA256 见 [当前构建清单](../../build/clock-rx-timing-fix/release_clock_rx_timing_trial/manifest.json)，后续用户确认见 [实板状态记录](../../build/clock-rx-timing-fix/release_clock_rx_timing_trial.hardware-status.json)；首版完整仿真与输入指纹见 [历史回归记录](../../build/clock-v1/regression.json)。当前功能已获用户确认，长期验收仍待完成；软件仿真和物理实现不能替代实板验收。

验证覆盖 117 次完整回归执行及 7 次补充检查，共 124 次通过；日历独立参考覆盖 36525 个日期边界，最终冻结 RTL 输出 11 种完整 720p 画面。首次回归中旧 UI 测试将 page=7 当作通用回退页，已改用 page=6，并增加 CLOCK 页旁路检查后续跑；末尾编译工具进程异常退出的两个音频场景分别重跑通过。原始中断日志和续跑日志均保留，不计失败执行为通过。

首次 CLOCK_TRIAL（历史）media 使用 9707 Slice（99.05%，比 GPIO 基线增加 14），render 使用 9492 Slice（96.86%，增加 440）；新增 BRAM、DSP、PLL 均为零。Setup WNS 分别为 −2.413 ns 和 −0.551 ns，均未达到正式门槛；Hold WNS 分别为 +0.022 ns 和 +0.021 ns，Hold 零违例。仅按已约定的试板条件交付，正式检查脚本不放宽。

复现：

```powershell
./render/sim/run.ps1 -Test tb_calendar_clock -EvidenceDir build/clock-v1/evidence
./render/sim/run.ps1 -Test tb_clock_view_cdc -EvidenceDir build/clock-v1/evidence
./render/sim/run.ps1 -Test tb_clock_events -EvidenceDir build/clock-v1/evidence
./render/sim/run.ps1 -Test tb_clock_overlay -EvidenceDir build/clock-v1/evidence
./tools/dual-board/run-system.ps1 -Test tb_text_osd_menu
./tools/dual-board/run-regression.ps1
```

综合、物理实现使用新的 RunTag；已存在的候选和试板 bit 不覆盖。精确构建参数以试板包 `reports/*/settings.cfg` 为准。

实板验收清单：

1. 配套下载两板，核对默认日期及 CLOCK 第七项；覆盖所有字段边界、闰年、应用、取消和年月日期钳位。
2. 核对主屏、设置、七种应急组合、错误诊断及断线时左上角持续显示，字幕、音量提示没有字形串扰或遮挡。
3. 至少 20 次设置及应急进入/退出；未应用草稿被取消，已应用时间在重连、media 复位和应急恢复后保留。
4. 连续 30 分钟混合图片/音频/菜单/字幕/应急运行；与参考时钟比对并记录误差。实际精度取决于板载晶振，不声明额外校准精度。
5. 单独复位 render，确认恢复默认日期；断电后同样需重新设置。

此前 GPIO 应急试板包保持可用于两板整体回退；不要混用 1.8 与 1.9 两板 bit。
