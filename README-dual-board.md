# 双板接线与操作速查

系统完整功能与格式见[主 README](README.md)，板内结构见 [media](media/README.md)、[render](render/README.md)。业务协议为 **1.14**；配套 bit 和校验和见[发布说明](release/Second_Release_682b0ab/README-签核说明.md)。

## 接线与启动

1. 两块 HX4S20C 网口用网线直连，要求千兆全双工。
2. FAT32 SDHC/SDXC 卡插 media，BMP/WAV/TXT 放根目录；HDMI 接 render，声音从 HDMI 接收设备输出。
3. TM1650 接 render J2：pin31 SCL/J12、pin33 SDA/K14、pin29 3.3V、pin30 GND；SCL/SDA 外部上拉到 3.3V。
4. 可选应急源接 render J2 pin1 GPIOB0/P4、pin2 GPIOB1/N4，输入 0/3.3V 并共地，内部下拉。
5. 两板分别烧录同一发布配对的 media/render 功能 bit。上电加载首张普通图片，轮播默认关闭；无 BMP 仍可开菜单播放 WAV。

VGA 顶层信号为 virtualIO，未提供物理 VGA 引脚。`*_linktest.bit` 仅测试 PRBS 链路，不显示图片或播放声音。

## 默认设置

| 项目 | 默认 / 范围 |
|---|---|
| 自动轮播 | 关闭；至少两张普通图片才可开启 |
| INTERVAL | 5 秒；5–300 秒，每步 5 秒 |
| TRANSITION | FADE；另有 SMOOTH SLIDE、GRID DISSOLVE、RANDOM |
| 亮度 | 100%；10–100%，每步 10% |
| 对比度 / 饱和度 | 100%；0–200%，每步 10%，仅作用于图片 |
| 音量 | 100%；0–100%，每步 5% |
| 本地 Text OSD | 空、关闭；最多 256 字符 |
| SD SUBTITLE | DISPLAY=OFF、AUTO=OFF |
| CLOCK | 2000-01-01 00:00:00；2000–2099，无掉电保存 |

## 操作

矩阵排列：`1 2 3 A / 4 5 6 B / 7 8 9 C / * 0 # D`。KEY2/3/4 在 media，矩阵键盘在 render。

| 场景 | 操作 |
|---|---|
| 打开设置 | KEY3 或矩阵 `*` |
| 关闭设置 | KEY3；矩阵 `#` 子页返回、主页关闭 |
| 主页/文件/列表选项 | KEY2 单击向后；矩阵 `2/8` 上下 |
| 确认 / 子页返回 | KEY4 短按或矩阵 `5`；KEY2 双击或矩阵 `#` 返回 |
| 数值页 | KEY2 增、KEY4 减；矩阵 `4` 减、`6` 增 |
| 主屏切图 | KEY2 按下下一张；矩阵 `4/6` 上一张/下一张 |
| 轮播开关 | 空闲主屏 KEY2 长按 2 秒；矩阵 `A` |
| 主屏音频 | KEY4 或矩阵 `5` 单击暂停/恢复、双击下一首 |
| 快进 / 停止音频 | KEY4 长按 2 秒快进 5 秒；矩阵 `9` 退出，暂停时也有效 |
| 主屏音量 | 矩阵 `2/8` 增/减，每步 5%，约 2 秒提示 |
| 键盘警报 | 矩阵 `C` 每次按下切换锁存；B 无动作 |

方向键按下执行一次，500 ms 后每 150 ms 连发。菜单 KEY2 单击、关窗暂停单击等等待 300 ms 双击窗口。关窗 KEY2 按下即切图，长按可能先切图再切换轮播。应急/恢复时屏蔽普通操作，启动、切页、断线或故障取消后先松键。

## 设置页

十项依次为 FILE BROWSER、BRIGHTNESS、CONTRAST、SATURATION、TEXT OSD、VOLUME、SD SUBTITLE、CLOCK、TRANSITION、INTERVAL。

- **FILE BROWSER**：只列根目录文件，每页 8 项、名字前 32 字符；跨页重扫，不进入文件夹，隐藏 OVERLAY.BMP。
- **BRIGHTNESS**：优先 DDC/CI 背光，失败回退普通画面 RGB；对比度/饱和度只修改图片。
- **TEXT OSD**：矩阵 `2/8/4/6` 移动、`5` 输入 A–Z/SPACE 或执行 DEL/CLR/ON-OFF；板载键不编辑内容。
- **SD SUBTITLE**：选 DISPLAY、AUTO、CLEAR MANUAL 后确认。AUTO 开启会同时开启 DISPLAY；浏览器选 TXT 成功则 DISPLAY 开、AUTO 关。
- **CLOCK**：`2/8` 选 YEAR→MONTH→DAY→HOUR→MINUTE→SECOND→APPLY，`4/6` 循环调数值，仅 APPLY 上按 `5` 提交。返回丢弃草稿。
- **TRANSITION**：选行后确认应用，退出不自动提交光标模式。
- **INTERVAL**：`4/6` 或 KEY4/KEY2 减/增 5 秒。

## 配套素材与播放关系

普通 BMP 为宽高各 1–4096、24 bpp、BI_RGB、正高度；WAV 为 48 kHz/16 bit PCM 单/双声道。TXT 为可打印 ASCII，可带 UTF-8 BOM；TAB 转空格，只显示首行，最多检查 260 字节/保存 256 字符。

`PHOTO01.BMP` 可配 `PHOTO01.WAV` 和 `PHOTO01.TXT`，主文件名匹配不区分大小写。配音查找独立于字幕开关：轮播开启时等配音实际曲尾换图，关闭时循环配音；无配音时背景音乐继续，轮播使用 INTERVAL。切图后可恢复被配音打断的背景音乐及确认位置/暂停态。矩阵 `9` 取消当前音轨、配音循环与背景恢复，新图/选曲可重启。

SD DISPLAY 开启时优先显示 SD 文字；关闭后回到本地 Text OSD。自动字幕需开启 AUTO，文字长于 74 字符会在 y=64 的中间 70% 窗口循环滚动。

可选固定台标 `OVERLAY.BMP` 为标准 54 字节头、64×64、24 bpp、BI_RGB、正高度，12342 字节；应急 `EMERG.WAV` 格式同普通 WAV，不进入“下一首”列表。示例见[字幕](examples/sd-subtitle/README.md)、[台标](examples/overlay/README.md)、[应急](examples/emergency/README.md)。

## 应急与排障

GPIOB0/1 高有效、回低解除；C 源再按一次解除。全部来源解除才恢复日常状态。画面含红色警示图形、有效来源顺序和每路触发日期时间；同周期用 `=`、先后用 `→`。EMERG.WAV 循环、数字增益固定 100%；缺失/错误时静音保留警报。本地时钟持续走时，render 复位回默认值。

WAIT DATA 表示等待远端状态，LINK DOWN 表示链路不可用，ERROR n 需结合调试信号判断。media LED 逻辑值为 `~link_up`，render 为 `~display_valid`。换卡/更新素材后复位 media。构建、仿真见[主 README](README.md#构建与验证)，开发过程与旧试板记录见[开发记录](doc/dual-board/development-history.md)。
