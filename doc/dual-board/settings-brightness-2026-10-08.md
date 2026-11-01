# 设置菜单、DDC/CI 与全局亮度实现（2026-10-08）

## 修改思路

只修改双板工程。media 复用现有 `file_browser` 的业务状态机、文本 RAM 写口和提交接口，新增一级设置页和亮度页；目录分页、BMP/WAV 解析及加载保持原结构。KEY2 使用独立 `key_click_decode` 在消抖事件之上延迟单击判定，避免双击先移动光标或增加亮度。

render 优先通过 HDMI DDC 的标准 VCP0x10 调节显示器；三次查询/写入/回读失败后，启用最终合成输出的 RGB 缩放。此位置在菜单、诊断、音频 OSD 的下游，属于全局亮度。硬件亮度控制正常时 RGB 为100%，增益只在帧界改变。

默认100%，上下限10%–100%，步长10%。KEY3打开设置菜单，在任何页面关闭全部；选中文件成功后关闭全部。KEY2双击从任意二级页返回一级，保留当前亮度及一级选中项。复位恢复100%，不主动向显示器发送掉电保存指令。

## 文件、状态与具体增删位置

### media 菜单与按键

- `media/rtl/ui/file_browser.v`：在原状态定义之后增加 `S_SETTINGS=12`、`S_BRIGHTNESS=13`、`S_MENU_DRAW=14`；增加 `brightness_level/brightness_mode` 接口。
- 在原按键消抖位置接出KEY2松开事件，新增 `key_click_decode`；KEY4短按在松开时确认，长按抑制确认。
- 增加 `menu_char` 函数，产生英文标题、选项、百分比、十格进度条和实际控制模式。
- 在主 `case` 前增加KEY3全局开关与KEY2双击返回；S_CLOSED原直接打开目录逻辑移到设置页确认。
- 目录和已经提交的加载请求通过 `scan_inflight/load_inflight` 后台收尾。返回后保留目录仲裁权到完成，迟到ACK不关闭一级菜单。后台事务未结束时禁止重新进入浏览器。两类事务互斥，共用31位超时计数器，减少资源占用。
- 新增 `media/rtl/clock/key_click_decode.v`：IDLE / DOWN / WAIT_SECOND / DRAIN，首次松开后300ms才输出单击，第二次稳定按下优先于窗口到期；切页时取消旧手势并吞掉仍按住的释放事件。
- `media/rtl/audio/audio_transport.v`：菜单接管时取消待判定KEY4事件，保留暂停状态，避免菜单打开后触发延迟音频动作。

真实状态定义与双击优先分支：

```verilog
    // Top-level pages share the existing text RAM and write/commit interface.
    localparam S_SETTINGS=4'd12, S_BRIGHTNESS=4'd13, S_MENU_DRAW=4'd14;
    reg [1:0] page; // 0=file browser, 1=settings, 2=brightness
    reg settings_sel;
    reg [8:0] menu_addr;
    reg [1:0] mode_drawn;
    reg gesture_cancel;
    reg scan_inflight,load_inflight;
```

```verilog
                DOWN:if(ev_hold) state<=DRAIN;
                     else if(ev_release) begin count<=LIMIT;state<=WAIT_SECOND;end
                WAIT_SECOND:if(ev_press) begin double_pulse<=1;count<=0;state<=DRAIN;end
                            else if(count<=1) begin single_pulse<=1;count<=0;state<=IDLE;end
                            else count<=count-1'b1;
                DRAIN:if(ev_release || !pressed) state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
```

在主状态机中加入以下两个分支（双击返回在进入此case前处理）：

```verilog
            S_SETTINGS:begin
                if(key_ok_pulse) begin
                    gesture_cancel<=1;
                    if(settings_sel) begin page<=2;menu_addr<=0;draw_return<=S_BRIGHTNESS;state<=S_MENU_DRAW;end
                    else if(!scan_inflight && !load_inflight) begin
                        page<=0;ent_cnt<=0;cur<=0;scan_page_base<=0;cache_page_base<=0;
                        status_kind<=idle_ok ? ST_SCAN:ST_BUSY;state<=S_OPEN_INIT;
                    end
                end else if(key_sel_pulse) settings_sel<=~settings_sel;
            end
            S_BRIGHTNESS:begin
                if(key_ok_pulse && brightness_level>1) begin
                    brightness_level<=brightness_level-1'b1;menu_addr<=0;draw_return<=S_BRIGHTNESS;state<=S_MENU_DRAW;
                end else if(key_sel_pulse && brightness_level<10) begin
                    brightness_level<=brightness_level+1'b1;menu_addr<=0;draw_return<=S_BRIGHTNESS;state<=S_MENU_DRAW;
                end else if(mode_drawn!=brightness_mode) begin
                    menu_addr<=0;draw_return<=S_BRIGHTNESS;state<=S_MENU_DRAW;
                end
            end
```

