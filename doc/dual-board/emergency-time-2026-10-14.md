# 紧急触发时间记录（2026-10-14，协议 1.9）

B0、B1 和 C 的有效顺序记录现在同时保存触发确认时的 CLOCK 日期时间，精度为秒。原黑底红色图案与顺序行保留，下面按相同顺序逐行显示白色时间记录，例如：

```text
B0 = B1 → C
B0 2026-10-14 15:30:01
B1 2026-10-14 15:30:01
C  2026-10-14 15:30:05
```

## 操作和保留规则

先在设置的 CLOCK 页调整当前日期时间。没有设置时沿用系统默认 `2000-01-01 00:00:00`；不新增 RTC 或掉电保存。

GPIO 稳定确认高电平、C 按下沿切换为有效的总线周期采样触发时间；读的是该边沿之前的 CLOCK 值。秒进位或 CLOCK APPLY 与触发同周期时，记录旧值。实际时钟继续运行，已触发时间保持不变。

同一个确认周期触发的来源共用时间，用 `=` 连接；不同周期仍用 `→`，即使记录的时分秒相同也不会合并。并列组内部按 B0、B1、C 排列。解除来源即移除对应显示；再次触发更新时间并移到末尾。每次最多三个有效来源，不提供历史记录页面。

记录行固定 22 个字符、每字符 16 像素，左起 x=464，y=612、644、676，字形为原应急 5×7 点阵的两倍显示。最后一行区域结束于 y=699，不超出 720p 画面。左上角的实时日期时间保持显示。

最后一个来源解除后的恢复阶段保留最后非空来源画面及其时间；恢复完成后隐藏记录。恢复期间重新触发，记录新时间，继续沿用最初的日常图片/音频快照。断线、media 复位不清除本地有效来源和时间；render 系统复位清除记录，高 GPIO 经重新确认后记录新时间。

## 实现与验证

输入模块保留三个 33 位日历编码和一份确认流水时间。跨时钟层用一套串行 double-dabble 转换器生成三个 48 位 BCD 日期时间，四阶段邮箱保证载荷稳定，视频域在应急绘制层输入的垂直同步消隐窗口整体接收。时间更新始终伴随来源集合变化，转换期间逐周期监测集合/顺序；等待帧界时的短暂解除/重触发也会标记需要重新发布，避免最终集合相同而遗漏新时间。

生产绘制层复用已在帧界提交的 CDC 时间寄存器，避免再复制 144 位时间。独立绘图使用默认的本地帧锁存；生产组合选择 `FRAME_TIMESTAMPS=1`，要求上游时间仅在垂直消隐中变化。来源、顺序在 VS 结束提交，时间在同一垂直消隐期间已整体准备好；允许控制器在 VS 上升沿后解除应急，并在该窗口接收解除快照，保持下一活动帧的画面与音频一起恢复。RGB 与 HS/VS/DE 继续同步延迟三拍。板间协议、UI 292 字节快照、media RTL 和音频格式不变。

时间 BCD 邮箱按字段上界省去恒零高位，公开接口仍为三个 48 位 BCD 时间；覆盖全部 100 个年份及多组日期时间字段。仅复位控制与记录有效性，邮箱数据在完整转换和握手前不会发布；无效载荷不作显示。

新增仿真覆盖确认采样、同秒先后、并列、解除重触发、记录冻结、转换中连续变化、帧界背压时集合回到原值、视频域单独复位、恢复画面，以及闰日/月末/年末/2099 年回绕和触发与秒进位/APPLY 同周期。生产 CDC 与绘制组合检查活动帧期间完整显示状态稳定。

完整画面检查覆盖 25 种有效顺序和七种来源图案，独立 Python 检查器逐像素验证红色几何图案、白色顺序及三行日期时间。另生成 11 张完整 CLOCK 合成画面，验证顶层时钟与应急记录可共存。回归还覆盖原应急控制/音频恢复、CLOCK 编辑、字幕、菜单、链路和完整 720p 图片接收。

