# media 音量版GUI增量布线修复

截图中的PHY-8023位于`x17y34_local6`，冲突网络为`u_media/u_fat_wav_controller/seek_cap_r[4]`和`u_link/rst_dup_270_holdbuf0`；随后RUN-8102。与本机GUI `media/MultimediaSystem_media_Runs/phy_1/run.log`完全一致，也与此前seed3音量构建的失败一致。

## 修复

此前音量版media已用high/seed4/routability通过签核，但GUI工程及CLI默认仍保留seed3。本次将`media/build/project.tcl`的原生策略和`media/build/run.ps1`默认同步为seed4，并通过TD原生API保存`.al`。保持FSM off、area effort high、high物理优化、routability与Hold修复，不修改RTL/IP/约束，不放宽资源或时序门槛。保留原工程源文件顺序。

GUI操作：

1. 关闭旧media工程，再打开`media/MultimediaSystem_media.al`，避免旧GUI内存覆盖磁盘设置。
2. 核对phy_1为high、seed4、routability、fix_hold=on。
3. Syn和Phy均Reset，再从Syn运行到Generate Bitstream，不继续失败的增量Route。
4. 检查本次phy.area、phy.ts、route.qor和run.log，不能拿目录中旧bit或旧报告认定成功。

## 验证范围与来源

本次CLI尝试重新综合时，TD在`elaborate -top top_media`阶段出现`Oops! coredump`；两次日志分别保留于`media/Runs/syn_volfix/console.txt`和`media/Runs/syn_volfixfresh/console.txt`。这与截图中已完成综合后的布线冲突是两个问题。没有把失败综合当成通过，也没有覆盖旧综合签核。

当前RTL、IP、约束及其他输入与已签核的`media/Runs/syn_volume/inputs.json`逐文件SHA256核对一致；仅project.tcl和run.ps1改变默认物理seed。复用原`MultimediaSystem_media_gate.db`重新执行high/seed4物理构建。复用来源、原输入清单和网表SHA256见`media/Runs/syn_volfixroute/reuse-provenance.json`，原综合inputs保留为`original-synthesis-inputs.json`，当前调用inputs单独记录。不声称本次全新综合通过。

原GUI错误和工程/脚本备份在`build/media-volume-route-fix-2026-10-09/before/`。原音量签核包及实板恢复bit未覆盖。GUI重新打开后的实际运行与实板验收由用户执行。

## 本轮结果

复用上述综合网表，重新执行Place/Route/Hold修复/bitgen已通过，日志没有PHY-8023/RUN-8102：**8455 Slice、56 BRAM9K、0 BRAM32K、7 DSP，Setup +0.104ns、Hold +0.003ns，Setup/Hold零违例**，当前调用输入指纹检查通过。Slice86.28%仍触发原有80%建议提示，但不影响原定时序/资源门槛；未放宽任何门槛。

- [本轮media bit](../../build/media-volume-route-fix-2026-10-09/release/MultimediaSystem_media.bit)
- [配套render seed8 bit](../../build/gui-volume-route-fix-2026-10-09/release/MultimediaSystem_render.bit)
- [签核、SHA256与复用来源清单](../../build/media-volume-route-fix-2026-10-09/release/manifest.json)

media SHA256：`9fe8c7792daae84886aa19730c320b35b75b6b8911ed36bda24f84476b62badd`。本次CLI新综合未通过，GUI重新综合及实板验收仍待执行；已签核原media音量bit也继续保留可用。