### DDC/CI 主机与总线归属

- 新增 `render/rtl/driver/ddc_i2c_master.v`：50kHz I²C、0x37地址、逐字节ACK、读末字节NACK、STOP、实际SCL采样、时钟延展、20ms事务超时释放。
- 新增 `render/rtl/driver/ddcci_brightness.v`：250ms启动等待、Get/Set VCP0x10、50ms通信间隔、100ms失败间隔、最多三次失败、5秒再探测；解析校验和、类型、结果、16位最大值和当前值；Set后回读必须匹配目标值。
- 最大值到目标值采用20拍精确除法，避免乘法加常数除法串接成像素时钟长路径。等待期间的新调节请求通过比较最新等级与已确认等级继续处理。
- `render/rtl/driver/hdmi_audio_driver.v`：增加亮度接口，把物理DDC连接至独立主机。旧加密核EDID触发置0，DDC端口与物理引脚隔离。当前固定720p配置没有消费EDID，不存在两个主机并行驱动。
- SCL由output改为inout，SCL/SDA都只驱动0或高阻；输入首先经过两级同步。综合网表已核对第一同步级打包到IO输入寄存器，时钟连接为video_clk，第二级为正常video_clk触发器；综合中的第一输入级虚拟clk告警不代表实际PAD时钟悬空。

物理DDC连接替换片段：

```verilog
    tri1 core_ddc_sda;
    wire ddc_scl_low,ddc_sda_low;
    assign hdmi_ddc_scl=ddc_scl_low ? 1'b0:1'bz;
    assign hdmi_ddc_sda=ddc_sda_low ? 1'b0:1'bz;
    assign edid_trig=1'b0;
    ddcci_brightness u_brightness (
        .clk(pixel_clk),.rst(rst_tx),.level(brightness_level),
        .mode(brightness_mode),.rgb_level(brightness_rgb_level),
        .scl_in(hdmi_ddc_scl),.sda_in(hdmi_ddc_sda),.scl_low(ddc_scl_low),.sda_low(ddc_sda_low)
    );

```

回读校验和选择回退的关键代码：

```verilog
    wire valid_reply=reply[87:80]==8'h6e && reply[79:72]==8'h88 &&
        reply[71:64]==8'h02 && reply[63:56]==0 && reply[55:48]==8'h10 &&
        reply[47:40]==0 && reply_xor==0 && max_value!=0 && current_value<=max_value;
    assign rgb_level=hardware_active ? 4'd10:safe_level;
```

```verilog
                FAILED:begin
                    if(attempts==2) begin
                        hardware_active<=0;mode<=2;attempts<=0;verifying<=0;
                        delay_count<=(CLK_HZ/1000)*REPROBE_MS;next_state<=GET_START;state<=PAUSE;
                    end else begin
                        attempts<=attempts+1'b1;verifying<=0;
                        delay_count<=(CLK_HZ/1000)*RETRY_MS;next_state<=GET_START;state<=PAUSE;
                    end
                end
                default:state<=BOOT;
            endcase
        end
    end
```

### 最终输出全局 RGB 缩放

- 新增 `render/rtl/video/brightness_scale.v`：两拍流水，逐通道 round(rgb*level/10)，100%精确恒等，输入等级越界按100%处理。
- `render/rtl/render_core.v`：替换音频OSD之后的末级 `video_stream_reg` 为亮度模块，RGB/HS/VS/DE始终一起延迟。DDC正常时level=10，回退时使用菜单等级。
- `render/rtl/ui/ui_text_overlay.v`：复用既有提交同步与帧界确认，随UI控制锁存亮度等级。`top_render` / `render_core` / `seam_render` / HDMI驱动传递接口，外部引脚位置不变。

全局合成之后的实际例化位置：

