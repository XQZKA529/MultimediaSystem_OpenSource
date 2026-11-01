# 音量控制（2026-10-09）

基于ed875b4资源优化及high/seed6实板恢复源码实现。两板协议升级至v1.5，需配套更新；原恢复bit和项目备份保留于 `build/audio-volume-2026-10-09/baseline/`，原发布目录未覆盖。本次新产物仍需实板验收。

## 操作

- 0–100%，每步5%，复位100%，线性PCM幅度；0%静音但播放位置继续推进。
- 关窗矩阵2（上）增加、8（下）减少；播放、暂停和无音轨均可调。按下立即一次，500ms后每150ms连发。
- 一级菜单第五项VOLUME；二级页显示百分比和20段条。矩阵4减6增、KEY4减KEY2单击增；#或KEY2双击返回、KEY3关闭。
- 关窗调节显示约2秒提示，重复操作续时，边界操作也显示当前等级；菜单、断线和诊断取消，设置调节及重连不弹出。
- 退出、切图、换曲、暂停和重连保留音量；media系统复位恢复100%，没有断电保存。

## 模块边界

media的 `volume_controller` 是音量唯一所有者，输入为增减和快捷提示意图，输出等级、变更脉冲、提示标记和32位操作版本。菜单持有的 `volume_drawn` 仅用于一页文本绘制快照，不是配置副本。按键路由解析设备事件，菜单生成语义动作；两者在media_core连接控制器。

seam_media在包边界优先发送独立 `VOLUME_SET` 元数据，冻结已经启动的消息并合并最新待发配置。seam_render只校验和交付配置，不计算增益。无载荷消息不复制菜单字符，不占UI_SNAPSHOT保留位。

render的 `volume_view_cdc` 通过四阶段握手保持邮箱，在VS原子提交等级与提示。视频复位重新发布等级，不重放提示。`audio_volume_gain` 只认识24位有符号立体声PCM及等级；输入输出固定两拍，Q15表、完整乘积、正负对称舍入，半数远离零。每个样本增益移动最多69，满量程约475个48kHz样本（9.90ms）收敛。播放环、样本消费计数和Goertzel频谱保持原通路。

`volume_hint_controller` 管理2秒计时与帧界显示状态；`volume_overlay` 只合成像素，区域x=904、y=552、宽360、高48。条形20段，文本复用现有ASCII字库的B读口。菜单/Text OSD继续使用A读口；字库初始化不变，两个端口均同步读一拍。提示RGB/HS/VS/DE固定两拍延迟，隐藏时也保持相同延迟。Text OSD的13位元数据、双银行BRAM字节接口及四拍流水不变。

菜单页编号和选择索引改为3位，保持4位状态接口；状态15由对比度和音量参数页共享。五项菜单保持32×9文本快照，文本ROM共享重复的整行，20个不同文本行共640字节，仍使用原有一块BRAM9K。

## 仿真和综合入口

在仓库根目录：

```powershell
./media/sim/run.ps1 -Test tb_volume_controller
./media/sim/run.ps1 -Test tb_volume_transport
./media/sim/run.ps1 -Test tb_settings_menu
./media/sim/run.ps1 -Test tb_settings_menu -SharedKeys
./media/sim/run.ps1 -Test tb_settings_rom
./media/sim/run.ps1 -Test tb_keypad_router
./render/sim/run.ps1 -Test tb_audio_volume_gain
./render/sim/run.ps1 -Test tb_volume_view_cdc
./render/sim/run.ps1 -Test tb_volume_protocol
./render/sim/run.ps1 -Test tb_volume_overlay
./render/sim/run.ps1 -Test tb_volume_text_pipeline
./tools/dual-board/run-system.ps1 -Test tb_text_osd_menu
./tools/dual-board/run-system.ps1 -Test tb_text_osd_menu -VolumeRetry
python tools/dual-board/check-volume-modules.py
python tools/dual-board/audit.py
./media/build/run.ps1 -Stage all -RunTag volume_seed4 -PhysicalEffort high -PlaceSeed 4 -RouteEffort routability
./render/build/run.ps1 -Stage all -RunTag volume_seed8 -PhysicalEffort high -PlaceSeed 8
```

独立综合已确认五个新增模块均不使用BRAM。独立24位增益实例映射4 DSP，整板源码的16位WAV样本低8位恒0可被综合剪枝；最终DSP数量以整板面积报告为准。候选综合/报告在 `build/audio-volume-2026-10-09/probes/`。

