//=============================================================================
// module : audio_osd_status
// 文件名 : rtl/ui/audio_osd_status.v
// 功  能 : 【OSD 语义层】整个 OSD 全部语义值的**唯一产生者**：跨域搬运曲目元数据、
//          数已播帧、算条形填充像素、格式化 MM:SS、推进节拍相位，最后组装成
//          128 bit 渲染模型（见 rtl/pkg/osd_model_bus.vh，频谱字段直通不入寄存器）。
//
//  定位：
//    · 全工程唯一新增的**双时钟**模块（sd_card_clk → video_clk 的准静态握手）。
//    · 严格不产生像素、不知道条形有多宽以外的事、不知道动画长什么样。
//    · 渲染层（audio_osd_overlay + 4 个 painter）只读它的输出，反向无依赖。
//
//  ── 为什么进度分子在 video 域数 ─────────────────────────────────────────
//    `i_sample_valid && i_sample_ready` 恰好等于 audio_wav_pcm 的 in_take
//    （= 这一拍真正取走一对样本进 48 kHz 管线），平均 48000/s。
//    好处：① 与播放位置一一对应；② 欠载自动停；③ 暂停时 ready 被门掉 ⇒
//    **进度自动冻结，零额外逻辑**；④ AUDIO_SOURCE="TONE" 时 ready 恒 0 ⇒ 自动隐藏。
//
//  ── 填充算法：样本轴 DDA（零除法、零乘法）──────────────────────────────
//    每消费一对样本：frac += BAR_W；若 frac >= total 则 frac -= total 且 fill++。
//    不变量：fill = floor(pos × BAR_W / total)，frac = (pos × BAR_W) mod total。
//    只有 32 位加法 + 比较，且跑在 48 kHz（远低于像素率）⇒ 像素路径上只剩
//    painter 里的一个"lx < fill"比较。**不要改成"每像素累加"**：那是顺序累加，
//    纯组合实现会引入乘法，把长路径塞进 75 MHz 像素域。
//
//  ── 时间文本：全十进制位计数，一样零除法 ───────────────────────────────
//    秒/分不存二进制再除，而是直接维护"十位/个位"数字（ss_t/ss_o, mm_t/mm_o）。
//    每秒进位靠 9→0、5→0 判断；ASCII 就是 8'h30 + 数字。
//    总时长要"数出 total 里有多少个 48000"：用后台循环重复减 48000 同时做十进制
//    进位（1 小时 ≤3600 次迭代，在某几帧的消隐空闲里跑完，与显示时序解耦）。
//
//  ── 快进 5 秒怎么跳格（本次设计的关键取舍）────────────────────────────
//    px_step = SEEK_STEP_FRAMES × BAR_W / total **每轨只算一次**（total 每轨不变），
//    用重复减法（≤340 次）。快进时视频域只需 fill += px_step、秒数 += 5，
//    **不需要在跳转时做任何除法**。代价：每次跳格残留 <1 px 舍入误差（不可见），
//    且曲尾 1 s 内的钳位快进会让显示略微超前（马上曲终，可接受）。
//
//  ── 跨域纪律 ───────────────────────────────────────────────────────────
//    sd 侧数据（payload_frames / stream_is_seek）由 fat_wav_controller 寄存，
//    且在翻转 i_stream_toggle **之前**已稳定 ≥2 个 video 时钟 ⇒ 视频域用
//    "toggle 3 级同步 + 边沿检测"取沿，在沿上当拍直接采数据（教科书多比特 CDC）。
//    模型在 vs 帧界锁存，避免时间文本/条形边缘在半帧内被改花。
//=============================================================================
`include "../pkg/video_bmp_params.vh"
`include "../pkg/osd_model_bus.vh"
module audio_osd_status #(
    parameter integer PIX_CLK_HZ   = `VBP_PIX_CLK_HZ,   // 75_000_000
    parameter integer SAMPLE_RATE  = 48_000,
    parameter integer BAR_W        = `VBP_OSD_BAR_W,    // 340
    parameter integer SEEK_STEP_S  = 5,                 // 快进步长（秒）
    parameter integer DUR_ITER_MAX = 20000              // 总时长循环次数上限（防垃圾值）
)(
    //====================== sd_card_clk 域（准静态元数据）======================
    input  wire        i_sd_clk,
    input  wire        i_sd_rst,            // 高有效
    input  wire [31:0] i_payload_frames,    // data 载荷总帧数（样对）
    input  wire        i_stream_is_seek,    // 本次重基是 seek(1) 还是换曲(0)
    input  wire        i_stream_toggle,     // 每次重基翻转一次
    input  wire        i_pause,             // 暂停电平（sd 域）

    //====================== video_clk 域 ======================
    input  wire        i_video_clk,
    input  wire        i_video_rst,         // 高有效
    input  wire        i_vs,                // 用于帧界锁存模型
    input  wire        i_sample_valid,      // 环取数握手（分子）
    input  wire        i_sample_ready,
    input  wire        i_play_run,          // OSD 显示条件（暂停时仍为 1）
    input  wire [`OSD_M_SPEC_W-1:0] i_spectrum_heights,

    output wire        o_pause_v,           // 同步到 video 域后的暂停电平（顶层门控用）
    output wire        o_stream_restart_v,  // 同步后的换曲/快进脉冲
    output wire [`OSD_M_W-1:0] o_model
);

    localparam [31:0] SR32 = SAMPLE_RATE;
    localparam integer SEEK_STEP_FRAMES = SEEK_STEP_S * SAMPLE_RATE;
    localparam [31:0] PX_NUM_C = SEEK_STEP_FRAMES * BAR_W;   // 常数：240000*340

    //=========================================================================
    // 1) 跨域：toggle 3 级同步 + 边沿检测
    //=========================================================================
    reg tg_s1, tg_s2, tg_s3;
    always @(posedge i_video_clk or posedge i_video_rst) begin
        if (i_video_rst) begin
            tg_s1 <= 1'b0; tg_s2 <= 1'b0; tg_s3 <= 1'b0;
        end else begin
            tg_s1 <= i_stream_toggle;
            tg_s2 <= tg_s1;
            tg_s3 <= tg_s2;
        end
    end
    wire stream_edge = tg_s2 ^ tg_s3;       // 重基沿
    assign o_stream_restart_v = stream_edge;

    //=========================================================================
    // 2) pause 同步（2FF）：同一条网既做门控又进模型，保证两处口径一致
    //=========================================================================
    reg ps1, ps2;
    always @(posedge i_video_clk or posedge i_video_rst) begin
        if (i_video_rst) begin ps1 <= 1'b0; ps2 <= 1'b0; end
        else             begin ps1 <= i_pause; ps2 <= ps1; end
    end
    assign o_pause_v = ps2;

    //=========================================================================
    // 3) 位置计数（分子）——暂停/欠载因 ready 被门而自动冻结
    //=========================================================================
    wire        consume = i_sample_valid && i_sample_ready;
    reg  [31:0] pos_local;

    //=========================================================================
    // 4) 样本轴 DDA：fill = floor(pos × BAR_W / total)
    //=========================================================================
    reg  [31:0] tot_r;                      // 锁存的总帧数（DDA 分母）
    reg  [31:0] frac;
    reg  [9:0]  fill;                       // 已播像素列数 0..BAR_W
    reg  [9:0]  px_step;                    // 每次 seek 跳几格（每轨算一次）

    wire [31:0] frac_nxt = frac + BAR_W[31:0];

    //=========================================================================
    // 5) 十进制数字计数器（避免 /10 /60）
    //=========================================================================
    reg [15:0] smp_cnt;                     // 0..47999，产生"秒"节拍
    reg [3:0]  cur_ss_o, cur_ss_t;          // 已播 秒个位/十位
    reg [3:0]  cur_mm_o, cur_mm_t;          // 已播 分个位/十位
    reg [3:0]  dur_ss_o, dur_ss_t;          // 总时长 秒个位/十位
    reg [3:0]  dur_mm_o, dur_mm_t;          // 总时长 分个位/十位

    localparam [4:0] SEEK_STEP_D5 = SEEK_STEP_S;              // 步长的 5 bit 形式
    wire [4:0] ss_add = {1'b0, cur_ss_o} + SEEK_STEP_D5;      // 快进时的秒个位中间量

    //=========================================================================
    // 6) 节拍相位（4 Hz 推进；暂停冻结）
    //=========================================================================
    wire tick4, tick1, lvl1;
    osd_timebase #(
        .CLK_FREQ_HZ ( PIX_CLK_HZ )
    ) u_tb (
        .video_clk ( i_video_clk ),
        .rst       ( i_video_rst ),
        .o_tick4   ( tick4 ),
        .o_tick1   ( tick1 ),
        .o_lvl1    ( lvl1  )
    );
    reg [1:0] beat_phase;

    //=========================================================================
    // 7) 后台作业：每轨算一次 (a) 总时长 mm:ss  (b) px_step
    //    迭代次数 ≤（秒数 + 340），典型几百拍，与显示完全解耦。
    //=========================================================================
    localparam [1:0] J_IDLE = 2'd0, J_DUR = 2'd1, J_PX = 2'd2;
    reg  [1:0]  jst;
    reg  [31:0] j_acc;
    reg  [15:0] j_cnt;

    // 秒节拍（每 SAMPLE_RATE 个样本一次）
    wire sec_tick = consume && (smp_cnt == (SAMPLE_RATE-1));

    always @(posedge i_video_clk or posedge i_video_rst) begin
        if (i_video_rst) begin
            pos_local  <= 32'd0;
            tot_r      <= 32'd0;
            frac       <= 32'd0;
            fill       <= 10'd0;
            px_step    <= 10'd0;
            smp_cnt    <= 16'd0;
            cur_ss_o   <= 4'd0; cur_ss_t <= 4'd0;
            cur_mm_o   <= 4'd0; cur_mm_t <= 4'd0;
            dur_ss_o   <= 4'd0; dur_ss_t <= 4'd0;
            dur_mm_o   <= 4'd0; dur_mm_t <= 4'd0;
            beat_phase <= 2'd0;
            jst        <= J_IDLE;
            j_acc      <= 32'd0;
            j_cnt      <= 16'd0;
        end else begin
            //-------------------------------------------------------------
            // 7a) 重基沿：锁存新总量、复位/跳格、启动后台作业
            //-------------------------------------------------------------
            if (stream_edge) begin
                tot_r     <= i_payload_frames;
                pos_local <= 32'd0;
                smp_cnt   <= 16'd0;
                // 总时长只取决于 total，每次重基都从零重算（seek 也不例外，
                // 否则数字会在旧值上累加 —— TB 里 T4 抓过这个 bug）
                dur_ss_o  <= 4'd0; dur_ss_t <= 4'd0;
                dur_mm_o  <= 4'd0; dur_mm_t <= 4'd0;
                if (i_stream_is_seek) begin
                    // 快进：条形按 px_step 跳格；秒数 +SEEK_STEP_S（十进制进位）
                    fill <= ((fill + px_step) > BAR_W[9:0]) ? BAR_W[9:0]
                                                            : (fill + px_step);
                    // 秒进位：用 5 位中间量，支持步长 ≤10 s（更大需改成循环减 10）
                    if (ss_add > 5'd9) begin
                        cur_ss_o <= ss_add[3:0] - 4'd10;
                        if (cur_ss_t == 4'd5) begin
                            cur_ss_t <= 4'd0;
                            if (cur_mm_o == 4'd9) begin
                                cur_mm_o <= 4'd0;
                                cur_mm_t <= (cur_mm_t == 4'd9) ? 4'd9 : (cur_mm_t + 4'd1);
                            end else cur_mm_o <= cur_mm_o + 4'd1;
                        end else cur_ss_t <= cur_ss_t + 4'd1;
                    end else cur_ss_o <= ss_add[3:0];
                end else begin
                    // 换曲：一切归零
                    fill      <= 10'd0;
                    frac      <= 32'd0;
                    cur_ss_o  <= 4'd0; cur_ss_t <= 4'd0;
                    cur_mm_o  <= 4'd0; cur_mm_t <= 4'd0;
                end
                // 启动/重启后台作业
                j_acc <= i_payload_frames;
                j_cnt <= 16'd0;
                jst   <= J_DUR;
            end else begin
                //---------------------------------------------------------
                // 7b) 位置与 DDA
                //---------------------------------------------------------
                if (consume) begin
                    pos_local <= pos_local + 32'd1;
                    if (fill < BAR_W[9:0]) begin
                        if (frac_nxt >= tot_r) begin
                            frac <= frac_nxt - tot_r;
                            fill <= fill + 10'd1;
                        end else begin
                            frac <= frac_nxt;
                        end
                    end
                    // 秒节拍（十进制进位，零除法）
                    if (sec_tick) begin
                        smp_cnt <= 16'd0;
                        if (cur_ss_o == 4'd9) begin
                            cur_ss_o <= 4'd0;
                            if (cur_ss_t == 4'd5) begin
                                cur_ss_t <= 4'd0;
                                if (cur_mm_o == 4'd9) begin
                                    cur_mm_o <= 4'd0;
                                    cur_mm_t <= (cur_mm_t == 4'd9) ? 4'd9
                                                                   : (cur_mm_t + 4'd1);
                                end else cur_mm_o <= cur_mm_o + 4'd1;
                            end else cur_ss_t <= cur_ss_t + 4'd1;
                        end else cur_ss_o <= cur_ss_o + 4'd1;
                    end else begin
                        smp_cnt <= smp_cnt + 16'd1;
                    end
                end

                //---------------------------------------------------------
                // 7c) 后台作业（非阻塞：位置/DDA 优先级更高，互不干扰）
                //---------------------------------------------------------
                case (jst)
                J_DUR: begin
                    if ((j_acc >= SR32) && (j_cnt < DUR_ITER_MAX[15:0])) begin
                        j_acc <= j_acc - SR32;
                        j_cnt <= j_cnt + 16'd1;
                        // 总时长秒的十进制进位
                        if (dur_ss_o == 4'd9) begin
                            dur_ss_o <= 4'd0;
                            if (dur_ss_t == 4'd5) begin
                                dur_ss_t <= 4'd0;
                                if (dur_mm_o == 4'd9) begin
                                    dur_mm_o <= 4'd0;
                                    dur_mm_t <= (dur_mm_t == 4'd9) ? 4'd9
                                                                   : (dur_mm_t + 4'd1);
                                end else dur_mm_o <= dur_mm_o + 4'd1;
                            end else dur_ss_t <= dur_ss_t + 4'd1;
                        end else dur_ss_o <= dur_ss_o + 4'd1;
                    end else begin
                        // 转去算 px_step
                        j_acc <= PX_NUM_C;
                        j_cnt <= 16'd0;
                        px_step <= 10'd0;
                        jst   <= J_PX;
                    end
                end
                J_PX: begin
                    // px_step = floor(SEEK_STEP_FRAMES*BAR_W / total)，重复减法 ≤BAR_W 次
                    if ((j_acc >= tot_r) && (tot_r != 32'd0) && (j_cnt <= BAR_W[15:0])) begin
                        j_acc  <= j_acc - tot_r;
                        j_cnt  <= j_cnt + 16'd1;
                        px_step<= j_cnt[9:0] + 10'd1;
                    end else begin
                        jst <= J_IDLE;
                    end
                end
                default: jst <= J_IDLE;
                endcase
            end

            //-------------------------------------------------------------
            // 7d) 节拍相位（暂停冻结）
            //-------------------------------------------------------------
            if (tick4 && !ps2) beat_phase <= beat_phase + 2'd1;
        end
    end

    //=========================================================================
    // 8) 文本缓冲：13 字符 "MM:SS / MM:SS"（全补零，直接由十进制位拼出）
    //=========================================================================
    wire [`OSD_TXT_W-1:0] txt_w = {
        8'h30 + {4'd0, dur_ss_o},      // [103:96]  总时长 个位秒
        8'h30 + {4'd0, dur_ss_t},      // [95:88]   总时长 十位秒
        8'h3A,                         // ':' 
        8'h30 + {4'd0, dur_mm_o},      // 总时长 个位分
        8'h30 + {4'd0, dur_mm_t},      // 总时长 十位分
        8'h20,                         // ' '
        8'h2F,                         // '/'
        8'h20,                         // ' '
        8'h30 + {4'd0, cur_ss_o},      // 已播 个位秒
        8'h30 + {4'd0, cur_ss_t},      // 已播 十位秒
        8'h3A,                         // ':'
        8'h30 + {4'd0, cur_mm_o},      // 已播 个位分
        8'h30 + {4'd0, cur_mm_t}       // 已播 十位分
    };

    //=========================================================================
    // 9) 模型组装（组合拼）
    //
    //    ★ 只有 [127:0] 需要 vs 帧界锁存（填充分量、文本、节拍、显隐）；
    //      频谱字段 (`OSD_M_SPEC, 80 bit) **直通**，不过寄存器。
    //      理由：`audio_goertzel_osd` 的柱高本来就是在 vs 沿顺序扫完才更新的
    //      （见其头注释第 5 节），这里再锁一遍纯属重复——省 80 个触发器。
    //      相位上也安全：那 12 拍的扫描落在 vs 消隐里（≈42 µs），
    //      远早于有效像素区，不存在半帧撕裂。
    //=========================================================================
    localparam integer MRW = 128;                  // 需要锁存的部分
    wire [MRW-1:0] model_w;
    assign model_w[`OSD_M_FILLPX] = fill;          // [9:0]
    assign model_w[`OSD_M_BEAT]   = beat_phase;    // [11:10]
    assign model_w[`OSD_M_TXT]    = txt_w;         // [115:12]
    assign model_w[`OSD_M_SHOW]   = i_play_run;    // [116]
    assign model_w[`OSD_M_PAUSED] = ps2;           // [117]
    assign model_w[`OSD_M_BLINK1] = lvl1;          // [118]
    assign model_w[127:119]       = 9'd0;

    reg vs_d;
    reg [MRW-1:0] model_r;

    always @(posedge i_video_clk or posedge i_video_rst) begin
        if (i_video_rst) begin
            vs_d    <= 1'b0;
            model_r <= {MRW{1'b0}};
        end else begin
            vs_d <= i_vs;
            if (i_vs & ~vs_d) model_r <= model_w[MRW-1:0];
        end
    end

    assign o_model[MRW-1:0]     = model_r;
    assign o_model[`OSD_M_SPEC] = i_spectrum_heights;   // 直通，见第 9 节说明

endmodule
