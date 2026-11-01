//=============================================================================
// module : key_debounce
// 文件名 : rtl/clock/key_debounce.v
// 功  能 : 按键消抖 + 可选长按（fat_bmp_controller / file_browser / audio_transport 共用）
//
//  按下沿稳定 DEBOUNCE_MS 后出 1 拍 press_pulse；
//  松开沿稳定 DEBOUNCE_MS 后出 1 拍 release_pulse（与 press_pulse 对称）；
//  稳定按下持续 HOLD_MS 后出 1 拍 hold_pulse（未用可悬空）。一次长按
//  只会出一次 hold_pulse（靠 hold_done 锁存，松开才复位），不周期重复。
//  按钮低有效（板载 KEY 常态高）。
//
//  release_pulse 的用途：区分"短按 / 连按两次 / 长按"这三种手势。只有
//  press_pulse 时无法判断"第二次按下"是双击，因为不知道第一次何时松开；
//  audio_transport 用 release_pulse 起双击窗口。不需要的例化点把该口悬空即可
//  （Verilog 允许输出端口不接，现有 5 处例化无需改动）。
//=============================================================================
module key_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 50,
    parameter integer HOLD_MS     = 2000
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,
    output reg  press_pulse,
    output reg  release_pulse,
    output reg  hold_pulse
);
    localparam integer D_LIMIT = (CLK_FREQ_HZ/1000)*DEBOUNCE_MS;
    localparam integer H_LIMIT = (CLK_FREQ_HZ/1000)*HOLD_MS;

    reg s0, s1, stable;
    localparam D_BITS=D_LIMIT>1 ? $clog2(D_LIMIT):1;
    localparam H_BITS=H_LIMIT>1 ? $clog2(H_LIMIT):1;
    localparam COUNTER_CHUNK=4;
    localparam H_CHUNKS=(H_BITS+COUNTER_CHUNK-1)/COUNTER_CHUNK;
    localparam H_CARRY_BITS=H_CHUNKS>1 ? H_CHUNKS-1:1;
    reg [D_BITS-1:0] cnt;
    reg [H_BITS-1:0] hold_cnt;
    reg [H_CARRY_BITS-1:0] hold_cnt_carry;
    reg        hold_done;
    // Predict the terminal count on the preceding increment. The wide
    // equality now feeds one local FF instead of every counter/carry update.
    // Reset/release/completion keep the prediction aligned with hold_cnt.
    wire hold_last;
    generate if(H_LIMIT<=1) begin: g_short_hold
        assign hold_last=(H_LIMIT==1);
    end else begin: g_hold_terminal
        reg last;
        always @(posedge clk or posedge rst)
            if(rst) last<=1'b0;
            else if(stable==1'b0 && !hold_done && !last) last<=(hold_cnt==H_LIMIT-2);
            else last<=1'b0;
        assign hold_last=last;
    end endgenerate


    // Keep wide free-running increments out of one long carry chain. The
    // fixed-size chunks are still a cycle-exact binary increment; lower-bit
    // all-ones tests feed each higher chunk in parallel.
    wire [D_BITS-1:0] cnt_inc;
    wire [H_BITS-1:0] hold_cnt_inc;
    genvar dseg, hseg;
    generate
        for (dseg=0; dseg<D_BITS; dseg=dseg+COUNTER_CHUNK) begin: g_debounce_inc
            localparam integer W=(D_BITS-dseg>=COUNTER_CHUNK)?COUNTER_CHUNK:(D_BITS-dseg);
            if (dseg==0) begin: g_low
                assign cnt_inc[dseg +: W]=cnt[dseg +: W]+{{(W-1){1'b0}},1'b1};
            end else begin: g_high
                assign cnt_inc[dseg +: W]=cnt[dseg +: W]+{{(W-1){1'b0}},(&cnt[dseg-1:0])};
            end
        end
        for (hseg=0; hseg<H_BITS; hseg=hseg+COUNTER_CHUNK) begin: g_hold_inc
            localparam integer W=(H_BITS-hseg>=COUNTER_CHUNK)?COUNTER_CHUNK:(H_BITS-hseg);
            if (hseg==0) begin: g_low
                assign hold_cnt_inc[hseg +: W]=hold_cnt[hseg +: W]+{{(W-1){1'b0}},1'b1};
            end else begin: g_high
                // The lower chunks' all-ones condition is predicted and
                // registered one cycle ahead, keeping the carry path local.
                assign hold_cnt_inc[hseg +: W]=hold_cnt[hseg +: W]+{{(W-1){1'b0}},hold_cnt_carry[hseg/COUNTER_CHUNK-1]};
                always @(posedge clk or posedge rst) begin
                    if(rst) hold_cnt_carry[hseg/COUNTER_CHUNK-1]<=1'b0;
                    else if(stable || hold_done || hold_last)
                        hold_cnt_carry[hseg/COUNTER_CHUNK-1]<=1'b0;
                    else hold_cnt_carry[hseg/COUNTER_CHUNK-1]<=
                        hold_cnt[hseg-1:0]=={{(hseg-1){1'b1}},1'b0};
                end
            end
        end
    endgenerate

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s0<=1'b1; s1<=1'b1; stable<=1'b1; cnt<=0;
            press_pulse<=1'b0; release_pulse<=1'b0;
            hold_cnt<=0; hold_done<=1'b0; hold_pulse<=1'b0;
        end else begin
            s0 <= button_in;
            s1 <= s0;
            press_pulse   <= 1'b0;
            release_pulse <= 1'b0;
            hold_pulse    <= 1'b0;

            if (s1 == stable) cnt <= 0;
            // cnt only takes values 0..D_LIMIT-1, so equality replaces a
            // full-width magnitude comparator without changing the timeout.
            else if (cnt == D_LIMIT-1) begin
                if (stable && !s1)      press_pulse   <= 1'b1;  // 松开→按下
                else if (!stable && s1) release_pulse <= 1'b1;  // 按下→松开
                stable <= s1;
                cnt    <= 0;
            end else cnt <= cnt_inc;

            if (stable == 1'b0) begin
                if (!hold_done) begin
                    if (hold_last) begin
                        hold_pulse <= 1'b1;
                        hold_done  <= 1'b1;
                        hold_cnt   <= 0;
                    end else hold_cnt <= hold_cnt_inc;
                end
            end else begin
                hold_cnt  <= 0;
                hold_done <= 1'b0;
            end
        end
    end
endmodule
