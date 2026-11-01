//=============================================================================
// glue_video_ctrl — 显示侧诊断码合成 + 按键语义分流（1:1 自 top 搬出）
//
//   err_code_show / err_show : diag_code + frame_black + ui_active → ERROR n
//   key_next_img             : 浏览器打开时吞掉 KEY2，避免移光标又切图
//=============================================================================
module glue_video_ctrl (
    input  wire [3:0]  diag_code,
    input  wire        display_valid,
    input  wire        frame_black,
    input  wire        ui_active,
    input  wire        key2,
    output wire [3:0]  err_code_show,
    output wire        err_show,
    output wire        key_next_img
);

    // Real controller errors take priority even when an older valid frame is
    // still displayed.  Normal loading reports code 15 and stays unobtrusive.
    assign err_code_show = (diag_code != 4'd15) ? diag_code :
                           (display_valid ? (frame_black ? 4'd6 : 4'd15) : 4'd15);
    assign err_show      = (err_code_show != 4'd15) && ~ui_active;

    // 浏览器窗口打开期间 KEY2 只移光标，不切背景图
    assign key_next_img  = ui_active ? 1'b1 : key2;

endmodule
