//=============================================================================
// module : osd_timebase
// 文件名 : rtl/ui/osd_timebase.v
// 功  能 : 【OSD 时间基准】产生与音频无关的通用节拍，供动画/闪烁使用。
//
//  输出：
//    o_tick4  4 Hz 单拍脉冲（节拍动画每 250 ms 移一相）
//    o_tick1  1 Hz 单拍脉冲（上位机每秒刷新一次时间文本用）
//    o_lvl1   1 Hz 方波电平（0.5 s 高 / 0.5 s 低；暂停呼吸/闪烁要的是电平，
//             不能拿 1 拍脉冲去选颜色——那样只会闪 1 个像素周期）
//
//  为什么单独成文件：它是"动画可替换"的公共节拍源。将来加淡入淡出、闪烁提示
//  都从这里取节拍，不必各自造计数器；本模块与音频、与进度、与像素全无关系，
//  TB 里只要数时钟就能完整验证。
//=============================================================================
module osd_timebase #(
    parameter integer CLK_FREQ_HZ = 75_000_000,
    parameter integer TICK4_HZ    = 4,
    parameter integer TICK1_HZ    = 1
)(
    input  wire video_clk,
    input  wire rst,            // 高有效
    output reg  o_tick4,
    output reg  o_tick1,
    output reg  o_lvl1
);

    localparam [31:0] D4 = CLK_FREQ_HZ / TICK4_HZ;   // 18750000 @75MHz
    localparam [31:0] D1 = CLK_FREQ_HZ / TICK1_HZ;   // 75000000 @75MHz
    localparam [31:0] DH = D1 / 2;                   // 半周期 → 1 Hz 方波

    reg [31:0] c4, c1;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            c4 <= 32'd0;
            c1 <= 32'd0;
            o_tick4 <= 1'b0;
            o_tick1 <= 1'b0;
            o_lvl1  <= 1'b0;
        end else begin
            o_tick4 <= 1'b0;
            o_tick1 <= 1'b0;

            if (c4 >= D4 - 32'd1) begin
                c4      <= 32'd0;
                o_tick4 <= 1'b1;
            end else c4 <= c4 + 32'd1;

            if (c1 >= D1 - 32'd1) begin
                c1      <= 32'd0;
                o_tick1 <= 1'b1;
            end else c1 <= c1 + 32'd1;

            // 方波电平：每半周期翻转一次
            if (c1 == DH - 32'd1)
                o_lvl1 <= ~o_lvl1;
        end
    end

endmodule