```verilog
    brightness_scale u_pipe_after_ui (
        .level(brightness_rgb_frame),
        .clk(video_clk), .rst(rst_video),
        .hs_in(hs_osd), .vs_in(vs_osd), .de_in(de_osd), .rgb_in(rgb_osd_comb),
        .hs_out(hs), .vs_out(vs), .de_out(de), .rgb_out(rgb)
    );

```

RGB 算术与同步流水：

```verilog
            rp<=({4'd0,rgb_in[23:16]}*{8'd0,safe_level})+12'd5;
            gp<=({4'd0,rgb_in[15:8]} *{8'd0,safe_level})+12'd5;
            bp<=({4'd0,rgb_in[7:0]}  *{8'd0,safe_level})+12'd5;
            h1<=hs_in;v1<=vs_in;d1<=de_in;
            hs_out<=h1;vs_out<=v1;de_out<=d1;
            rgb_out[23:16]<=rp/12'd10;
            rgb_out[15:8]<=gp/12'd10;
            rgb_out[7:0]<=bp/12'd10;
        end
    end
endmodule
```

### 跨板协议、工程及回归入口

- `media/rtl/seam/seam_media.v` 与 `render/rtl/seam/seam_render.v`：UI快照保持292字节，flags[11:8]为等级1..10，零或越界默认10；控制字段在文本复制开始时冻结，复制期间变化则重建。
- 新增返回消息 `DB_BRIGHTNESS_STATUS=0x32`：offset[1:0]为0检测/调节、1硬件回读确认、2RGB回退。状态变化及重握手后重新发送。亮度页显示CHECKING / DISPLAY BRIGHTNESS (DDC) / GLOBAL RGB (FALLBACK)。
- `media/rtl/media_core.v`、`media/rtl/top_media.v` 增加亮度请求及模式连接。
- 两板 `rtl/pkg/board_link.vh` minor升为1，协议说明三份同步更新。
- 两板 `build/sources.txt` 注册新增模块，通过原生TD project脚本更新 `.al`。
- `render/constr/render.sdc` 只切断异步DDC输入到第一采样级的时序检查，内部同步级仍检查时序。
- 仿真脚本和 `tools/dual-board/run-regression.ps1` 注册新增用例，现有双板测试显式连接新增接口。

## 已完成验证

- `tb_key_click`：单击、双击、窗口边界优先级、长按抑制、上下文取消。
- `tb_settings_menu`：消抖、一级选项、进入/返回、数值与进度条、上下限、枚举中返回、仲裁保留、BMP/WAV确认、迟到ACK、扫描与加载互斥、绘制中状态变化、绘制中关闭。
- `tb_audio_transport_gate`：菜单接管取消未决音频手势，原短按/双击/长按与新曲恢复保持。
- `tb_brightness_scale`：全部256通道值、10档及非法等级、舍入、100%恒等、HS/VS/DE对齐。
- `tb_ddcci_brightness`：正常Get/Set/回读、非100及16位范围、调节期间新请求、NACK、坏校验和、不支持VCP、ACK但不执行Set、有限延展、卡死时钟、周期再探测恢复。
- 原UI、SD启动、图片提交、交叉淡化事务测试通过；完整720p双帧读取测试覆盖真实FIFO背压、坐标、刷新与中断恢复。
- 128/4096字图片跨板系统测试包含亮度请求、无文本写入的等级修改与回退模式反馈；单声道与延迟反馈音频联合回归通过。
- 包审计通过：单板基线哈希未改变、两板均仅依赖自身源码、协议说明保持一致。

## 构建与实板边界

render新产物：`render/Runs/phy_settings_brightness/MultimediaSystem_render.bit`，Setup WNS +0.133ns、Hold WNS +0.003ns、无违例，Slice 66.65%、BRAM9K 53。

此前media脚本构建未通过门槛（最后一次Setup WNS +0.062ns，要求≥+0.100ns），门禁阻止bit生成。用户随后通过GUI自行编译并烧录，确认设置菜单与亮度功能正常；未提供对应GUI产物的资源/时序报告，因此功能验收与工具签核分别记录。

2026-10-08用户确认GUI编译、烧录后功能正常；本记录不据此推断所有显示器兼容性。RGB回退缩放整个发送画面，不能改变背光物理功率；若显示器硬件已调暗后DDC中断，RGB缩放作用于其最后保持的硬件设置之上。菜单中的百分比是请求值，DDC模式只有完成匹配回读后才显示已确认。

协议依据：[VESA DDC/CI 1.1](https://glenwing.github.io/docs/VESA-DDCCI-1.1.pdf)。