全套非绘图仿真完成后，最后一次修改仅涉及本地 CDC 的寄存器实现。依据源码指纹和实际编译依赖复用 54 项未受影响证据，重新运行两个直接使用 CDC 的用例；两项完整绘图仿真本轮单独执行。复用证明及每份 PASS 日志 SHA256 写入发布包回归清单。直接受影响场景使用新 RTL 重新验证。

结果、最终资源与时序以本轮发布包的 `manifest.json`、`regression.json` 和 `visual-check.json` 为准。早期候选因 MSlice 超容量失败，其日志保留，不计作合格产物。正式签核脚本没有放宽；本次按资源合法、Hold 零违例的试板标准交付并完整披露 Setup。

## 最终构建结果

render 使用 `syn_emergency_time_v7` 与 `phy_emergency_time_v7_high5_nopost`，area_prior / high / seed5，post_place_opt=off，原生 Hold 修复保持启用。

| 项目 | 当前 render | 相对 CLOCK 接收修复版 |
|---|---:|---:|
| Slice | 9787 / 9800（99.87%） | +210 |
| LUT / 寄存器 | 17427 / 12588 | +463 / +379 |
| BRAM9K / BRAM32K | 51 / 5 | 0 / 0 |
| DSP / PLL | 15 / 2 | 0 / 0 |
| Setup WNS / TNS | −1.015 / −86.454 ns | 正式门槛未通过 |
| Hold WNS / TNS | +0.022 / 0 ns | 零违例 |

共 58 项验证用例：56 项非绘图场景和两项完整绘图仿真。完整应急画面 25 张、CLOCK 合成画面 11 张，Python 独立检查 23117792 像素和全部固定字形行；CLOCK 合成测试另执行 10272823 次 RGB/同步检查。

media 沿用原 `clock_v1_medium3` bit：9707 Slice（99.05%）、Setup −2.413 / −638.324 ns、Hold +0.022 / 0 ns；当前原配套版本已获用户实板确认。本次新增触发时间功能仍待实板验收。

## 下载、复现及实板验收

本轮包位于 `build/emergency-time-v1/release_emergency_time_trial.zip`。render 下载 `render_EMERGENCY_TIME_TRIAL.bit`；media 使用与当前 CLOCK 接收修复版逐字节相同的 `media_CLOCK_RX_TIMING_TRIAL.bit`。已经运行 CLOCK 1.9 配套版本时只需更新 render；从 GPIO 1.8 升级必须两板配套更新。

```powershell
./tools/dual-board/run-emergency-time.ps1
python ./tools/dual-board/check-emergency-time-frames.py
./render/build/run.ps1 -Stage syn -RunTag emergency_time_new
./tools/dual-board/run-emergency-time-physical.ps1 -Board render -SynthesisRunTag emergency_time_new -RunTag emergency_time_new_high5_nopost -PlaceSeed 5 -PhysicalEffort high -SkipPostPlaceOpt
./tools/dual-board/generate-emergency-time-trial.ps1 -Board render -RunTag emergency_time_new_high5_nopost
python ./tools/dual-board/package-emergency-time.py --render emergency_time_new_high5_nopost
```

若正式 bitgen 因 Setup 门槛终止，只有完整路由数据库、合法资源和零 Hold 违例均满足时，才允许上面的独立试板 bitgen。独立物理脚本的 `-SkipPostPlaceOpt` 仅关闭 TD 6.2 崩溃的 post-place 优化阶段，保留原约束、原生 Hold 修复及正式门槛；精确参数以发布包 settings.cfg 为准。已有构建标识及交付目录不能覆盖；发布脚本重新核对源文件、测试证据及两板配套 bit 的 SHA256。

实板待用户验证：

1. 设置 CLOCK，分别触发 B0、B1、C，核对日期时间冻结、顺序及左上角时钟持续走时。
2. 测试并列、同秒先后、解除中间来源、解除后重触发和全部七种组合。
3. 在午夜附近触发，核对跨日；未设置时核对默认日期；单独复位 render 后确认旧记录清除。
4. 应急期间断线、media 重启和恢复中重触发，核对时间、图片、音频位置及暂停状态。
5. 至少 20 次应急进入/恢复及 10 分钟应急播放，记录异常与两板 bit SHA256。

仿真和工具结果不等同于实板确认；原 CLOCK 接收修复发布包保留为回退版本。
