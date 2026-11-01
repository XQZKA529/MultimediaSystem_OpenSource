//=============================================================================
// module : fat_wav_controller
// 文件名 : rtl/audio/fat_wav_controller.v
// 功  能 : WAV 播放应用层。接收浏览器 ext_play_*，用 map bank1 + lba_stream1
//          读文件；wav_header_parse 校验 48k/16bit/PCM；wav_pcm_unpack 后打成
//          {L16,R16} 推入音频环。与图像链 FAT 互斥由 map/dir 仲裁保证。
//
//  契约（C4）：
//    ext_play_req(1拍)+{cluster,size} → ext_play_ack（头合法）/ ext_play_rejected
//    ack 在 payload_start（头解析成功）同拍发出，浏览器关窗后继续灌环。
//    新选曲 / 播完 / 格式错误 → 中止当前流并静音（由播放侧排空环）。
//    map_* 接 fat32_ro map 口（bank=1）
//    str_* 接 lba_stream（通道 1）
//    ring push：wr_push + {L16,R16}
//
//  相位 1 约定：unpack 24bit 取 [23:8] 打成 16bit 入环，播放侧 <<8 还原，
//  低 8 位丢失可接受（见 spec multi-stream-wav）。
//=============================================================================
module fat_wav_controller #(
    parameter integer SEEK_STEP_FRAMES = 240_000,  // 快进步长（帧）：5 s @48kHz
    parameter integer EXTERNAL_POSITION = 0
) (
    input  wire        clk,              // sd_card_clk
    input  wire        rst,

    // ---- 浏览器选曲 ----
    input wire use_prepared,defer_new_file,
    input  wire        ext_play_req,
    input  wire [31:0] ext_play_cluster,
    input  wire [31:0] ext_play_size,
    input wire start_at_position,input wire [31:0] initial_position,
    output wire [31:0] current_cluster,current_size,
    input wire prepare_restore,prepare_size,input wire [31:0] prepare_word,
    output wire [31:0] prepared_cluster,prepared_size,
    output reg         ext_play_ack,
    output reg         ext_play_rejected,
    input  wire        play_stop,        // 可选：强制停
    output wire        play_busy,
    output wire        play_idle,
    output reg  [3:0]  play_status,      // DBG

    // ---- map（bank1）----
    output reg         map_start,
    output wire [31:0] map_first_cluster,
    output wire [31:0] map_size,
    output reg         map_abort,
    input  wire        map_busy,
    input  wire        map_done,
    input  wire        map_ok,

    // ---- lba_stream1 ----
    output reg         str_start,
    output reg  [31:0] str_file_off,
    output reg  [31:0] str_len,
    output reg         str_abort,
    output wire        str_ready,
    input  wire [7:0]  str_data,
    input  wire        str_data_valid,
    input  wire        str_done,
    input  wire        str_ok,
    input  wire        str_error,
    input  wire        str_busy,

    // ---- 音频环 push（{L16,R16}）----
    output reg         ring_push,
    output reg  [31:0] ring_data,
    input  wire        ring_ready,        // burst-credit: free >= whole burst (gap-only sample)
    output reg         ring_clear,        // 1拍 flush ring on new track / stop (C4)
    output reg         ring_flush,        // 文件结束后把不足 WRITE_BURST 的尾样本写入 SDRAM

    // ---- 播放进度元数据（供音频 OSD；准静态，payload_start 同拍更新）----
    //  跨域纪律：这两个数据与 o_stream_toggle **同拍寄存**，视频域靠 toggle 的
    //  3 级同步沿来采数据 —— 数据在沿被看到前已稳定 ≥2 个 video 时钟。
    //  o_payload_frames = data chunk 的**帧数**（16bit/单声道=2字节一帧，
    //  立体声=4字节一帧），是 OSD 进度条的分母。
    output reg  [31:0] o_payload_frames,
    output reg         o_stream_is_seek,  // 本次重基是 seek(1) 还是换曲(0)
    output reg         o_stream_toggle,   // 每次重基翻转一次

    // ---- 快进（seek）----
    //  语义：向前 SEEK_STEP_FRAMES 帧；目标钳到"曲尾留 1 s"以内，已到最后 1 s 则忽略。
    //  执行：str_abort → 等流真正停下（lba_stream 回 str_aborted，不计错误）→
    //  用新偏移重启**同一记流**：段表仍有效（不重走 FAT 簇链）、不重解析 WAV 头
    //  （data_byte_len/channels 还在寄存器里）。
    //  ★ 三个隐藏依赖（缺一就是上板才暴露的 bug，见 doc/audio-osd-*）：
    //    ① str_len 必须 = cap_size - 新偏移（否则 file_left 从新起点多读 ⇒ 段表耗尽）
    //    ② hdr_active 必须置 0（置 1 ⇒ 载荷喂进未启动的头解析器 ⇒ 音频全丢）
    //    ③ wav_pcm_unpack 的字节对齐计数要补发一次 start_pulse（否则左右声道错相）
    input  wire        ext_seek_fwd,      // 1 拍
    input  wire [31:0] i_played_frames,
    input  wire        absolute_seek,
    input  wire [31:0] absolute_target,
    output wire [31:0] o_stream_base,
    output wire [31:0] o_pos_frames       // 绝对位置（帧）= pos_base + 已推帧数
);

    localparam P_IDLE    = 4'd0;
    localparam P_MAP     = 4'd1;
    localparam P_HDR     = 4'd2;
    localparam P_BODY    = 4'd3;
    localparam P_REJECT  = 4'd4;
    localparam P_DONE    = 4'd5;
    localparam P_RECOVER = 4'd6;
    localparam P_SEEK    = 4'd7;   // 快进：等被中止的流真正停下，再按新偏移重启

    reg [3:0]  state;
    reg [31:0] cap_cluster, cap_size;
    reg [31:0] nxt_cluster, nxt_size;
    // Reuse seek_target for an atomic positioned reopen, before publishing PCM_BEGIN.
    reg seek_target_valid,skip_initial;
    assign current_cluster=cap_cluster;assign current_size=cap_size;
    assign prepared_cluster=nxt_cluster;assign prepared_size=nxt_size;
    reg        hdr_start;
    reg        hdr_active;
    reg        pending_new;

    // ---- 快进（seek）----
    reg [31:0] pos_base;        // 本次流的起始帧号（首播 0；seek 后 = 目标）
    reg [31:0] pushed_cnt;      // 本次流已推入环的帧数
    reg [31:0] seek_target;     // 快进目标帧号
    reg [31:0] seek_bytes;      // 入口拍预寄存的字节偏移
    reg        unpack_realign;  // 补发 wav_pcm_unpack 的 start_pulse（1 拍）

    // 绝对位置 = 本次流起点 + 已推帧数（顺序加法，无除法）
    wire [31:0] pos_frames = EXTERNAL_POSITION ? i_played_frames : pos_base + pushed_cnt;
    assign o_stream_base=pos_base;
    assign o_pos_frames = pos_frames;

    // 目标钳位：曲尾留 1 s（48000 帧），文件短于 2 s 直接不支持快进
    localparam [31:0] SEEK_GUARD = 32'd48000;

    // ★ 时序：o_payload_frames 是**准静态**的（只在 payload_start 那一拍更新，
    //   然后整曲不变），但它在原来的组合锥里要串起「32 位减法 seek_cap →
    //   32 位比较 seek_ok → 32 位加法 + 比较 + mux seek_tgt」共 8 级逻辑、
    //   9.69 ns 数据路径（其中 net 占 59%），在 100 MHz bus_clk 上打成
    //   Setup WNS −44 ps。把**减法那一级单独寄存**，使 seek_cap / seek_allowed
    //   相对 o_payload_frames 只晚 1 拍稳定（o_payload_frames 本身要好几拍后
    //   才可能在 P_BODY 被真正使用，1 拍延后对功能无影响），组合锥里就只剩
    //   比较+加法+mux。
    reg [31:0] seek_cap_r;
    reg        seek_allowed_r;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            seek_cap_r     <= 32'd0;
            seek_allowed_r <= 1'b0;
        end else begin
            seek_cap_r     <= o_payload_frames - SEEK_GUARD;
            seek_allowed_r <= (o_payload_frames >= (SEEK_GUARD * 32'd2));
        end
    end

    // Pipeline the target together with its one-cycle request. The external
    // frozen position can change on the request cycle, so a continuously
    // computed target from the preceding cycle is not the requested position.
    reg        seek_pending_r;
    reg        seek_request_r,seek_position_ok_r;
    reg        seek_ok_r;
    reg [31:0] seek_sum_r;
    reg [31:0] seek_tgt_r;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            seek_pending_r <= 1'b0;
            seek_request_r<=0;seek_position_ok_r<=0;seek_sum_r<=0;
            seek_ok_r  <= 1'b0;
            seek_tgt_r <= 32'd0;
        end else begin
            seek_request_r <= ext_seek_fwd && state == P_BODY &&
                              !absolute_seek && !ext_play_req && !play_stop;
            seek_pending_r<=seek_request_r;
            seek_position_ok_r<=seek_allowed_r && (pos_frames < seek_cap_r);
            seek_ok_r<=seek_position_ok_r;
            seek_sum_r<=pos_frames+SEEK_STEP_FRAMES[31:0];
            seek_tgt_r<=seek_sum_r>seek_cap_r ? seek_cap_r:seek_sum_r;
        end
    end

    assign map_first_cluster = cap_cluster;
    assign map_size          = cap_size;
    assign play_busy         = (state != P_IDLE);
    assign play_idle         = (state == P_IDLE);

    // ---- 头解析 / unpack 字节分流 ----
    // payload_start 拍：头刚结束，下一字节即 PCM。同拍字节改喂 unpack
    //（wav_pcm_unpack 在 start_pulse 同拍可收首字节），不再进解析器。
    wire        parse_done, parse_ok, payload_start;
    wire [3:0]  reject_code;
    wire [31:0] data_off, data_len;
    wire        channels;
    wire        hdr_byte  = str_data_valid && hdr_active && !payload_start;
    wire        up_byte   = str_data_valid && (!hdr_active || payload_start);

    wav_header_parse u_hdr (
        .clk(clk), .rst(rst),
        .start_pulse(hdr_start),
        .byte_valid(hdr_byte),
        .byte_data(str_data),
        .parse_done(parse_done), .parse_ok(parse_ok),
        .reject_code(reject_code),
        .data_byte_offset(data_off), .data_byte_len(data_len),
        .channels(channels), .payload_start(payload_start)
    );

    wire        up_valid;
    wire [23:0] up_left, up_right;

    wav_pcm_unpack u_up (
        .clk(clk), .rst(rst),
        // seek 重启时补发一次对齐脉冲：abort 窗口里 unpack 的字节计数可能停在
        // 帧中间，不补发会导致左右声道错相
        .start_pulse(payload_start | unpack_realign),
        .byte_valid(up_byte),
        .byte_data(str_data),
        .channels(channels),
        .out_valid(up_valid),
        .out_left(up_left), .out_right(up_right)
    );

    // unpack 无反压。bug1 fix: burst-credit — lba_stream 只在突发间隙采样 str_ready；
    // 突发一旦开始，环侧凭 credit 预留整突发空间，中途只进不出（不丢样）。
    // str_ready = ring_ready（整突发可吸收）；P_HDR 段无样，恒 1。
    // D2: ring_ready 已是 wav_play_glue 内部寄存后的输出，此处组合直通即可。
    assign str_ready = (state == P_HDR)  ? 1'b1 :
                       (state == P_BODY) ? (hdr_active ? 1'b1 : ring_ready) :
                       1'b0;

    // 16-bit 打包 {L16,R16}：unpack 已 <<8，取 [23:8]
    wire [15:0] pack_l = up_left[23:8];
    wire [15:0] pack_r = up_right[23:8];
    wire [31:0] pack_w = {pack_l, pack_r};

    // 新选曲或强制停：回到 P_RECOVER 等 map/str 收尾，再决定重启或空闲
    wire want_new = ext_play_req;
    wire want_stop = play_stop && !ext_play_req;
    // The pending descriptor has only two writers. Keep its update outside
    // the playback state machine to avoid routing the state priority tree to
    // every descriptor bit. A new request takes precedence over restoration.
    //
    // 2026-10-30：只把 want_stop 这一项提前一拍寄存。
    // want_stop = play_stop = kp_stop || em_play_stop || (image_presented && paired_track_active && !em_block)
    // 是从 media_core 各处汇来的宽 OR，原来直接进 CE；布线报告显示
    //   play_status -> nxt_cluster_reg[20].ce  15 级逻辑、fanout 69、
    //   Data Path 19.892ns（net 13.842ns 占 70%），50MHz 下 Slack -0.244。
    // 它在本块里只用于"有停止请求时不恢复描述符"，因此寄存一拍只会改变
    // "stop 与 restore 同拍"这种边角，新请求（want_new）路径保持当拍不变。
    reg want_stop_q;
    always @(posedge clk or posedge rst) begin
        if (rst) want_stop_q<=0; else want_stop_q<=want_stop;
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            nxt_cluster<=0; nxt_size<=0;
        end else if (want_new && use_prepared!==1'b1) begin
            nxt_cluster<=ext_play_cluster; nxt_size<=ext_play_size;
        end else if (prepare_restore===1'b1 && !want_new && !want_stop_q) begin
            if (prepare_size) nxt_size<=prepare_word; else nxt_cluster<=prepare_word;
        end
    end
    reg absolute_pending;
    // Range validation is registered before it enters the broad control-priority
    // mux. The frozen playback position remains the exact requested target.
    always @(posedge clk or posedge rst) begin
        if(rst) absolute_pending<=0;
        else begin
            absolute_pending<=absolute_seek && !want_new && !want_stop && state!=P_SEEK &&
                o_payload_frames!=0 && absolute_target<o_payload_frames;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state<=P_IDLE;
            map_start<=0; map_abort<=0;
            str_start<=0; str_abort<=0;
            str_file_off<=0; str_len<=0;
            cap_cluster<=0; cap_size<=0;
            seek_target_valid<=0;skip_initial<=0;
            ext_play_ack<=0; ext_play_rejected<=0;
            play_status<=0;
            ring_push<=0; ring_data<=0; ring_clear<=0; ring_flush<=0;
            unpack_realign<=0;
            hdr_start<=0; hdr_active<=0;
            pending_new<=0;
            o_payload_frames<=32'd0; o_stream_is_seek<=1'b0; o_stream_toggle<=1'b0;
            pos_base<=32'd0; pushed_cnt<=32'd0; seek_target<=32'd0; seek_bytes<=32'd0; unpack_realign<=1'b0;
        end else begin
            map_start<=0; str_start<=0;
            ext_play_ack<=0; ext_play_rejected<=0;
            ring_push<=0; ring_clear<=0; ring_flush<=0;
            hdr_start<=0;
            str_abort<=0; map_abort<=0;
            // ★ unpack_realign 必须在这里清零：P_SEEK 只拉 1 拍。
            //   漏掉它 → start_pulse 恒 1 → unpack 每拍被对齐复位，永远出不了
            //   样本 → seek 后永久静音（上板实测踩过：长按快进即死，之后
            //   选曲/双击"无声"全是这一个根因）。
            unpack_realign<=1'b0;
            // One request in flight: reuse the existing target register rather
            // than a second 32-bit mailbox. Validation completes next cycle.
            if(absolute_seek && state!=P_SEEK && !want_new && !want_stop)
                seek_target<=absolute_target;

            if (payload_start && state==P_HDR && !want_new && !want_stop) begin
                hdr_active<=0;
                // 头解析完成：把"总帧数"交给 OSD，并翻转跨域握手位。
                // 帧数 = data_len / 每帧字节数（mono 2B / stereo 4B），只用移位。
                o_payload_frames <= channels ? (data_len >> 2) : (data_len >> 1);
                o_stream_is_seek <= 1'b0;          // 首播/换曲
                if(!seek_target_valid || seek_target==0) o_stream_toggle<=~o_stream_toggle;
                else skip_initial<=1;
                pos_base         <= 32'd0;          // 从头播
                pushed_cnt       <= 32'd0;
            end

            // 快进目标算术所需的"已推帧数"：unpack 每出一对样本计一次
            if (up_valid) pushed_cnt <= pushed_cnt + 32'd1;

            // unpack → ring：突发中每样必进（credit 已预留整突发空间，不丢样）
            if (up_valid && state==P_BODY && !want_new && !want_stop && !skip_initial && !(seek_target_valid && seek_target!=0)) begin
                ring_push<=1'b1;
                ring_data<=pack_w;
            end

            if (want_new) begin
                seek_target<=initial_position;seek_target_valid<=start_at_position===1'b1;skip_initial<=0;
                pending_new<=1'b1;
                ring_clear<=1'b1;   // bug2: flush play ring, mute until new payload (C4)
                // One startup path also holds the old descriptor until its
                // epoch history is committed, including requests from P_IDLE.
                str_abort<=str_busy;
                map_abort<=(state==P_MAP);
                state<=P_RECOVER;
            end else if (want_stop) begin
                pending_new<=1'b0;
                ring_clear<=1'b1;   // bug2: flush play ring on stop (C4)
                str_abort<=state!=P_IDLE;
                map_abort<=(state==P_MAP);
                if(state!=P_IDLE) state<=P_RECOVER;
            end else if(absolute_pending) begin
                seek_bytes<=seek_target << (channels ? 32'd2 : 32'd1);
                str_abort<=1;ring_clear<=1;state<=P_SEEK;
            end else if(seek_pending_r && seek_ok_r && !absolute_seek) begin
                // Accepted in P_BODY on the preceding cycle. Also honor it
                // when that cycle completed the current SD stream.
                seek_target<=seek_tgt_r;
                seek_bytes<=seek_tgt_r << (channels ? 32'd2 : 32'd1);
                str_abort<=1;ring_clear<=1;state<=P_SEEK;
            end else begin
                case (state)
                    P_IDLE: begin
                        // want_new 分支已处理启动
                    end
                    P_MAP: begin
                        if (map_done) begin
                            if (map_ok) begin
                                str_file_off<=32'd0;
                                str_len<=cap_size;
                                str_start<=1'b1;hdr_start<=1'b1;hdr_active<=1'b1;
                                state<=P_HDR;
                            end else begin
                                play_status<=4'd2;   // map walk 失败（簇链/溢出）
                                state<=P_REJECT;
                            end
                        end
                    end
                    P_HDR: begin
                        if (payload_start && state==P_HDR && !want_new && !want_stop) begin
                            if(seek_target_valid && seek_target!=0) begin
                                if(seek_target<(channels ? data_len>>2:data_len>>1)) begin
                                    seek_bytes<=seek_target << (channels ? 32'd2 : 32'd1);
                                    str_abort<=1;state<=P_SEEK;
                                end else begin play_status<=4'd1;state<=P_REJECT;end
                            end else begin ext_play_ack<=1'b1;seek_target_valid<=0;state<=P_BODY;end
                        end else if (parse_done && !parse_ok) begin
                            play_status<={1'b0,reject_code};state<=P_REJECT;
                        end
                    end
                    P_BODY: begin
                        if (str_done) begin
                            if (str_ok) begin
                                ring_flush<=1'b1;
                                state<=P_DONE;
                            end
                            else begin
                                play_status<=4'd3;   // str_error：段表耗尽/SD 读失败
                                state<=P_REJECT;
                            end
                        end
                    end
                    // 快进第 2 步：等被中止的流真正停下（lba_stream 回 str_aborted/
                    // str_done 或转回空闲），再按新偏移重启**同一记流**。
                    //   · 不重走 FAT 簇链：段表（bank1）仍有效
                    //   · 不重解析 WAV 头：data_byte_len/channels 还在寄存器里
                    //     ⇒ hdr_active 必须置 0、unpack 必须补发对齐脉冲
                    //   · ext_play_ack/rejected 不再发（这不是新的选曲请求）
                    P_SEEK: begin
                        if (!str_busy || str_done) begin
                            str_file_off <= data_off + seek_bytes;
                            str_len      <= cap_size - (data_off + seek_bytes);
                            pos_base       <= seek_target;
                            pushed_cnt     <= 32'd0;
                            o_stream_is_seek <= 1'b1;
                            o_stream_toggle  <= ~o_stream_toggle;
                            hdr_active     <= 1'b0;
                            skip_initial<=0;
                            if(seek_target_valid) begin ext_play_ack<=1;seek_target_valid<=0;end
                            unpack_realign <= 1'b1;
                            ring_clear     <= 1'b1;
                            str_start      <= 1'b1;
                            state          <= P_BODY;
                        end
                    end
                    P_REJECT: begin
                        ext_play_rejected<=1'b1;
                        str_abort<=1'b1;
                        state<=P_DONE;
                    end
                    P_DONE: begin
                        state<=P_IDLE;
                    end
                    P_RECOVER: begin
                        // 等 map/str 真正停下，再启动 pending_new 或回空闲
                        if (!map_busy && !str_busy && !str_data_valid && defer_new_file!==1'b1) begin
                            if (pending_new) begin
                                cap_cluster<=nxt_cluster;
                                cap_size<=nxt_size;
                                hdr_active<=1'b0;
                                ext_play_ack<=0; ext_play_rejected<=0;
                                if (nxt_size < 32'd44) begin
                                    ext_play_rejected<=1'b1;
                                    play_status<=4'd1;
                                    pending_new<=1'b0;
                                    state<=P_DONE;
                                end else begin
                                    map_start<=1'b1;
                                    hdr_start<=1'b0;
                                    play_status<=4'd0;
                                    pending_new<=1'b0;
                                    state<=P_MAP;
                                end
                            end else begin
                                state<=P_IDLE;
                            end
                        end
                    end
                    default: state<=P_IDLE;
                endcase
            end
        end
    end

endmodule
