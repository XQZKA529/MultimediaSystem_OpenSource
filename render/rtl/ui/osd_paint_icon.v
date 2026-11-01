//=============================================================================
// module : osd_paint_icon
// 文件名 : rtl/ui/osd_paint_icon.v
// 功  能 : 【播放/暂停图标 painter】▶ / ⏸ 两个图标，纯几何绘制、纯组合。
//
//  接口约定：只吃局部坐标 + paused（+1 Hz 方波电平做呼吸）。
//    ★ 没有 pos/total/fill_px 端口 —— 图标与进度完全无关，只反映播放/暂停态。
//
//  为什么不用字库：工程内 5×7 字库没有 ▶/⏸ 这两个图形，而且它们是纯几何
//  形状，用比较+减法几行就能画得比点阵更干净（斜边是连续缩进的）。
//
//  图标盒 28×28：
//    ▶（播放，白色）：三角形，左竖边 x=0 贯穿 ly 1..27，顶点在 (13,14)。
//        第 ly 行的展开量 lim = 13 - |ly-14| ⇒ 中间最宽、上下收尖。
//    ⏸（暂停，浅灰）：两根竖条 x∈[5,11] 与 x∈[17,23]，ly∈[3,24]。
//        暂停时用 1 Hz 方波在"正文色 / 压暗色"之间切换 ⇒ 呼吸感（这就是
//        "播放/暂停的动画反馈"，不需要额外逻辑）。
//=============================================================================
`include "../pkg/osd_model_bus.vh"
module osd_paint_icon #(
    parameter integer ICON_W = 28,
    parameter integer ICON_H = 28
)(
    input  wire [10:0] lx,             // 局部列坐标
    input  wire [10:0] ly,             // 局部行坐标
    input  wire        paused,
    input  wire        blink1,         // 1 Hz 方波电平
    output reg         draw,
    output reg  [2:0]  ink
);

    localparam integer CY = 14;        // 三角形纵向中心

    wire       inbox = (lx < ICON_W[10:0]) && (ly < ICON_H[10:0]);

    //-------------------------------------------------------------------------
    // ▶ 三角：d = |ly - CY|，第 ly 行画到 x = 13 - d
    //-------------------------------------------------------------------------
    wire [10:0] d    = (ly > CY[10:0]) ? (ly - CY[10:0]) : (CY[10:0] - ly);
    wire [10:0] lim  = (d >= 11'd14) ? 11'd0 : (11'd13 - d);
    wire        play_px = inbox && (ly >= 11'd1) && (lx <= lim);

    //-------------------------------------------------------------------------
    // ⏸ 双竖条
    //-------------------------------------------------------------------------
    wire        pause_px = inbox && (ly >= 11'd3) && (ly <= 11'd24) &&
                           (((lx >= 11'd5) && (lx <= 11'd11)) ||
                            ((lx >= 11'd17) && (lx <= 11'd23)));

    always @(*) begin
        if      (!paused && play_px)  begin draw = 1'b1; ink = `OSD_INK_FILL;    end
        else if ( paused && pause_px) begin draw = 1'b1;
                                            ink  = blink1 ? `OSD_INK_TEXT
                                                          : `OSD_INK_TEXTDIM;  end
        else                              begin draw = 1'b0; ink = 3'd0;         end
    end

endmodule
