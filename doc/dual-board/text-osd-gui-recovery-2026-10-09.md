# Text OSD GUI烧录恢复记录

2026-10-09，用户报告设置中确认TEXT OSD后不显示编辑页，上下切换失效，需退出后恢复导航。故障时render使用`build/bmp-scale-release/render/MultimediaSystem_render.bit`，media使用最新同步取消修复bit。用户随后反馈重新烧录最新GUI编译文件后恢复。

本次没有修改任何菜单或渲染RTL。对比缩放前后，Text OSD页面控制、事件路由与render绘制代码未变化；新增真实菜单链路测试通过。恢复事实说明需要核对构建产物差异，但不能据此确认旧bit缺少模块、烧录错误或具体综合选项是根因。旧配对不能作为Text OSD已通过实板验收的依据。

## 保留产物

已将当前两板原生GUI `MultimediaSystem_*_Runs/phy_1`中的bit、最新面积/时序、route.qor、最终日志及settings.cfg归档到`build/gui-text-osd-recovery-2026-10-09/`。用户未提供实际下载文件哈希，因此这些是当前目录的候选产物留档，不能当作已核实的下载指纹。GUI运行缺少编译时源码指纹，不能将当前源码哈希倒填为当时的构建输入。

资源整理时发现：此前本记录引用的GUI `final.qor`来自旧构建，media为10月5日、render为10月8日。原表中media的50块BRAM/+0.104ns和render的55块BRAM/+0.106ns不适用于本轮bit，现已纠正；旧文件归档为`stale-final.qor`。本轮数据由最新`*_phy.area`、保持时间修复后`route.qor`、`*_phy.ts`及最终`run.log`一致确认。

| 板 | 当前GUI文件生成时间 | SHA256 | 报告Setup WNS | Hold WNS | BRAM9K |
|---|---|---|---:|---:|---:|
| media | 2026-10-09 15:48:24 | `a1784c332824182c0dded00b1418e72eabdb65746ed16475850ebf5716ef6227` | +0.122ns | +0.003ns | 56 |
| render | 2026-10-09 13:02:46 | `5ccf7334b1742a31a2f82aa5a6a0cc9688ae83c43d105eab4b4221311f841c2d` | +0.109ns | +0.003ns | 53 |

两板最终结果均为Setup/Hold TNS=0、违例数=0。GUI与此前CLI产物的bit哈希不同，但bit生成带时间信息，哈希差异不足以证明功能或布局差异；当前资源/时序数值与相应CLI合格构建一致。保留原报告，不以这张表替代完整构建输入审计。归档清单见[evidence/text-osd-gui-recovery-2026-10-09.json](evidence/text-osd-gui-recovery-2026-10-09.json)，完整资源统计见[evidence/current-resources-2026-10-09.json](evidence/current-resources-2026-10-09.json)。

## 新增回归

`tools/dual-board/tb_text_osd_menu.v`连接生产file_browser、media键盘语义路由、两板seam与独立db_link实现、异步MAC时钟、ui_text_overlay、Text OSD事件路由/控制器/视图CDC/绘制模块。覆盖板载确认进入、矩阵导航、页面标志发送、真实视频提交、编辑开关/字符、窗口实际像素、返回后一级导航、重新进入保留配置和KEY3关闭。MAC服务模型不代表物理网口或烧录验证。

```powershell
./tools/dual-board/run-system.ps1 -Test tb_text_osd_menu
```

新用例加入完整回归入口，日志见[evidence/text-osd-menu-system.txt](evidence/text-osd-menu-system.txt)。此前单模块及网络标志用例没有覆盖这一整条菜单链路。

实板状态：用户确认Text OSD菜单恢复；106字符编辑、背景切图、音频并行、断线重连及长期稳定性未因此自动标记通过。先保留用户当前工作版本，具体构建差异根因留待有进一步证据时判断。
