// Four-phase held request/result mailbox; reader retirement is acknowledged.
`default_nettype none
module mix_transition_ctrl (
    input  wire        clk,             // video_clk
    input  wire        rst,             // video_rst
    input wire restore_req,restore_valid,input wire [1:0] restore_index,
    output reg restore_done,
    input  wire        vs,              // 视频帧同步

    // ---- 网络域请求邮箱（保持稳定）----
    input  wire        transition_req,  // 电平：请求一次切换
    input  wire [1:0]  req_new_idx,     // 新图缓存索引
    input  wire [1:0]  req_cur_idx,     // 请求时正在显示的缓存索引
    input  wire [1:0]  req_mode,
    output reg         req_ack,         // 已接受，保持至请求撤销

    // ---- 视频域动画接口 ----
    output reg         mix_active,      // 动画进行中（禁写两张缓存）
    output reg         lane1_en,        // 本帧读第二路
    output reg  [1:0]  lane1_idx,       // 第二路（新图）缓存索引
    output reg         alpha_start,     // 启动 α 推进（单拍）
    output reg  [1:0]  active_mode,
    input  wire [8:0]  alpha,           // 当前 α
    input  wire        alpha_busy,      // α 推进中
    input  wire        alpha_done,      // α 已到 256（单拍）
    input  wire        read_handoff,
    input  wire [1:0]  read_index,
    input  wire        read_dual_active,
    input  wire        mix_fail_in,     // 本帧混合失败（欠载/错位）

    // ---- 显示选择（帧边界提交，接回到 seam_render 的 display_index）----
    output reg  [1:0]  disp_index_out,  // 新图成为当前显示索引
    output reg         disp_valid_out,

    // ---- 完成反馈 ----
    output reg         transition_done, // 成功，保持至请求撤销
    output reg         transition_failed// 失败，保持至请求撤销（保留旧图）
);

    localparam T_IDLE=0,T_WAIT=1,T_FADE=2,T_FULL=3,T_RETIRE=4,T_REPORT=5,T_RECOVER=6,T_RESTORE=7;
    reg [2:0] st;
    reg [1:0] new_idx,old_idx;
    reg [5:0] random_index;
    reg vs_d,read_d,failed;
    wire frame_edge=vs && !vs_d;
    wire read_edge=read_handoff!=read_d;
    function [1:0] random_mode;
        input [5:0] index;
        begin case(index)
            // Fixed balanced table: 22 Fade, 21 Slide, 21 Grid entries.
            // It is decoded as small logic and needs no random-number core.
            6'd0:random_mode=1;
            6'd1:random_mode=2;
            6'd2:random_mode=1;
            6'd3:random_mode=0;
            6'd4:random_mode=1;
            6'd5:random_mode=2;
            6'd6:random_mode=2;
            6'd7:random_mode=2;
            6'd8:random_mode=0;
            6'd9:random_mode=0;
            6'd10:random_mode=0;
            6'd11:random_mode=1;
            6'd12:random_mode=0;
            6'd13:random_mode=2;
            6'd14:random_mode=0;
            6'd15:random_mode=1;
            6'd16:random_mode=2;
            6'd17:random_mode=0;
            6'd18:random_mode=0;
            6'd19:random_mode=0;
            6'd20:random_mode=2;
            6'd21:random_mode=1;
            6'd22:random_mode=1;
            6'd23:random_mode=0;
            6'd24:random_mode=1;
            6'd25:random_mode=1;
            6'd26:random_mode=1;
            6'd27:random_mode=1;
            6'd28:random_mode=2;
            6'd29:random_mode=2;
            6'd30:random_mode=2;
            6'd31:random_mode=2;
            6'd32:random_mode=1;
            6'd33:random_mode=0;
            6'd34:random_mode=0;
            6'd35:random_mode=0;
            6'd36:random_mode=0;
            6'd37:random_mode=0;
            6'd38:random_mode=0;
            6'd39:random_mode=1;
            6'd40:random_mode=1;
            6'd41:random_mode=0;
            6'd42:random_mode=2;
            6'd43:random_mode=2;
            6'd44:random_mode=2;
            6'd45:random_mode=1;
            6'd46:random_mode=2;
            6'd47:random_mode=0;
            6'd48:random_mode=0;
            6'd49:random_mode=2;
            6'd50:random_mode=2;
            6'd51:random_mode=2;
            6'd52:random_mode=2;
            6'd53:random_mode=1;
            6'd54:random_mode=0;
            6'd55:random_mode=1;
            6'd56:random_mode=1;
            6'd57:random_mode=0;
            6'd58:random_mode=1;
            6'd59:random_mode=1;
            6'd60:random_mode=0;
            6'd61:random_mode=2;
            6'd62:random_mode=1;
            6'd63:random_mode=2;
        endcase end
    endfunction
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            st<=T_IDLE;new_idx<=0;old_idx<=0;active_mode<=0;random_index<=0;vs_d<=0;read_d<=0;failed<=0;
            req_ack<=0;mix_active<=0;lane1_en<=0;lane1_idx<=0;alpha_start<=0;
            disp_index_out<=0;disp_valid_out<=0;transition_done<=0;transition_failed<=0;
            restore_done<=0;
        end else begin
            vs_d<=vs;read_d<=read_handoff;alpha_start<=0;
            case(st)
                T_IDLE:if(restore_req===1'b1) begin
                    if(frame_edge) begin
                        disp_index_out<=restore_index;disp_valid_out<=restore_valid;
                        restore_done<=!restore_valid;st<=T_RESTORE;
                    end
                end else if(transition_req) begin
                    new_idx<=req_new_idx;old_idx<=disp_index_out;
                    active_mode<=!disp_valid_out ? 2'd0:(req_mode==2'd3 ? random_mode(random_index):
                                 (req_mode<=2'd2 ? req_mode:2'd0));
                    if(disp_valid_out && req_mode==2'd3) random_index<=random_index+1'b1;
                    req_ack<=1;failed<=0;st<=T_WAIT;
                end
                T_WAIT:if(frame_edge) begin
                    lane1_idx<=new_idx;lane1_en<=1;mix_active<=1;alpha_start<=1;st<=T_FADE;
                end
                T_FADE:begin
                    if(mix_fail_in) begin failed<=1;st<=T_RECOVER;end
                    else if(alpha_done) st<=T_FULL;
                end
                T_FULL:begin
                    if(mix_fail_in) begin failed<=1;st<=T_RECOVER;end
                    else if(frame_edge) begin
                        disp_index_out<=new_idx;disp_valid_out<=1;lane1_en<=0;st<=T_RETIRE;
                    end
                end
                T_RETIRE:if(read_edge && read_index==new_idx && !read_dual_active) begin
                    mix_active<=0;transition_done<=1;st<=T_REPORT;
                end
                T_RECOVER:begin
                    // Keep both buffers protected until the old single reader
                    // has actually replaced the dual reader at a frame boundary.
                    if(frame_edge) lane1_en<=0;
                    if(read_edge && read_index==old_idx && !read_dual_active) begin
                        mix_active<=0;transition_failed<=1;st<=T_REPORT;
                    end
                end
                T_REPORT:if(!transition_req) begin
                    req_ack<=0;transition_done<=0;transition_failed<=0;st<=T_IDLE;
                end
                T_RESTORE:begin
                    if(read_index==restore_index && !read_dual_active) restore_done<=1;
                    if(!restore_req) begin restore_done<=0;st<=T_IDLE;end
                end
                default:st<=T_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
