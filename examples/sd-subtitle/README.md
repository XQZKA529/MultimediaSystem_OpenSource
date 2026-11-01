# SD 字幕示例

TXT 复制到 media 板 FAT32 SD 卡根目录，两板使用相同发布配对（业务协议 **1.14**）。DISPLAY/AUTO 默认关闭；文件只能含可打印 ASCII，支持开头 UTF-8 BOM 和 TAB 转空格，最多检查260字节、保存首行前256字符，不支持中文。

| 示例 | 使用方法 |
|---|---|
| [PHOTO01.TXT](PHOTO01.TXT) | 与自行准备的 PHOTO01.BMP 同名配对；设置 SD SUBTITLE 的 AUTO 为ON（会同时开启DISPLAY） |
| [MANUAL.TXT](MANUAL.TXT) | 在 FILE BROWSER 中确认，等显示提交成功后关窗，DISPLAY自动开启、AUTO关闭 |
| [LONG.TXT](LONG.TXT) | 选择后检查长字幕滚动及截断状态 |
| [EMPTY.TXT](EMPTY.TXT) | 选择后清空手动字幕，DISPLAY仍开启；不是删除本地Text OSD |

本目录未附带配对BMP。主屏字幕位于y=64、x=192–1087；74字符以内居中，长文本每两帧左移1像素，首尾各停61帧后循环。多行只显示首行，超长标记TRUNCATED (256)，检查范围内的非ASCII字节会导致拒绝。

DISPLAY开启时SD字幕优先于本地Text OSD；关闭DISPLAY可恢复本地文字。自动字幕绑定当前图片，转场/菜单/应急/诊断时隐藏。文件配对、状态和完整控制见[主 README](../../README.md#菜单文件浏览与字幕)。
