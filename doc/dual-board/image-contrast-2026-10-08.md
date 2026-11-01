# 图片对比度设置与独立像素模块（2026-10-08）

用户已确认前一轮设置菜单与亮度功能经GUI编译、烧录后正常。本轮新增图片对比度，尚未上板；仅双板工程有改动，根目录单板基线保持原样。

## 修改思路与操作

设置菜单依次为FILE BROWSER、BRIGHTNESS、CONTRAST。KEY2单击循环选项、KEY4短按进入；对比度页KEY2单击+10%、KEY4短按-10%，0%–200%、默认100%；KEY2双击保留并返回，KEY3关闭全部。百分比和20格进度条表示当前值；运行期间跨切图/关闭/重连保留，复位恢复100%。

算法独立于UI/协议/存储，作用于交叉淡化后的RGB888流，不修改SDRAM原图，也不控制显示器硬件对比度。信号路径为：

```text
双路图片读取 → 交叉淡化 → contrast_adjust（三拍）
→ 诊断叠加 → 设置菜单 → 音频OSD → 全局亮度 → HDMI/VGA
```

因此对比度不改变任何叠加文字；原有亮度仍可以改变最终整个画面。交叉淡化后的图片也使用当前对比度。无图时禁用处理，保持黑底。

## 菜单状态及增删位置

`media/rtl/ui/file_browser.v`的状态定义区增加`S_CONTRAST=4'd15`；现有4位状态宽度足够。`page=3`表示对比度，`settings_sel`由1位改为2位，光标行改为`2+settings_sel`。端口增加5位`contrast_level`，复位值10。设置页渲染增加第4行CONTRAST，并在共享`menu_char`中绘制独立对比度页。

原先两项之间翻转选择，替换为三项循环：

```verilog
else if(key_sel_pulse)
    settings_sel<=(settings_sel==2) ? 2'd0:(settings_sel+1'b1);
```

在`S_BRIGHTNESS`之后增加：

```verilog
S_CONTRAST:begin
    if(key_ok_pulse && contrast_level>0) begin
        contrast_level<=contrast_level-1'b1;
        menu_addr<=0;draw_return<=S_CONTRAST;state<=S_MENU_DRAW;
    end else if(key_sel_pulse && contrast_level<20) begin
        contrast_level<=contrast_level+1'b1;
        menu_addr<=0;draw_return<=S_CONTRAST;state<=S_MENU_DRAW;
    end
end
```

已有全局KEY2双击返回分支覆盖新页，不额外实现手势计时器；KEY2单击仍延后到300ms窗口结束，双击不会先触发增加。亮度范围和文件加载语义保持原状。

## 独立模块与未来视频接口

新增`render/rtl/video/contrast_adjust.v`，接口为：

```verilog
module contrast_adjust #(parameter VS_ACTIVE_HIGH=1'b1)(
    input wire clk,rst,
    input wire cfg_valid,input wire [4:0] cfg_level,
    input wire enable,
    input wire hs_in,vs_in,de_in,input wire [23:0] rgb_in,
    output reg hs_out,vs_out,de_out,output reg [23:0] rgb_out
);
```

- `clk/rst`：像素时钟与高有效复位；配置和像素均属于此时钟域。
- `cfg_valid/cfg_level`：单拍提交等级0..20；非法等级按10处理。最新配置替换待生效配置，VS有效脉冲结束时应用。若提交与脉冲结束同拍，则使用该次新值；未收到帧界前保留原值。
- `enable`：该输入像素是否应用对比度；0时等效100%，仍走完整三拍流水。上层无图时置0。
- `RGB888/HS/VS/DE`：连续扫描、每拍一个像素，无ready反压。三拍延迟在所有等级及禁用状态下固定；不依赖分辨率。低有效VS可设置参数0。

每个通道精确计算：

```text
floor(((c - 128) * level + 1280 + 5) / 10)，饱和到0..255
```

第一级计算有符号15位乘积，第二级加中灰和舍入偏置并钳位到0..2550，第三级对正数作常数除10。100%逐像素恒等，0%为128中灰；没有Gamma变换或RGB转亮度空间。高对比度饱和属于预期行为。

未来视频解码器输出RGB888后，可以直接串接此模块并同步提交配置；无需引用菜单状态机、BMP解析或本次板间协议。不包含视频解码、帧缓存和传输带宽设计。

## 输出链路及跨板接口

`render/rtl/render_core.v`在`rgb_base`定义之后、`error_overlay`实例之前加入：

```verilog
reg contrast_commit_seen;
always @(posedge video_clk or posedge rst_video)
    if(rst_video) contrast_commit_seen<=0;
    else contrast_commit_seen<=ui_commit_seen;
contrast_adjust u_contrast_adjust (
    .clk(video_clk),.rst(rst_video),
    .cfg_valid(ui_commit_seen!=contrast_commit_seen),.cfg_level(contrast_level),
    .enable(display_valid || mix_active),
    .hs_in(hs_mix),.vs_in(vs_mix),.de_in(de_mix),.rgb_in(rgb_base),
    .hs_out(hs_contrast),.vs_out(vs_contrast),.de_out(de_contrast),
    .rgb_out(rgb_contrast)
);
```

