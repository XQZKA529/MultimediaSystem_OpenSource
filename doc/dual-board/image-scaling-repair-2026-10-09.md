# BMP ERROR 5 回归排查与修复（2026-10-09）

## 实板报告与边界

用户烧录 `bmp_scale_release` 配对 bit 后，SD 根目录只放此前正常显示的 1280×720 BMP，五秒内出现 ERROR 5；FILE BROWSER 仍可看到该文件。目录可读说明初始化、挂载、目录枚举已完成，排查转向图片探测/事务。旧版本正常，不能用工具签核代替这次实板失败。

## 与改动前读取链路的差异

| 环节 | 改动前 | 缩放首版 | 本次修复 |
|---|---|---|---|
| SDIO 初始化、SD 引脚采样参数 | 原实现 | 未改 | 未改 |
| FAT / 存储封装 | 文件突发最多4扇区 | 参数化，图片1扇区；WAV独立链不变 | 保留 |
| 头部探测 | 512字节，直接解析 | 512字节，独立解析及几何计算 | 保留；读取许可仍绕过网络图像许可 |
| 全文件读取许可 | 网络发送FIFO | 原始字节FIFO≥528字节，逐像素另有网络许可 | 保留 |
| 事务取消 | 原控制器同步状态处理 | FIFO同步取消，但解包器、缩放器及行缓存通过 `rst || cancel` 异步复位 | FIFO、解包及缩放状态同步取消；行缓存只接系统rst，并在读写起始重建行状态 |
| 完成 | file_done | EOF + 解包 + 缩放 + 打包排空 | 保留；不放宽完成及超时条件 |

控制器的 `pipeline_cancel = state != C_LOAD && !pipeline_start` 是多位 FSM 的组合译码。WAIT_WR=0101 到 LOAD=0110 的转换会同时改变多位状态及启动译码；RTL 零延迟仿真不模拟各路布线的传播差异。该译码直接接异步复位时，边沿之间的短脉冲可复位解包器和缩放器，但 FIFO/外层事务只在时钟边沿处理取消，仍处于加载中。结果无输出、不能排空，最后触发加载超时 ERROR 5。

这是已复现的结构性缺陷，也是实板症状的合理根因候选；注入测试证明旧代码对该毛刺敏感，不能据此声称已测到实板上的实际毛刺。修复是否解决本次实板故障须由新 bit 烧录结果确认。

## 可复现验证

`tb_bmp_controller -CancelGlitch` 在第一次 WAIT_WR→LOAD 后1ns注入1ns取消脉冲，脉冲不跨时钟边沿。旧版在11695ns停止，记录 `abort_error=5 pixels=0`，负对照见 [bmp-scale-cancel-negative.txt](evidence/bmp-scale-cancel-negative.txt)。同步取消版在同样脉冲下正常完成全部六次成功提交，原有失败重试、截断、取消、重放、末尾阻塞保护仍通过。

```powershell
./media/sim/run.ps1 -Test tb_bmp_controller -CancelGlitch
./media/sim/run.ps1 -Test tb_bmp_overflow
./media/sim/run.ps1 -Test tb_image_timeout
./media/sim/run.ps1 -Test tb_media_sd_boot -ScaleFull
./tools/dual-board/run-regression.ps1 -SkipSystem
./media/build/run.ps1 -Stage all -RunTag bmp_scale_cancel_fix_s3 -PlaceSeed 3 -PhysicalEffort high -RouteEffort routability
```

修复版新增完整 `media_core` 测试已通过：从 SD 扇区模型开始，复用真实 FAT、存储封装、BMP、缩放、打包与 media seam，逐字核对691200字，跨42个FAT簇边界，再检查EOF、END、PRESENTED及display_valid。SD引脚电气、MAC与真实SDRAM仍需实板验证。旧开机测试只检查前512字；原完整fixture的FAT链已补齐，提交检查使用正确的C_READY=3。

## 当前状态

旧 `bmp_scale_release` 标记为实板失败版本，不继续推荐烧录。新 `bmp_scale_cancel_fix` 的完整720p读取、640×480→720p逐像素、毛刺注入、取消/重试及超时专项已通过；两板全模块回归与并行WAV联合测试也已通过，构建签核完成；BRAM≤56、Setup WNS≥0.100ns及Setup/Hold零违例的门槛保持不变。render RTL与原配对render bit不因本次修复改变。新bit资源与时序见下表。实板修复、不同尺寸显示及30分钟轮播尚未确认。

第一次修复版布局（种子4、medium、normal）在保持时间修复后遇到局部布线拥塞，没有合格bit；日志见 `evidence/bmp-scale-failed-cancel4-medium/`。继续使用其他布局种子，构建门槛不变。

## 合格烧录配对

| 板 | 使用产物 | BRAM9K | Setup WNS | Hold WNS |
|---|---|---:|---:|---:|
| media | `build/bmp-scale-cancel-fix/media/MultimediaSystem_media.bit`（新） | 56 | +0.122ns | +0.003ns |
| render | `build/bmp-scale-cancel-fix/render/MultimediaSystem_render.bit`（与上次提供的render相同） | 53 | +0.109ns | +0.003ns |

两板Setup/Hold TNS均为0。media DSP=7，Slice=85.83%；render DSP=13，Slice=85.09%。Slice80%仍为已有提示线。完整源输入指纹已逐文件核对，bit SHA256已核对复制前后相同；签核记录见 [bmp-scale-cancel-fix-qualification.json](evidence/bmp-scale-cancel-fix-qualification.json)。

media SHA256：`cde4654d0d908c51cb0922afedba59bc5efb6139e1ad24b8f7369ddde169d2f1`。
render SHA256：`0aa4999bad86063a3f97e89ecffa7e01b76c941acd39a0ceaf222729ff398798`。

只需重烧media，新产物绝对路径为 `D:/AnLu_FPGA_project/MultimediaSystem_v1/build/bmp-scale-cancel-fix/media/MultimediaSystem_media.bit`。先用原单张720p复测；实板成功后再记录不同尺寸、音频并行及30分钟轮播。旧 `bmp_scale_release` 实板失败，新同步取消版目前仅确认仿真/工具签核，尚未确认实板恢复。

种子5/medium/normal的候选完整布线但Setup WNS=-0.833ns，被门槛阻止bit生成；相关报告归档在 `evidence/bmp-scale-failed-cancel5-medium/`。最终使用种子3/high/routability的合格候选。

2026-10-09 后续反馈：用户使用上述media修复bit与原render bit时，Text OSD确认后编辑页未显示；重新烧录最新GUI编译文件后文字菜单恢复。本记录中的CLI配对不再作为Text OSD实板通过依据，后续优先保留用户当前工作版本。详见 [Text OSD恢复记录](text-osd-gui-recovery-2026-10-09.md)。此反馈不自动确认BMP缩放及30分钟轮播验收。
