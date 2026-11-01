//=============================================================================
// module : wav_play_glue
// 文件名 : rtl/audio/wav_play_glue.v
// 功  能 : 音频播放侧胶水：audio_ring_bram 弹性 FIFO + 16bit→24bit 扩位，
//          把 fat_wav_controller 的 {L16,R16} 环字流接到 audio_wav_pcm 的
//          in_valid/in_left/in_right/in_ready 契约。
//
//  相位 1 约定（可接受损失）：
//    fat_wav_controller 取 unpack 24bit 的 [23:8] 打成 16bit 入环；
//    本模块 out_left/right = {L16/R16, 8'h00}（<<8）还原 24bit。
//    低 8 位 LSB 在入环时已丢弃，本阶段不做抖动/补零优化。
//
//  时钟：
//    wr_clk = sd_card_clk（WAV 读侧）
//    rd_clk = video_clk（audio_wav_pcm 48 kHz 取样侧）
//=============================================================================
module wav_play_glue #(
    parameter integer ADDR_WIDTH   = 11,                   // 2048 字 = 8 KB
    parameter integer BURST_WORDS  = 256                   // 与 stream1 MAX_BURST=2 扇区对齐
)(
    // ---- 写侧（sd_card_clk）----
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        wr_push,
    input  wire [31:0] wr_data,
    output wire        wr_ready,          // burst credit（已寄存）: free >= BURST_WORDS (gap-only sample)
    input  wire        wr_clear,          // bug2: 1拍 flush ring on track change / stop (C4)
    output wire        wr_almost_empty,   // low watermark (for SDMA refill hint)

    // ---- 读侧（video_clk）→ audio_wav_pcm ----
    input  wire        rd_clk,
    input  wire        rd_rst_n,
    output wire        out_valid,
    output wire [23:0] out_left,
    output wire [23:0] out_right,
    input  wire        out_ready,
    output wire        play_run,          // I_run：环或 hold 仍有样本
    output wire [ADDR_WIDTH:0] buffered_words,
    output wire        clear_busy,
    output wire        clear_video
);

    localparam integer DEPTH_C  = (1 << ADDR_WIDTH);
    // bug1 fix: burst-credit — wr_ready only when the elastic FIFO can absorb a
    // FULL burst (BURST_WORDS) plus the 1-deep hold pipeline.  lba_stream samples
    // str_ready at burst gaps only; mid-burst samples must never drop.
    // D2: credit 已在本模块寄存后输出，顶层无需（也不应）再打拍。
    localparam integer CREDIT_C = BURST_WORDS + 4;
    localparam integer AFULL_C  = DEPTH_C - CREDIT_C;

    wire        ring_full, ring_empty, ring_af, ring_ae;
    wire [31:0] ring_rd_data;
    wire        ring_rd_valid;
    wire [ADDR_WIDTH:0] wr_level, rd_level;
    reg         ring_rd_en;
    reg  [31:0] hold;
    reg         hold_v;
    reg         fetch_pend;

    // burst credit: enough free words for a whole 2-sector burst + pipeline.
    // bug1 fix + D2：credit 在本模块内部寄存后输出（wr_clk 域打一拍）。
    // wr_ready 组合上只依赖 ring_af（寄存器源水位）与复位，不依赖 wr_push，
    // 寄存无组合环；全链同在 sd_card_clk 域，lba_stream 只在突发间隙采样
    // str_ready，多这 1 拍仅让下一突发晚发起 ≤1 拍，CREDIT_C 的 +4 余量覆盖。
    reg wr_ready_r;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            wr_ready_r <= 1'b0;
        else
            wr_ready_r <= !ring_af;
    end
    assign wr_ready = wr_ready_r;
    assign wr_almost_empty = ring_ae;

    // bug2: clear flushes ring + hold so track change mutes until new payload.
    // ★ CDC 纪律（seek 会让 clear 在 10µs 内连打两次，必须是同步释放）：
    //   wr_clear 是 sd 域 1 拍脉冲。写侧同域，直接异步复位没问题；
    //   读侧在 video_clk 域——把脉冲在 sd 域展宽成电平（10 拍 = 100ns ≥
    //   2 个 video 周期），读侧 2FF 同步后作为复位电平 ⇒ 断言与释放都对齐
    //   读侧时钟，无 recovery/removal 违规。写侧先出复位、读侧晚 2 拍出复位
    //   是安全方向（写者领先读者只会被反压，不会读空）。
    localparam [3:0] WR_CLR_EXT = 4'd10;  // 展宽拍数：100ns @100MHz ≥ 2 个 video 周期

    reg [3:0] clr_ext_cnt;
    reg       clr_lvl;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            clr_lvl     <= 1'b0;
            clr_ext_cnt <= 4'd0;
        end else if (wr_clear) begin
            clr_lvl     <= 1'b1;
            clr_ext_cnt <= WR_CLR_EXT;
        end else if (clr_ext_cnt != 4'd0) begin
            clr_ext_cnt <= clr_ext_cnt - 4'd1;
        end else begin
            clr_lvl     <= 1'b0;
        end
    end

    reg clr_s1, clr_s2;
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            clr_s1 <= 1'b0;
            clr_s2 <= 1'b0;
        end else begin
            clr_s1 <= clr_lvl;
            clr_s2 <= clr_s1;
        end
    end

    wire wr_rst_n_i = wr_rst_n & ~clr_lvl;
    wire rd_rst_n_i = rd_rst_n & ~clr_s2;
    assign buffered_words=rd_level+hold_v+fetch_pend;
    assign clear_busy=clr_lvl;
    assign clear_video=clr_s2;

    audio_ring_bram #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(ADDR_WIDTH),
        .AL_FULL_NUM(AFULL_C),
        .AL_EMPTY_NUM(4)
    ) u_ring (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n_i),
        .wr_en(wr_push && !ring_full), .wr_data(wr_data),
        .wr_full(ring_full), .wr_level(wr_level), .almost_full(ring_af),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n_i),
        .rd_en(ring_rd_en), .rd_data(ring_rd_data), .rd_valid(ring_rd_valid),
        .rd_empty(ring_empty), .rd_level(rd_level), .almost_empty(ring_ae)
    );

    // 预取 hold → show-ahead（audio_wav_pcm 组合同拍取样）
    wire consume = out_valid && out_ready;
    wire can_acc = !hold_v || consume;
    wire do_fetch = can_acc && !fetch_pend && !ring_empty;

    always @(posedge rd_clk or negedge rd_rst_n_i) begin
        if (!rd_rst_n_i) begin
            hold       <= 32'd0;
            hold_v     <= 1'b0;
            fetch_pend <= 1'b0;
            ring_rd_en <= 1'b0;
        end else begin
            ring_rd_en <= do_fetch;
            if (ring_rd_valid) begin
                hold       <= ring_rd_data;
                hold_v     <= 1'b1;
                fetch_pend <= 1'b0;
            end else if (consume) begin
                hold_v <= 1'b0;
            end
            if (do_fetch)
                fetch_pend <= 1'b1;
        end
    end

    assign out_valid = hold_v;
    assign out_left  = {hold[31:16], 8'h00};
    assign out_right = {hold[15:0],  8'h00};
    assign play_run  = hold_v || fetch_pend || !ring_empty;

endmodule
