# render GUI 增量布线修复

## 音量版GUI配置修复

本次截图的冲突网为`u_seam/frame_crc_b[19]_syn_12`、`u_link/rst_dup_66`及`u_video_reset/sync_ff[1]`，本机GUI `phy_1/run.log`与截图完全一致。音量扩展后，seed6不再能完成本次增量Hold修复，而已签核的音量版使用high/seed8。上次音量交付保留了旧默认seed，导致GUI重新构建仍然失败。

已将render的工程生成器`build/project.tcl`、CLI默认`build/run.ps1`与原生`.al`同步为high/seed8，策略和UserParams均保存seed8，Reset不会恢复seed6。保留routability、fix_hold=on和原时序/资源门槛，不修改RTL或SDRAM约束。media沿用此前工程与已签核seed4配套bit，本次修复针对截图中的render。

GUI必须关闭旧工程，再打开磁盘上的`render/MultimediaSystem_render.al`，对Syn和Phy均Reset，再从Syn运行到Generate Bitstream；不要直接继续失败的Route，也不要让旧GUI内存配置覆盖新`.al`。phy_1应显示high、seed8、routability、fix_hold=on。截图中的SDRAM位置警告在正常版本也存在，不是本次失败的直接证据。

CLI复现：`./render/build/run.ps1 -Stage all -RunTag volume_gui_fix`。本次构建报告与输入指纹已归档于`build/gui-volume-route-fix-2026-10-09/`，此前音量版签核包仍原样保留。

重新执行默认配置的CLI完整Syn/Phy/bitgen已通过：**7593 Slice、51 BRAM9K + 4 BRAM32K、15 DSP，Setup +0.102ns、Hold +0.003ns，Setup/Hold零违例**。当前源码/脚本输入指纹检查通过，日志没有PHY-8023/RUN-8102；RTL/IP/约束与原签核音量版完全一致，只有两个render构建脚本变化。GUI保存参数已核对，用户重新打开后的GUI实际运行仍待执行。

新[render bit](../../build/gui-volume-route-fix-2026-10-09/release/MultimediaSystem_render.bit)与此前[media音量bit](../../build/audio-volume-2026-10-09/release/media/MultimediaSystem_media.bit)配套使用；[签核及SHA256清单](../../build/gui-volume-route-fix-2026-10-09/release/manifest.json)。render SHA256：`44d3c52e0b32ae6b8a0ef5ff607fa0f6a3fe3b03494e2b44fdc6df1a5e503095`。原音量签核包和实板恢复bit均未覆盖。

## 音量扩展前的历史修复记录

截图与本机GUI日志一致：`PHY-8023`位于`x20y21_n2beg1`、`x20y22_local0`，冲突网络为`u_link/expect_seq[1][7]`、`u_link/expect_seq[0][3]`与保持修复缓冲`u_link/rst_dup_19_holdbuf`；随后`RUN-8102 Incremental route failed`。失败布局占7358 Slice（75.08%）、55 RAM，不能依据这条通用报错认定器件容量用尽。

GUI工程仍保存旧medium/seed4设置，而实板确认正常的恢复版使用high/seed6。已修改`render/build/project.tcl`，用TD原生参数接口将high物理优化、routability、保持修复和seed6同时写入策略与UserParams，避免Reset后丢失覆盖参数；`render/build/run.ps1`默认也统一为high/seed6。主工程`.al`已经重新生成并核对保存值。没有关闭保持修复、放宽时序门槛或修改RTL。

原GUI错误日志和工程备份位于`build/gui-route-repair-2026-10-09/`。SDRAM位置警告在此前正常版本也存在，本轮没有据此修改硬SDRAM实例位置。

## GUI 操作

1. 关闭GUI中旧的render工程，再打开工作区`render/MultimediaSystem_render.al`。必须重新打开，否则GUI内存里的旧配置可能覆盖磁盘更新。
2. 对Syn和Phy都执行Reset，从Syn重新运行到Generate Bitstream；不要仅从失败的增量Route继续。phy_1应显示high优化、seed6、routability与fix_hold=on。
3. 核对本轮`*_phy.ts`、`*_phy.area`和`route.qor`。GUI目录旧bit、旧final.qor不能作为本次成功证据。

CLI等价构建：`./render/build/run.ps1 -Stage all -RunTag gui_route_repair`。CLI与GUI原生流程不同，不承诺生成逐字节相同bit；已实板确认的恢复bit保留不覆盖，新编译仍需功能验收。

构建脚本更新会改变完整输入指纹；恢复bit的HDL/IP/约束未改变，但不能用新脚本对旧bit倒填完整指纹。原签核包保留原始脚本及输入清单。

修正后的默认配置已完成CLI Syn/Phy/bitgen：7395 Slice（75.46%）、51 BRAM9K + 4 BRAM32K，Setup +0.104ns、Hold +0.003ns、Setup/Hold TNS=0，资源/时序/当前输入指纹检查通过，没有PHY-8023/RUN-8102。产物位于`render/Runs/phy_gui_route_repair/`，SHA256为`6f9b6a0af432c1443b7897aa7e97cbd33b78cce2b99e086765b66596e543d446`。GUI保存配置已核对，实际GUI重新打开后的运行由用户执行；CLI通过不等同于GUI此次已经运行成功。此前实板确认正常的恢复bit仍原样保留。
