# 应急音频示例

将本目录的 [EMERG.WAV](EMERG.WAV) 复制到 media 板 FAT32 SD 卡根目录，与日常 BMP/WAV 共存。它是两秒、48 kHz、16 bit、单声道 PCM 提示音，用于检查应急循环播放，不是撤离语音。

应急由 render 的 GPIOB0/1 高电平或矩阵 **C 键按下切换锁存**触发。GPIO 回低解除，C 再按一次解除；三路都无效后才恢复日常播放。B 键没有应急动作。应急音轨数字增益固定 100%，缺失或读取/格式失败时保留警报画面并静音。

固定名 EMERG.WAV 大小写不敏感，单/双声道均可，不加入普通“下一首”列表。图片若以 EMERG 为主文件名，也不会把此保留音轨自动作为配音。

用自己的 PCM WAV 替换时，从仓库根目录运行：

```powershell
python tools/convert_fpga_wav.py input.wav -o EMERG.WAV --ch 1
python tools/inspect_wav.py EMERG.WAV
```

转换器用标准库读取 PCM WAV，不能直接解码 MP3/AAC；压缩音频需先用外部工具转 PCM WAV。接线、来源顺序/触发时间显示及恢复行为见[操作速查](../../README-dual-board.md)，专项测试过程见[开发记录](../../doc/dual-board/development-history.md)。