已有测试涵盖21档、正负极值、舍入和渐变、valid节拍、边界/取消/长按、五项菜单及板载双击、非法消息、冻结metadata与最新合并、独立复位、2秒超时及重复续时。像素检查包含475596次音量/双读口检查和928093次完整720p文字+音量合成检查。原Text OSD约505万次像素/四拍回归、BRAM复制及独立复位回归继续通过。真实双板链路验证快捷调节、菜单、边界提示、unity/mute和重连；另有实际丢包重传专项。

## 完整构建签核与交付

两板完整综合、布局布线、Hold修复和bit生成已完成，通过现有资源/时序/输入指纹门槛，未放宽约束。使用TD 6.2.168116、面积优先及high物理策略；media保留FSM off、area effort high与routability。原seed3（media）、seed6/7/9（render）遇到PHY-8023/RUN-8102增量Hold布线冲突。最终media seed4、render seed8通过；失败日志保存在发布目录的 `failed-attempts/`。

| 板 | 原Slice → 新Slice（差值） | 原LUT → 新LUT | 原寄存器 → 新寄存器 | BRAM9K + BRAM32K（差值） | DSP（差值） | Setup / Hold WNS |
|---|---:|---:|---:|---:|---:|---:|
| media | 8411 → 8455（+44） | 15186 → 15334 | 10308 → 10374 | 56 + 0（0） | 7（0） | +0.104 / +0.003ns |
| render | 7395 → 7593（+198） | 12603 → 13186 | 9546 → 9895 | 51 + 4（0） | 15（+2） | +0.102 / +0.003ns |

Slice取自Hold修复后的final.qor，其他资源取自最终phy.area；两板Setup/Hold违例数及TNS均为0。差值包含seed和物理优化的影响，不单独归因于新增RTL。media总RAM为56、render为55，DSP分别7/15，均满足计划门槛。原media基线来自实板GUI归档，原render来自7395 Slice恢复版；旧media缺少完整编译前源码指纹，本次新两板有完整指纹。

配套交付（协议v1.5，需同时更新）：

- [media bit](../../build/audio-volume-2026-10-09/release/media/MultimediaSystem_media.bit)
- [render bit](../../build/audio-volume-2026-10-09/release/render/MultimediaSystem_render.bit)
- [配套清单与SHA256](../../build/audio-volume-2026-10-09/release/manifest.json)
- [media签核](../../build/audio-volume-2026-10-09/release/media/qualification.json)、[render签核](../../build/audio-volume-2026-10-09/release/render/qualification.json)
- 发布目录 `source/` 保存与inputs.json逐文件核对一致的两板RTL/IP/约束/构建脚本；`tests/` 保存27份本轮测试日志，`probes/results.json`保存独立综合，`font-init-check.json`保存映射字库65536位核对结果。

复现音量版使用上面的seed4/8命令。render的CLI默认与原生工程已修正为seed8，避免GUI再次使用旧seed6导致Hold增量布线冲突；media的CLI与原生工程默认也已同步为seed4，详见[media GUI修复](media-volume-route-repair-2026-10-09.md)。GUI须关闭旧工程重新打开，Syn/Phy都Reset，并按发布settings.cfg核对策略。重新构建后重新执行check-reports，不以旧签核替代新结果。详见[GUI修复记录](gui-route-repair-2026-10-09.md)。

| bit | SHA256 |
|---|---|
| media | `e3fb7a19260cfa65220493d7494c8ffd751925695d293be1318171eb9fc9cecc` |
| render | `9f14c21e01171107af70f71a6e9a6abac7d691e610b93e3f1fdede80ffe62b7c` |

## 实板验收（待执行）

1. 配套烧录两板新bit，冷启动确认默认100%，菜单五项及文字编辑正常。
2. 播放WAV，用矩阵2/8逐档调节与长按；0%静音，100%接近原音量，确认没有明显调节杂音。
3. 在暂停和无音轨时预设，恢复/开始播放后沿用；换曲、切图、菜单退出和网线重连保留。
4. 检查2秒提示、边界提示、重复续时，以及菜单/诊断/断线取消；106字符顶部文字、音频面板和提示可同时正常显示。
5. 检查板载KEY2单击/双击、KEY4和菜单返回；连续切图、淡化后交接与冷启动不得出现黑屏或ERROR 4–9。
6. 执行30分钟图片/音频混合播放、暂停/快进、音量反复调节和断线重连，记录实际烧录SHA256及结果。

工具回归与构建签核不能代替上述实板测试。本次未进行板卡烧录或实板测量，上述6项仍待执行。
