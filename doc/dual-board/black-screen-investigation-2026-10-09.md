# render 黑屏调查

用户实板对照：只更新render时，7204 Slice CLI版本有HDMI信号但全黑、菜单不可见；换回归档GUI版本恢复；只有抗锯齿字库升级的8441 Slice版本也正常。用户随后从GUI编译当前Text OSD BRAM源码，观察到每次切图短暂出现图片后黑屏，其他功能正常。两种故障表现分别记录，不假定根因相同。

进一步反馈明确时间点：**淡入效果结束，新图清晰的瞬间变黑**。因此实际排查重点是双路淡化结束后的单路交接，不把下述“首次淡化中欠载回退”复现当作实际根因。

故障CLI版本已撤回烧录推荐。当前恢复入口是用户已确认正常的[字库版render bit](../../build/aa-font-bram32-2026-10-09/render/MultimediaSystem_render.bit)，media保持原版。

## 已复现的故障路径

更贴近最新反馈的条件复现：保持新图像素有效，淡化到`alpha=256`时混合输出`ffffff`；完成读通路交接后，模拟单路图像没有有效像素，输出变成`000000`，此时`transition_done=1`、`transition_failed=0`、`disp_valid_out=1`。生产`mix_fail`仅在`mix_lane1_en=1`时检查`pair_ok`，故单路欠载不会通过这条路径上报失败。这证明单路读图缺失可以产生“清晰瞬间变黑、事务仍判成功”，尚不能证明实板实际触发了该条件。代码与日志为`tb_fade_end_black.v`、`handoff-repro.txt`。

完整720p读图回归于本次调查重新通过：两个双路帧、切回单路帧以及中断后恢复帧，共四帧。它没有覆盖物理SDRAM数据完整性，也没有将最新Text OSD布局后的实板故障标记为通过。

生产`pixel_mixer`与`mix_transition_ctrl`连接测试中，首次图片提交时`disp_valid_out=0`，仍从黑底启动双路淡化。注入一次新图`pixel_valid=0`后，`mix_fail`终止淡化、进入`T_RECOVER`，随后`transition_failed=1`、`mix_active=0`，`disp_valid_out`仍为0。`render_core`因此强制`rgb_base=0`，下一次提交会重复这条路径。测试实测混合像素先出现`090909`，随后回到无有效显示图状态。

这证明一次欠载足以产生“闪出图片再持续黑屏”，**尚未证明实板发生了欠载，更未确定欠载来自SDRAM、FIFO、跨域或物理布局**。既有转场测试覆盖成功以及已有旧图时的失败保留，没有覆盖首次图片失败后黑底这一组合。既有720p读图仿真也不能替代实板SDRAM和布线验证。

另一处可确认的诊断缺口：`err_show`与`err_code_show`只取网络/远端状态，没有把本地`mix_fail`或`transition_failed`显示出来，因此本地转场失败可能只有黑底，没有解释性的错误文字。

复现代码与日志位于`build/black-screen-2026-10-09/tb_first_image_underflow.v`、`repro-simulation.txt`；运行`./build/black-screen-2026-10-09/repro.ps1`。故障GUI bit及报告已独立归档，bit SHA256为`dd8c92e5c34de912c1467b3995000f247cc743b6b92ac6907de832f0aca2b256`；没有当时输入指纹，不将当前源码反填为GUI构建证据。

## 隔离诊断版

诊断源码位于`build/black-screen-2026-10-09/diagnostic/render/`，保留现有Text OSD BRAM和转场行为，只增加视频域本地故障锁存与现有ERROR横幅。主工程RTL不修改。

| 错误码 | 含义 |
|---|---|
| ERROR 4 | 双路结束后等待读通路交接超过两个帧边界 |
| ERROR 5 | 单图扫描的旧图解包器缺少有效像素 |
| ERROR 6 | 转场失败，未捕获到对应缺失路的分类 |
| ERROR 7 | 淡化期间新图解包器缺少有效像素 |
| ERROR 8 | 淡化期间旧图解包器缺少有效像素 |
| ERROR 9 | 淡化期间两路均缺少有效像素 |

错误锁存持续至下一次切图请求。菜单可以遮住错误横幅，观察时关闭菜单。这里的“缺少有效像素”指解包器有效标志，不能直接推导为SDRAM数据损坏。诊断版仅用于定位，不是已修复版本，也没有实板验收。

首个诊断版medium/seed4的Setup WNS为−0.048ns，未生成bit，未放宽签核门槛。后续诊断版增加交接超时检测，并将单路欠载检测扩展到交接等待阶段，独立构建留档。

诊断版high/seed5的Setup为−0.036ns，亦未生成bit。high/seed6通过：Slice 7395（75.46%），51 BRAM9K + 4 BRAM32K，Setup +0.104ns、Hold +0.003ns、两类TNS=0，源码输入指纹一致。

[隔离诊断bit](../../build/black-screen-2026-10-09/release/MultimediaSystem_render.bit)的SHA256为`c54c9dc548d0e2f188792cba41316d0e5b95fc4980381570efa3c439b271164b`，仅更新render。重现切图，关闭菜单观察错误横幅，再反馈错误码或“没有错误文字”。诊断锁存代码单独验证了正常不显示、单路欠载、新图欠载、结果保持、下一请求清空和交接超时，测试通过。

## 用户确认恢复及当前源码

用户烧录high/seed6诊断bit后先反馈“不再黑屏”，随后确认连续切图、淡化、菜单、文字编辑和音频均正常，且没有ERROR 4–9。该bit现在作为实板恢复版本保留。主工程`render_core.v`已同步为该bit的精确输入，根工程执行输入指纹/资源/时序检查通过；没有修改media。

恢复版保留Text OSD BRAM、字库和本地故障检测，7395 Slice（75.46%）、12603 LUT、9546寄存器，51 BRAM9K + 4 BRAM32K、13 DSP。与字库版8441 Slice相比少1046（12.39%），布局种子4→6，不能将差值当作同种子的单模块因果测量。

**根因仍未确认。**诊断改动没有修改读图/转场状态机；故障观测逻辑与布局同时变化，正常结果不能区分物理布局、综合优化或其他硬件敏感因素。未观察到错误码，就不能据此声称实板欠载发生、或某条失败状态机路径已修复。保留已正常的bit，避免仅删除检测逻辑再换一次布局而丢失可用产物。

扩展后的完整720p读图回归通过：双路读取后，1号新图缓冲转到主读通路，逐像素/地址核对完整帧；再切回0号缓冲并验证中断后恢复。长期30分钟运行、断线重连和冷启动稳定性尚未验收。

复建当前源码使用`./render/build/run.ps1 -Stage all -RunTag recovery -PhysicalEffort high -PlaceSeed 6`。GUI配置后续已修正为high/seed6并保存到原生工程，见GUI布线修复记录；重新编译须重新验收，优先保留本次已确认正常的bit。完整源码、输入指纹、报告及清单见[恢复包](../../build/black-screen-2026-10-09/render-recovery.zip)。
