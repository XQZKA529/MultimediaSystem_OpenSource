//=============================================================================
// mix_alpha_ctrl.v — 交叉淡化 α 推进器（阶段 2）
//
// 职责：在帧边界（vs 上升沿）把 α 从 0 推进到 256，30 个帧间隔走完。
//   第 k 步（k=1..30）取 α = round(256*k/30)，端点精确：
//     k=0  → 0   （第一帧，纯旧图）
//     k=30 → 256 （第三十帧，纯新图）
//
// 语义：
//   * start 脉冲（在帧边界被上层拉一拍）开始一次淡化；
//   * 之后每个帧边界推进一档，共 30 档；
//   * 到达 256 后 busy 落低，直到下一次 start。
//   * fail 脉冲立即终止本次淡化（欠载等），busy 落低、α 归 0；
//     上层据此回到旧图单路扫描。
//
// 乘法表用组合查表实现（30 项常量），避免在视频域引入除法器/乘法器。
//=============================================================================
`default_nettype none
module mix_alpha_ctrl (
    input  wire        clk,
    input  wire        rst,
    input  wire        vs,              // 视频帧同步（上升沿为帧边界）
    input  wire        start,           // 帧边界请求启动淡化
    input  wire        fail,            // 本帧混合失败（欠载/错位）

    output reg  [8:0]  alpha,           // 当前系数 0..256
    output reg         busy,            // 淡化进行中
    output reg         done,            // 本帧刚到达 α=256（单拍脉冲）
    output reg  [4:0]  progress_step
);
    localparam integer STEPS = 30;
    reg [4:0] step;                     // 0..30

    // round(256*k/30)，k=0..30，组合查表
    function [8:0] alpha_of;
        input [4:0] k;
        begin
            case (k)
                5'd0 : alpha_of = 9'd0;
                5'd1 : alpha_of = 9'd9;
                5'd2 : alpha_of = 9'd17;
                5'd3 : alpha_of = 9'd26;
                5'd4 : alpha_of = 9'd34;
                5'd5 : alpha_of = 9'd43;
                5'd6 : alpha_of = 9'd51;
                5'd7 : alpha_of = 9'd60;
                5'd8 : alpha_of = 9'd68;
                5'd9 : alpha_of = 9'd77;
                5'd10: alpha_of = 9'd85;
                5'd11: alpha_of = 9'd94;
                5'd12: alpha_of = 9'd102;
                5'd13: alpha_of = 9'd111;
                5'd14: alpha_of = 9'd119;
                5'd15: alpha_of = 9'd128;
                5'd16: alpha_of = 9'd137;
                5'd17: alpha_of = 9'd145;
                5'd18: alpha_of = 9'd154;
                5'd19: alpha_of = 9'd162;
                5'd20: alpha_of = 9'd171;
                5'd21: alpha_of = 9'd179;
                5'd22: alpha_of = 9'd188;
                5'd23: alpha_of = 9'd196;
                5'd24: alpha_of = 9'd205;
                5'd25: alpha_of = 9'd213;
                5'd26: alpha_of = 9'd222;
                5'd27: alpha_of = 9'd230;
                5'd28: alpha_of = 9'd239;
                5'd29: alpha_of = 9'd247;
                default: alpha_of = 9'd256;   // k=30
            endcase
        end
    endfunction

    reg vs_d;
    wire frame_edge = vs & ~vs_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            vs_d  <= 1'b0;
            step  <= 5'd0;
            alpha <= 9'd0;
            busy  <= 1'b0;
            done  <= 1'b0;
            progress_step <= 5'd0;
        end else begin
            vs_d <= vs;
            done <= 1'b0;

            if (fail) begin
                // 立即终止：回到旧图单路
                step  <= 5'd0;
                alpha <= 9'd0;
                busy  <= 1'b0;
                progress_step <= 5'd0;
            end else if (start && !busy) begin
                // 启动：本帧仍输出 α=0（纯旧图），下一帧边界才推进
                step  <= 5'd0;
                alpha <= 9'd0;
                busy  <= 1'b1;
                progress_step <= 5'd0;
            end else if (busy && frame_edge) begin
                if (step >= STEPS-1) begin
                    alpha <= 9'd256;
                    progress_step <= 5'd30;
                    busy <= 1'b0;          // endpoint frame starts now
                    done <= 1'b1;
                end else begin
                    step  <= step + 5'd1;
                    alpha <= alpha_of(step + 5'd1);
                    progress_step <= step + 5'd1;
                end
            end
        end
    end
endmodule
`default_nettype wire
