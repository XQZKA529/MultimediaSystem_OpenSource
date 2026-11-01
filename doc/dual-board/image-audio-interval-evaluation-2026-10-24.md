# 图片配音与可调轮播评估（协议 1.13）

> **更新说明（2026-10-24）**：本报告初版中的 media 布线资源数被用户 GUI 的 PHY-9009 超限信息纠正。最新面积修正及放置结果见文末“media 超限修正”。此前的 media 路由 QoR 属于面积修正前候选，不代表当前 RTL。

本轮在现有字幕目录查找、WAV 播放链、图片轮播秒计数器和 UI 快照上实现图片同名配音与可调轮播。设置主页新增最右侧 INTERVAL 项；间隔默认为 5 秒，范围 5–300 秒，步进 5 秒。两板当前源码必须配套运行协议 1.13。

## 实现与资源复用

- `sd_subtitle_controller` 的两遍目录扫描同时查找 TXT 与 WAV，共用完整文件名比较和已有名称 RAM。匹配不依赖字幕显示开关；应急恢复图片不会重启配音。排除目录、重复 WAV、无效结果和专用 `EMERG.WAV`。
- WAV 通过原播放器打开；实际消费位置到达曲尾且播放状态结束后才循环配音或请求下一张。手动选曲接管当前音频，后续成功切图再恢复配音匹配。
- `fat_bmp_controller` 保留现有约一秒计数器，增加五秒分频和档位倒计时。配音期间不启动默认间隔；菜单、应急及目录操作期间遵循现有暂停/等待流程。
- 页号复用原快照保留位，`UI_SNAPSHOT` 仍为 292 字节。九项主页仍为 32×9 字符，图标使用原 CLOCK 图形并离线缩小到 80×80；没有增加图片/PCM 缓冲或实时图标缩放器。

## 验证

通过的针对性验证包括：

- `tb_sd_subtitle_controller`：全名及大小写折叠查找、TXT/WAV 同时匹配、缺失/歧义/错误结果、取消/恢复及重连。
- `tb_sd_subtitle_fat`：真实 MBR/VFAT 目录、TXT/WAV 与 BMP 共用目录仲裁、WAV-map 与文件 credit、解析和块读取失败。
- `tb_bmp_controller`：默认 5 秒及 10 秒双档轮播门限。
- `tb_settings_menu`、`tb_settings_rom`：第九项导航、page=8、5–300 秒边界、五秒增减和设置 ROM 初始化。
- `tb_media_sd_boot`、`tb_emergency_integration`、`tb_keypad_router`、`tb_clock_events` 通过。
- `tb_text_osd_menu -MenuSmoke`：经双板生产链接到达 page=8 并返回；UI 像素合成与 AA 检查通过。
- `python tools/dual-board/audit.py` 与 `git diff --check` 通过。

`tb_sd_subtitle_system -NoFrameExport` 能编译，但本轮 ModelSim 在 `run -all` 长时间未结束且没有输出 PASS，已中止，因此不计为通过。完整生产综合和物理实现均使用原工程约束，没有放宽签核门槛。

## 同配置综合资源对照

基线为本轮修改前 HEAD 的独立工作树；两边均运行相同 TD 版本、同一设备/约束及 `MapMode=area_prior`、`InferFsm=off`、`AreaEffort=high`。以下是综合网表面积报告计数，不把它们当作最终 Slice 数。

| 板卡 | 基线基础门 | 当前基础门 | 增量 | 基线 DFF | 当前 DFF | 增量 |
|---|---:|---:|---:|---:|---:|---:|
| media | 26,784 | 27,756 | +972 | 10,826 | 10,928 | +102 |
| render | 29,381 | 29,385 | +4 | 12,450 | 12,455 | +5 |

本轮没有对 HEAD 基线再跑物理实现，因此不声称同源最终 Slice 增量；当前完整布线占用如下。

## 当前物理结果

| 板卡 | Slice / 9,800 | BRAM9K + BRAM32K | DSP / 29 | Setup WNS / TNS | Setup 违例端点 | Hold WNS / TNS | Hold 违例端点 | 结果 |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| media | 9,760 (99.59%) | 58 + 1 | 28 | −4.911 ns / −1,863.493 ns | 1,902 | +0.019 ns / 0 | 0 | 未签核 |
| render | 9,582 (97.78%) | 63 + 15 | 29 | −0.246 ns / −0.579 ns | 4 | +0.022 ns / 0 | 0 | 未签核 |

原签核条件为 Setup WNS ≥ +0.100 ns、Setup/Hold TNS 为 0、违例端点为 0，并保留项目现有资源限制。两板 Hold 修复通过；Setup 均未达标，media Slice 余量仅 40。构建工具因此拦截 bitgen，没有生成可发布 bit。媒体板最差 setup 路径从既有 subtitle RAM 读时钟到 seam `seek_wait`；渲染板最差路径在音频 OSD 动画逻辑。该物理结果明确暴露了当前高占用设计的余量不足，仍需单独做面积/时序收敛。

复现命令：

```powershell
cd media;  ./build/run.ps1 -Stage syn -RunTag autoplay13
cd render; ./build/run.ps1 -Stage syn -RunTag autoplay13
cd media;  ./build/run.ps1 -Stage phy -RunTag autoplay13
cd render; ./build/run.ps1 -Stage phy -RunTag autoplay13
```

完整日志、时序和 QoR 文件位于 `media/Runs/{syn,phy}_autoplay13/` 与 `render/Runs/{syn,phy}_autoplay13/`。

## media 超限修正

GUI 报告 media 需要 4905 MSlice，超过 4900 限额。为减少面积同时保持同名 TXT/WAV 同时匹配，WAV 描述符复用了字幕控制器中已有的 `found_cluster/found_size` 寄存器；TXT 描述符继续使用文件请求簇号/大小寄存器。这样移除了新增的 64 位 WAV 描述符副本。轮播配置变化也由设置页发出单拍事件，去掉计时器每拍比较的 6 位影子寄存器和比较器；另移除了曲尾后已不再可达的标志位。

变更后的 media 综合计数为 27,601 基础门、10,858 DFF；面积修正前为 27,756 基础门、10,928 DFF，净减少 **155 门和 70 个触发器**。seed=8 放置报告为 **4,838/4,900 MSlices**（9,675/9,800 Slice，98.72%）、58 BRAM9K + 1 BRAM32K、28 DSP，低于截图中的限额。放置阶段 Setup WNS +0.010 ns、零 setup 违例；Hold WNS −0.014 ns、176 个 hold 违例，仍需 Hold 修复。

本次 seed=8 物理运行进入全局路由后未完成，也未生成 route/最终 QoR 报告，因此只确认了放置阶段面积低于限额，不宣称最终布线、时序签核或 bitgen 通过。`media/Runs/phy_autoplay13_area3/place.qor` 保存当前放置报告；完整复现命令为 `./build/run.ps1 -Stage all -RunTag autoplay13_area3_repro -PlaceSeed 8`。上述面积优化相关的 `tb_sd_subtitle_controller`、`tb_sd_subtitle_fat`、`tb_settings_menu`、`tb_bmp_controller`、`tb_media_sd_boot` 和 `tb_emergency_integration` 均通过。
