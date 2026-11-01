# SD 台标示例

将 [OVERLAY.BMP](OVERLAY.BMP) 复制到 media 板 FAT32 SD 卡根目录。它是固定保留名、标准54字节头、64×64、24 bpp、BI_RGB、正高度、自下而上BMP，总长12342字节；不进入普通图片轮播目录或文件浏览器。

media在主图显示且相关通道空闲后加载，转为RGB565，经整对象CRC和视频提交后，render在 **x=1200–1263、y=16–79** 不透明叠加。设置、应急、诊断和断线场景隐藏，主图切换时台标固定，不参与转场，受普通画面亮度影响。缺失/格式/读取错误时隐藏，不阻断主图。

[source.png](source.png)为可编辑源图，仓库根目录运行：

```powershell
python tools/convert_sd_overlay.py examples/overlay/source.png OVERLAY.BMP
```

转换器依赖Pillow，缩放到64×64并写出规定头部，不提供透明通道。也可不带参数进入路径交互。[preview_1280x720.png](preview_1280x720.png)仅为坐标示意，渐变背景不属于真实输出。完整功能见[主 README](../../README.md)。
