# 256 字符字幕滚动实现评估（2026-10-22）

## 实现

Text OSD、手动 TXT 和按 BMP 名称自动匹配的 TXT 共用 256 字符容量与 render 端显示路径。720p 字幕窗口为 x=192–1087、y=64；74 字符以内按文字宽度居中，75–256 字符在 896 像素窗口内循环向左滚动，每两帧移动 1 像素，首尾各停 61 帧。提交内容、字幕来源或显示可见性变化时，滚动从开头重新开始；窗口外的像素不叠字。

TXT 有界读取为 260 字节；超过 256 字符时保存前 256 字符并显示 `TRUNCATED (256)`。SD 字幕事务升级为 264 字节（66 个 32 位字），flags 长度使用 bits8:0，显示/自动/截断/首行标志使用 bits9–12。双板协议为 1.12，文本 RAM 重分区后沿用现有 BRAM。

## 仿真结果

通过的针对性回归包括 TXT parser（BOM、TAB、256/257 字符和格式边界）、本地 Text OSD 容量/DEL/追加、256 字符跨时钟域快照、SD 字幕接收行为 RAM 与原生 BRAM、字幕滚动帧状态、完整 Text OSD 像素/同步参考、设置菜单 BRAM 初始化、FAT32 实际 TXT 读取以及双板可靠链路字幕系统（关闭重复的全帧导出）。证据日志位于 `media/build/evidence/`、`render/build/evidence/` 和 `doc/dual-board/evidence/sd-subtitle-system_no_frames.txt`。

双板 Text OSD 菜单专项最初失败是测试台漏接 `file_browser.transition_mode` 到 `seam_media.transition_mode`，导致快照控制字带高阻位，仿真中的相等比较变为 X 并反复丢弃快照。补齐连线、产生有效复位脉冲后，完整 `tb_text_osd_menu` 通过；结果见 `doc/dual-board/evidence/text-osd-menu-system.txt`。纯控制字段变化不再提前宣告字符 RAM 已提交，避免菜单文本写入完成前复制旧页面。

完整 1280×720 短字幕、75 字符边界、长字幕、256 字符字幕及 Text OSD 编辑器常规/焦点画面均由 `tb_text_osd_frame_ppm` 导出，每帧 921,600 像素。使用 `tools/dual-board/convert-text-osd-frames.py` 和 `tools/dual-board/check-text-osd-frames.py` 完成转换及像素检查，结果通过并记录于 `build/ui-text-osd-sim/visual-check.json`。画面位于 `build/ui-text-osd-sim/frames/`。检查脚本和参考模型按新的 70% 窗口更新。

## 综合、布局布线与签核

两板使用独立的 `subtitle_scroll_v112` 输出目录，保留原器件、约束和签核门槛。输入清单 SHA256：media `53367FAC4F028A2032FB03D87F7090ADC4C35C5FCE1E90A80BCC79231A83A833`；render `BE6812ABD934B6F3FB3393152464B643059BBA69565100629A3D8A93A4B951B7`。

| 板 | Slice | BRAM9K/FIFO9K + BRAM32K | DSP | Setup WNS / TNS | Hold WNS / TNS | 结果 |
|---|---:|---:|---:|---:|---:|---|
| media | 9471/9800（96.64%） | 58 + 1 | 28/29 | −2.405 / −221.088 ns | −0.020 / −0.020 ns | 未通过；bitgen withheld |
| render | 9454/9800（96.47%） | 60 + 15 | 29/29 | −9.653 / −489.163 ns | +0.022 / 0 ns | 未通过；bitgen withheld |

两板的片上 RAM 数与协议 1.11 基线相同，没有增加 BRAM；render Slice 比基线增加 137，media 增加 50。media 有两条 Hold 违例；render 的 Setup 仍严重违例且总 RAM 75，超过当前 build flow 的 56 块内部资源门槛。两板均未生成 bit，也没有放宽时序或资源签核规则。

原始输出：`media/Runs/phy_subtitle_scroll_v112/`、`render/Runs/phy_subtitle_scroll_v112/`。综合/布局布线数字按最终 `.area`、`final.qor` 与 `.ts` 报告记录；构建脚本在原门槛失败时明确阻止 bitgen。
