//=============================================================================
// module : lane_lvds_10_1
// 文件名 : rtl/driver/lane_lvds_10_1.v
// 功  能 : 【物理层】TMDS 10:1 并串转换器（单通道）
//          来源：安路官方 APUG092 HDMI1.4b Transmitter 参考设计同名文件，
//          来源：官方 HDMI 1.4b 参考设计的串化模块。
//          本文件仅补充注释，逻辑与官方完全一致（已在该官方参考设计中
//          于 EG4S20 + TD6.2 上板验证）。
//
// 原理（为什么 5x 时钟 + ODDR 就能做 10:1）：
//   TMDS 每个像素周期要送出 1 个 10bit 字符。串化时钟 = 5 × 像素时钟，
//   EG_LOGIC_ODDR 在串化时钟的上升沿送 d0、下降沿送 d1 —— 每个串化周期
//   送 2 bit，5 个周期正好 10 bit。串行率 = 5 × 2 × 25MHz = 250 Mbps/lane。
//
//   像素域(25M)                串化域(125M)
//   S_odd_even 每像素周期翻转 ──同步2拍──► XOR 检出翻转沿 = S_load_en
//                                              │ 每 5 个串化周期脉冲一次
//                                              ▼
//                          S_load_en_2d=1 : S_shift_data <= I_data_in (10bit 装载)
//                          S_load_en_2d=0 : S_shift_data <= S_shift_data << 2
//                                              │ 每次取最高 2 bit
//                                              ▼
//                                       EG_LOGIC_ODDR ──► O_serial_out
//
//   注意：I_pixel_clk 与 I_serial_clk 必须严格 5 倍频关系（同一 PLL 输出），
//   两个域之间只靠 S_odd_even 这个 1bit "节拍标志" 传递，属于设计刻意为之
//   的跨域结构（配套 SDC 将两时钟声明为 exclusive 组，不做跨域 STA）。
//=============================================================================
module lane_lvds_10_1 #(
    parameter DEVICE = "EG"    // 器件族："EF2"/"EF3"/"EF4"/"SF1"/"EG"/"PH1A"/"PH1P"/"DR1"
    )(
    input  wire      I_pixel_clk,    // 像素时钟（并行域，如 25MHz）
    input  wire      I_serial_clk,   // 串化时钟 = 5 × 像素时钟（如 125MHz）
    input  wire      I_rst,          // 复位，高电平有效（官方接口约定）

    input  wire[9:0] I_data_in,      // 本通道当前像素周期的 10bit TMDS 字符

    output wire      O_serial_out    // 串行输出（接顶层 _P 差分正端，负端由 IO 约束自动生成）
);

    //--------------------------------------------------------------------------
    // ① 像素域节拍：每个像素周期翻转一次，作为"新字符到了"的标志
    //--------------------------------------------------------------------------
    reg      S_odd_even;
    reg      S_odd_even_1d;    // 串化域同步第 1 拍
    reg      S_odd_even_2d;    // 串化域同步第 2 拍
    reg      S_load_en;        // 翻转沿检测 = 装载使能（每像素周期 1 拍）
    reg      S_load_en_1d;
    reg      S_load_en_2d;
    reg[9:0] S_shift_data;     // 移位寄存器：每次左移 2bit，从高位送出
    reg[1:0] S_oddr_data;      // ODDR 输入寄存

    always @(posedge I_pixel_clk or posedge I_rst) begin
        if(I_rst)
            S_odd_even <= 1'b0;
        else
            S_odd_even <= ~S_odd_even;
    end

    //--------------------------------------------------------------------------
    // ② 跨域同步 + 沿检测：翻转标志打两拍后 XOR，得到每像素周期一次的脉冲
    //    （1 拍同步 + 1 拍延迟，XOR = 检出 0→1 或 1→0 的变化沿）
    //--------------------------------------------------------------------------
    always @(posedge I_serial_clk) begin
        S_odd_even_1d <= S_odd_even;
        S_odd_even_2d <= S_odd_even_1d;
    end

    always @(posedge I_serial_clk) begin
        S_load_en    <= S_odd_even_1d ^ S_odd_even_2d;
        S_load_en_1d <= S_load_en;
        S_load_en_2d <= S_load_en_1d;
    end

    //--------------------------------------------------------------------------
    // ③ 10bit 字符装载/移位：装载时整体换新字符，其余时间左移 2bit
    //    （移位后 [9:8] 依次扫过字符的全部 5 对 bit）
    //--------------------------------------------------------------------------
    always @(posedge I_serial_clk or posedge I_rst) begin
        if(I_rst)
            S_shift_data <= 'd0;
        else
            if(S_load_en_2d)
                S_shift_data <= I_data_in;
            else
                S_shift_data <= S_shift_data << 2;
    end

    //--------------------------------------------------------------------------
    // ④ 取最高 2bit 送 ODDR：
    //    ODDR 端口语义（FPGA_Libraries_Guide）：
    //      d0 = 串化时钟上升沿送出的 bit
    //      d1 = 串化时钟下降沿送出的 bit
    //    即每对 bit 中 [9] 先出（上升沿）、[8] 后出（下降沿）。
    //    上层 hdmi_phy 已做过位序反转，保证 TMDS 字符 bit0 最先上线。
    //--------------------------------------------------------------------------
    always @(posedge I_serial_clk) begin
        S_oddr_data <= S_shift_data[9:8];
    end

    //--------------------------------------------------------------------------
    // ⑤ 器件相关 ODDR 原语选择（与上层 DEVICE 参数一致）
    //    EG4（本工程）→ EG_LOGIC_ODDR；未选中的 generate 分支不会参与综合
    //--------------------------------------------------------------------------
    generate
        if(DEVICE == "EF2")
            begin
                EF2_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EF3")
            begin
                EF3_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EF4")
            begin
                EF4_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "SF1")
            begin
                SF1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EG")
            begin
                EG_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "PH1A")
            begin
                PH1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "PH1P")
            begin
                PH1P_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "DR1")
            begin
                DR1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
    endgenerate

endmodule
