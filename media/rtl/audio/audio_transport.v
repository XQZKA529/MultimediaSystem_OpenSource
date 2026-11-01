//=============================================================================
// module : audio_transport
// 文件名 : rtl/audio/audio_transport.v
// 功  能 : 【播放运输控制】把 KEY4 的三种手势翻译成 播放/暂停 / 下一首 / 快进5秒。
//
//  ── 手势定义（仅当"文件浏览器关闭 且 有曲目在播/已暂停"时生效）───────────
//    短按            → 播放 / 暂停 循环切换
//    连续两次短按    → 播放下一首 WAV（并解除暂停）
//    长按（2 s）     → 快进 5 秒（保持当前暂停状态不变）
//    其它情况（浏览器打开、无曲目）→ 全部无效，KEY4 仍是浏览器的"确认选中"
//
//  ── 为什么短按动作要延后 300 ms 才执行（本模块最容易写错的地方）──────────
//    key_debounce 只给"按下/长按"，没有"松开"（本工程已为它补了 release_pulse）。
//    若按下当拍就执行播放/暂停，那么"想双击下一首"的人会先被暂停一次。
//    所以：按下只置 armed；松开才启动双击窗口；窗口内再按一次 = 双击；
//    窗口到期而仍 armed = 短按；中途长按 = 快进并抑制短按（hold_seen）。
//    代价是播放/暂停有约 DBL_WIN_MS 的手感延迟 —— 这是双击判定的必然代价。
//
//  ── 低耦合 ─────────────────────────────────────────────────────────────
//    · 只认"是否在播"这一个状态位，不知道 SD/FAT/文件/音频数据通路的存在。
//    · 输出三个语义动作（pause 电平 / next 脉冲 / seek 脉冲），由顶层分派。
//    · 只吃"帧/秒"级语义，不做任何字节换算（那是 fat_wav_controller 的事）。
//    · 换输入设备（触摸/编码器）只需换事件提供者，本 FSM 不动。
//=============================================================================
module audio_transport #(
    parameter integer CLK_FREQ_HZ = 100_000_000,   // sd_card_clk
    parameter integer DBL_WIN_MS  = 300            // 双击判定窗口
)(
    input  wire clk,
    input  wire rst,               // 高有效（工程统一约定）

    // ---- 上下文 ----
    input  wire i_playing,         // 1 = 有曲目在播/已暂停（= ~wav_play_idle）
    input  wire i_ui_active,       // 1 = 文件浏览器窗口打开（此时本模块完全让位）
    input  wire i_new_track,       // 1 拍：选曲/换曲请求（含浏览器确认与下一首）
    input wire i_restore_pause,i_restore_value,

    // ---- 按键事件（来自 key_debounce，均为单拍脉冲）----
    input wire action_pause,action_next,
    input  wire ev_press,
    input  wire ev_release,
    input  wire ev_hold,

    // ---- 语义动作 ----
    output reg  o_pause,           // 电平：1 = 暂停
    output reg  o_next_req,        // 1 拍：播放下一首
    output reg  o_seek_fwd         // 1 拍：快进 SEEK_STEP 秒
);

    localparam [31:0] DBL_LIMIT = (CLK_FREQ_HZ/1000)*DBL_WIN_MS;

    reg        armed;          // 有一次"待判定"的短按
    reg        hold_seen;      // 本次按下已判为长按（抑制短按动作）
    reg [31:0] win;            // 双击窗口倒计时（0 = 无窗口）

    wire gate = i_playing && !i_ui_active;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            armed     <= 1'b0;
            hold_seen <= 1'b0;
            win       <= 32'd0;
            o_pause   <= 1'b0;
            o_next_req<= 1'b0;
            o_seek_fwd<= 1'b0;
        end else begin
            o_next_req <= 1'b0;
            o_seek_fwd <= 1'b0;

            // 选曲/换曲即恢复播放（新曲/新位置总是从"播放"开始）
            if (i_new_track) o_pause <= 1'b0;

            // 窗口倒计时
            if (win != 32'd0) win <= win - 32'd1;

            //-----------------------------------------------------------------
            // 手势优先级链（同一拍只可能命中一条：三种事件互斥）
            //-----------------------------------------------------------------
            if(action_next && gate) begin o_next_req<=1;armed<=0;win<=0;end
            else if(action_pause && gate) begin o_pause<=~o_pause;armed<=0;win<=0;end
            else if (!gate || i_new_track) begin
                armed<=1'b0;hold_seen<=1'b0;win<=32'd0;
            end else if (ev_press && gate && armed && (win != 32'd0)) begin
                // 双击 → 下一首
                o_next_req <= 1'b1;
                armed      <= 1'b0;
                win        <= 32'd0;
            end else if (ev_press && gate) begin
                // 首次按下：先挂起，等松开/长按/第二按来判断手势
                armed     <= 1'b1;
                hold_seen <= 1'b0;
                win       <= 32'd0;
            end else if (ev_hold && armed) begin
                // 长按 → 快进 5 秒，并抑制短按动作
                o_seek_fwd <= 1'b1;
                armed      <= 1'b0;
                hold_seen  <= 1'b1;
                win        <= 32'd0;
            end else if (ev_release && armed && !hold_seen) begin
                // 松开：启动双击窗口
                win <= DBL_LIMIT;
            end else if ((win == 32'd1) && armed) begin
                // 窗口到期仍待判定 ⇒ 短按 = 播放/暂停翻转
                o_pause <= ~o_pause;
                armed   <= 1'b0;
            end
            if(i_restore_pause===1'b1) begin
                o_pause<=i_restore_value;armed<=0;hold_seen<=0;win<=0;
            end
        end
    end

endmodule