随后将诊断模块输入从`hs_mix/vs_mix/de_mix/rgb_base`改接四个对比度输出。全局亮度实例保持原来的下游位置。

UI消费者在VS上升沿确认完整页面，配置模块在同一垂直消隐的VS结束处应用参数，下一帧图片与菜单值一致。`contrast_level`来自稳定的快照邮箱，在UI确认返送至网络域前完成采样；像素模块本身不承担跨时钟同步。

`media_core/top_media/seam_media`和`seam_render/top_render/render_core`增加5位等级连线。`UI_SNAPSHOT`仍为292字节，在32位flags的[20:16]放等级、bit21放存在标记；缺标记或等级>20按100%，合法0明确表示0%。复制开始冻结完整32位控制字段，复制期间控制变化则重建。部分页面断线不改变已提交等级，重连重发当前值。

两板`rtl/pkg/board_link.vh`的minor改为2，无新增操作码；三份协议说明同步。`render/build/sources.txt`加入模块，使用TD原生project脚本更新`.al`，GUI重新打开工程后Reset Syn/Phy再Run；当前render工程已通过TD原生API保存布局种子4。

## 验证

- `tb_contrast_adjust`：256个通道输入×21档、不同RGB值、饱和/舍入、100%恒等、非法等级、禁用、固定三拍时序、VS两种极性、帧中更新/最新值/帧界同拍更新、运行中复位。共检查7210个有效像素。
- `tb_settings_menu`：三项循环、0/200%钳位、百分比/进度条、双击无单击副作用、返回与关闭保留；原目录仲裁、BMP/WAV和迟到ACK场景仍通过。
- `tb_image_contrast`：用真实诊断、文字菜单和音频OSD检查76800个输出像素；0/200/60%只改变图片，全部叠加像素与100%基准相同；无图保留黑底；UI提交后第一帧生效。
- `tb_ui_snapshot`：旧快照、存在标记、非法21/31、合法0/20、部分页面断线及新页面提交。
- `tb_system`：两份实际链路实现，128/4096字图片，亮度/对比度无文本写入更新，以及断线期间改参数、重连重发。
- 回归原按键、音频手势、SD启动、图片提交、UI显示、亮度/DDC、交叉淡化与音频延迟反馈；日志在各板`build/evidence/`和`doc/dual-board/evidence/`。

新增测试已注册到仿真脚本和联合回归入口。包审计确认单板基线未改动、两板仅依赖本目录源码、协议副本一致。

```powershell
./media/sim/run.ps1 -Test tb_settings_menu
./render/sim/run.ps1 -Test tb_contrast_adjust
./render/sim/run.ps1 -Test tb_image_contrast
./render/sim/run.ps1 -Test tb_ui_snapshot
./tools/dual-board/run-system.ps1 -FrameWords 4096
```

## 原生构建与上板

GUI入口为`media/MultimediaSystem_media.al`和`render/MultimediaSystem_render.al`，使用完整功能工程；需要同时更新两板。关闭旧工程窗口并重新打开，Reset Syn/Phy后Run。本轮media使用种子1，render使用种子4；当前render原生工程已保存种子4。`-Stage project`会恢复脚本的通用种子1，重新生成项目后需在GUI中将render布局种子设为4，或使用下面显式指定种子的完整构建命令。

```powershell
./media/build/run.ps1 -Stage all -RunTag contrast
./render/build/run.ps1 -Stage all -RunTag contrast_s4 -PlaceSeed 4
```

脚本继续要求Setup WNS≥0.100ns、Setup/Hold均无违例、Slice≤80%、BRAM9K≤56；不通过时阻止bit生成。首次render布局结果Setup WNS−0.552ns、Hold WNS+0.003ns、Slice67.94%、BRAM9K53，未生成bit。资源和时序验收与实板功能验收分别记录，本轮尚未烧录硬件。


最终合格配对如下，两个脚本均成功退出，且输入指纹核验通过：

| 板 | bit路径 | Setup WNS | Hold WNS | Slice | BRAM9K | DSP | 种子 |
|---|---|---:|---:|---:|---:|---:|---:|
| media | `media/Runs/phy_contrast/MultimediaSystem_media.bit` | +0.106ns | +0.003ns | 79.15% | 50 | 4 | 1 |
| render | `render/Runs/phy_contrast_s4/MultimediaSystem_render.bit` | +0.121ns | +0.003ns | 67.88% | 53 | 12 | 4 |

两板Setup/Hold TNS均为0、无违例，满足原有全部门槛。使用面积优先映射、高强度物理优化与routability布线。对比度模块未成为最终时序关键路径；未修改原SDRAM读调度或诊断算法。其他布局及自动映射试编译未签核，不属于交付产物。

SHA256：

```text
media  62f8e124fbe98167040ef8c801943f667d5e7bed320481ae7d027ce70c4f1ace
render 141725db99ebb805532a1197d6d3ccb6277be35fe0e9accd477e720ab68c877c
```

签核结果另存`doc/dual-board/evidence/contrast-qualification.json`。`Runs/`为本机构建产物，不纳入Git。当前实板结论仅适用于用户确认的上一轮亮度版本，本轮对比度仍需烧录上述配对后验证。
