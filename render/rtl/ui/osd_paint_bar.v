//=============================================================================
// module : osd_paint_bar
// 文件名 : rtl/ui/osd_paint_bar.v
// 功  能 : 【进度条 painter】虚线轨道 + 实心已播 + 播放头。纯组合、无状态。
//
//  接口约定（"高内聚"的关键）：只吃两样东西 —— 局部坐标 + 已播像素列数。
//    ★ 它没有 level / beat / paused / 任何 sd 域信号的端口，也拿不到 total：
//      填充量已经在语义层算成"像素数"了（样本轴 DDA，见 audio_osd_status），
//      本模块只做几何映射。换条形（线性→环形/波形）只需重写本文件。
//
//  ★ 禁止在本文件引入乘法/除法/除法器：它位于 75 MHz 像素路径上，只允许
//    比较、移位与 mux。当前实现只有比较 + 移位。
//
//  局部坐标安全约定：调用方可以直接给 x_cnt-ORIGIN 这种"越界会回绕成很大值"
//  的减法结果，本模块用 (lx < W) && (ly < H) 自行判界 —— 回绕值必然 ≥ W，
//  所以越界一定被拒，不需要调用方额外加门控。
//
//  行结构（高 H=16）：
//    播放头  ly 2..13   （2 px 宽，跨过填充边界）
//    实心块  ly 4..11   （8 px 高）
//    虚线轨道 ly 7..8   （居中 2 px，2 亮 2 暗）
//=============================================================================
`include "../pkg/osd_model_bus.vh"
module osd_paint_bar #(
    parameter integer BAR_W = 340,     // 条宽（像素）
    parameter integer BAR_H = 16       // 条高（像素）
)(
    input  wire [10:0] lx,             // 局部列坐标（左上角为 0）
    input  wire [10:0] ly,             // 局部行坐标（左上角为 0）
    input  wire [9:0]  fill_px,        // 已播像素列数 0..BAR_W（语义层已钳位）
    output reg         draw,
    output reg  [2:0]  ink
);

    //-------------------------------------------------------------------------
    // 判界 + 填充量二次钳位（对参数被改错也安全）
    //-------------------------------------------------------------------------
    wire       inbox = (lx < BAR_W[10:0]) && (ly < BAR_H[10:0]);
    wire [10:0] f    = (fill_px > BAR_W) ? BAR_W[10:0] : {1'b0, fill_px};

    // 播放头落在"第一个未填充列"；填满时钉在最后一列；f=0 时钉在第 0 列
    wire [10:0] hx = (f >= BAR_W[10:0]) ? (BAR_W[10:0] - 11'd1) : f;

    //-------------------------------------------------------------------------
    // 三种笔画（优先级：头 > 实心 > 虚线轨道）
    //-------------------------------------------------------------------------
    wire is_head  = inbox && (ly >= 11'd2) && (ly <= 11'd13) &&
                    ((lx == hx) || (lx + 11'd1 == hx));
    wire is_fill  = inbox && (ly >= 11'd4) && (ly <= 11'd11) && (lx < f);
    wire is_track = inbox && (ly >= 11'd7) && (ly <= 11'd8) &&
                    (((lx >> 1) & 11'd1) == 11'd0);   // 2 亮 2 暗

    always @(*) begin
        if (is_head) begin
            draw = 1'b1;  ink = `OSD_INK_HEAD;
        end else if (is_fill) begin
            draw = 1'b1;  ink = `OSD_INK_FILL;
        end else if (is_track) begin
            draw = 1'b1;  ink = `OSD_INK_TRACK;
        end else begin
            draw = 1'b0;  ink = 3'd0;
        end
    end

endmodule
