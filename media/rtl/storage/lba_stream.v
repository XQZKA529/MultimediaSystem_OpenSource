//=============================================================================
// module : lba_stream
// 文件名 : rtl/storage/lba_stream.v
// 功  能 : 持有 fat_chain_map 段表游标，向绑定 SD 通道要扇区突发，吐文件字节流。
//          与 fat32_ro 的 file_* 字节流解耦：map 填好后本模块不查 FAT。
//
//  绑定：实例参数 CHANNEL 不驱动硬件，仅文档约定 0=ch0（图）/1=ch1（音）。
//  反压 str_ready 仅在突发间隙采样（与 fat32_ro.file_read_ready 同则）。
//  文件偏移/长度按字节；可从非 0 开始（首字节可不在扇区边界）。
//
//  SD command/grant failure retries the unchanged request at most RETRY_MAX
//  times, waiting RETRY_WAIT cycles. A data-phase failure terminates the stream:
//  bytes may already have reached the WAV parser/PCM FIFO and cannot be replayed
//  without corrupting sample order. The WAV controller rejects/clears this epoch.
//=============================================================================
module lba_stream #(
    parameter integer MAP_DEPTH    = 256,
    parameter integer MAP_AW       = 8,
    parameter integer MAX_BURST    = 64,   // 扇区，与 FAT 突发上限一致
    parameter integer CHANNEL      = 0,
    parameter integer RETRY_MAX    = 3,        // 同一记突发的最大重发次数
    parameter integer RETRY_WAIT   = 500_000   // 两次尝试之间的退避（clk 拍，100MHz≈5ms）
)(
    input  wire        clk,
    input  wire        rst,

    // ---- map 读口（与 fat_chain_map 对齐）----
    output reg  [MAP_AW-1:0] map_rd_addr,
    input  wire [31:0] map_rd_lba,
    input  wire [31:0] map_rd_nsec,
    input  wire [MAP_AW:0] map_count,      // bank 内段数

    // ---- 流控制 ----
    input  wire        str_start,          // 1 拍
    input  wire [31:0] str_file_off,       // 字节偏移
    input  wire [31:0] str_len,            // 字节长度
    input  wire        str_abort,
    input  wire        str_ready,          // 下游可收（突发间隙门控）
    output reg  [7:0]  str_data,
    output reg         str_data_valid,
    output reg         str_done,
    output reg         str_ok,
    output reg         str_error,
    output reg         str_aborted,       // 1 = 因 str_abort 中止（不算错误；seek 用）
    output wire        str_busy,
    output reg  [1:0]  str_retry_used,     // 观测：本轨累计重发次数（0..3 饱和，>0 即发生过 SD 读错）

    // ---- SD 授权式突发读（接 ch0 或 ch1）----
    output reg         blk_req,
    output reg  [31:0] blk_lba,
    output reg  [15:0] blk_count,
    input  wire        blk_grant,
    input  wire [7:0]  blk_data,
    input  wire        blk_data_valid,
    input  wire        blk_end,
    input  wire        blk_error
);

    localparam S_IDLE      = 4'd0;
    localparam S_LOAD_MAP  = 4'd1;
    localparam S_MAP_WAIT  = 4'd2;
    localparam S_PREP      = 4'd3;
    localparam S_REQ       = 4'd4;
    localparam S_WAIT_GNT  = 4'd5;
    localparam S_BURST     = 4'd6;
    localparam S_SKIP      = 4'd7;
    localparam S_NEXT      = 4'd8;
    localparam S_DONE      = 4'd9;
    localparam S_CALC      = 4'd10;
    // 读失败后的退避等待：立刻重发没有意义（卡可能正在恢复），
    // 而环里还有 ~42 ms 音频可播，所以等几 ms 再重发是"无声也无损"的。
    localparam S_RETRY_WAIT= 4'd11;
    localparam S_MAP_CHECK = 4'd12;

    reg [3:0] state;
    reg [MAP_AW-1:0] seg_idx;
    reg [31:0] cur_lba;        // 本段当前 LBA
    reg [23:0] cur_nsec;       // FAT32 <= 4GB: ceil(bytes/512) <= 2^23
    reg [31:0] file_left;      // 文件内剩余字节
    reg [31:0] skip_bytes;     // 本突发前需丢弃的字节（对齐）
    reg [31:0] seg_bytes;      // 段内字节偏移（定位 map 时累计）
    reg        map_rd_pend;
    reg        abort_pend;
    localparam BURST_BITS=(MAX_BURST[15:0]==0) ? 1:$clog2({1'b0,MAX_BURST[15:0]}+1);
    reg [BURST_BITS-1:0] burst_nsec;     // 最近一次发起突发的扇区数（≤MAX_BURST=64）
    reg [23:0] sec_need_r;
    reg skip_segment;
    reg [2:0]  retry_cnt;       // 本记突发已重发次数（0..RETRY_MAX）
    reg [18:0] retry_wait;      // 退避计数器（19 位 = 最多 524287 拍 ≈ 5.24ms）

    assign str_busy = (state != S_IDLE);

    // FAT32 文件 ≤4 GB ⇒ nsec ≤ 2^23，<<9 后恰在 32 位内不溢出
    wire [32:0] seg_span_bytes = {map_rd_nsec[23:0],9'd0};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            seg_idx <= 0;
            cur_lba <= 0;
            cur_nsec <= 0;
            file_left <= 0;
            skip_bytes <= 0;
            seg_bytes <= 0;
            map_rd_addr <= 0;
            map_rd_pend <= 0;
            abort_pend <= 0;
            burst_nsec <= 0;
            sec_need_r <= 0;
            skip_segment <= 0;
            retry_cnt <= 3'd0;
            retry_wait <= 19'd0;
            str_retry_used <= 2'd0;
            blk_req <= 0;
            blk_lba <= 0;
            blk_count <= 0;
            str_data <= 0;
            str_data_valid <= 0;
            str_done <= 0;
            str_ok <= 0;
            str_error <= 0;
            str_aborted <= 0;
        end else begin
            str_data_valid <= 1'b0;
            str_done <= 1'b0;

            if (str_abort && state != S_IDLE) begin
                abort_pend <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    blk_req <= 1'b0;
                    abort_pend <= 1'b0;
                    if (str_start) begin
                        str_ok <= 1'b0;
                        str_error <= 1'b0;
                        str_aborted <= 1'b0;
                        retry_cnt <= 3'd0;         // 新一次播放：重试计数清零
                        retry_wait <= 19'd0;
                        str_retry_used <= 2'd0;
                        file_left <= str_len;
                        skip_bytes <= str_file_off;
                        seg_bytes <= 32'd0;
                        seg_idx <= 0;
                        map_rd_pend <= 1'b0;
                        if (str_len == 0) state <= S_DONE;
                        else if (map_count == 0) begin
                            str_error <= 1'b1;
                            state <= S_DONE;
                        end else state <= S_LOAD_MAP;
                    end
                end

                // 顺序找覆盖 str_file_off 的段
                S_LOAD_MAP: begin
                    if (abort_pend) begin
                        str_aborted <= 1'b1;
                        state <= S_DONE;
                    end else if (seg_idx >= map_count) begin
                        str_error <= 1'b1;
                        state <= S_DONE;
                    end else begin
                        map_rd_addr <= seg_idx;
                        map_rd_pend <= 1'b1;
                        state <= S_MAP_WAIT;
                    end
                end

                S_MAP_WAIT: begin
                    // 读延迟 1 拍
                    map_rd_pend <= 1'b0;
                    state <= S_PREP;
                end

                S_PREP: begin
                    // Separate the BRAM read/compare and arithmetic from the
                    // state selection. A span of exactly 4GB must not wrap.
                    skip_segment <= {1'b0,skip_bytes} >= seg_span_bytes;
                    cur_lba <= map_rd_lba + (skip_bytes >> 9);
                    cur_nsec <= map_rd_nsec[23:0] - skip_bytes[31:9];
                    state <= S_MAP_CHECK;
                end

                S_MAP_CHECK: begin
                    if (abort_pend) begin
                        str_aborted <= 1'b1;
                        state <= S_DONE;
                    end else if (skip_segment) begin
                        skip_bytes <= skip_bytes - seg_span_bytes;
                        seg_bytes  <= seg_bytes + seg_span_bytes;
                        seg_idx    <= seg_idx + 1'b1;
                        state      <= S_LOAD_MAP;
                    end else begin
                        // 本段内定位
                        // 本段还能给的字节 = 段字节 - skip_bytes
                        // 本突发长度（扇区）稍后算
                        // 段内首扇区剩余字节需 skip 部分
                        // 用 skip_bytes[8:0] 作为突发前丢弃
                        state <= S_REQ;
                    end
                end

                S_REQ: begin
                    if (abort_pend) begin
                        str_aborted <= 1'b1;
                        state <= S_DONE;
                    end else if (file_left == 0) begin
                        str_ok <= 1'b1;
                        state <= S_DONE;
                    end else if (cur_nsec == 0) begin
                        seg_idx <= seg_idx + 1'b1;
                        skip_bytes <= 32'd0;
                        seg_bytes <= seg_bytes + seg_span_bytes;
                        state <= S_LOAD_MAP;
                    end else if (!str_ready) begin
                        state <= S_REQ; // 间隙等待反压
                    end else begin
                        // 把 ceil 加法与后续两个 min 比较拆成两拍，满足 100MHz。
                        sec_need_r <= ({1'b0,file_left} + {24'd0,skip_bytes[8:0]} + 33'd511) >> 9;
                        state <= S_CALC;
                    end
                end

                S_CALC: begin : calc_burst
                    reg [15:0] nsec_want;
                    if (abort_pend) begin
                        str_aborted <= 1'b1;
                        state <= S_DONE;
                    end else begin
                        nsec_want = (cur_nsec < MAX_BURST[15:0]) ? cur_nsec[15:0] : MAX_BURST[15:0];
                        if ((sec_need_r != 0) && (sec_need_r < {16'd0, nsec_want}))
                            nsec_want = sec_need_r[15:0];
                        blk_lba   <= cur_lba;
                        blk_count <= nsec_want;
                        blk_req   <= 1'b1;
                        burst_nsec <= nsec_want;
                        state     <= S_WAIT_GNT;
                    end
                end

                S_WAIT_GNT: begin
                    if (blk_grant) begin
                        blk_req <= 1'b0;
                        state   <= S_BURST;
                    end
                    if (blk_error && !blk_grant) begin
                        // ★ 命令/授权阶段失败：一个字节都没收到，重发无副作用
                        blk_req <= 1'b0;
                        if (retry_cnt >= RETRY_MAX[2:0]) begin
                            str_error <= 1'b1;
                            state     <= S_DONE;
                        end else begin
                            retry_cnt      <= retry_cnt + 1'b1;
                            retry_wait     <= 19'd0;
                            str_retry_used <= (str_retry_used == 2'd3) ? 2'd3
                                                                      : str_retry_used + 1'b1;
                            state          <= S_RETRY_WAIT; // 退避后再原样重发
                        end
                    end
                end

                S_BURST: begin
                    if (blk_data_valid) begin
                        if (skip_bytes[8:0] != 0) begin
                            skip_bytes <= skip_bytes - 1'b1;
                        end else if (file_left != 0) begin
                            str_data       <= blk_data;
                            str_data_valid <= 1'b1;
                            file_left      <= file_left - 1'b1;
                        end
                    end
                    if (blk_error) begin
                        str_data_valid <= 1'b0;
                        str_error <= 1'b1;
                        state <= S_DONE;
                    end else if (blk_end) begin
                        state <= S_NEXT;
                    end
                end

                // 退避等待：等 RETRY_WAIT 拍再回 S_REQ 重发。
                // 环里还有 ~42ms 音频，所以这 ~5ms 的停顿听不出来；
                // 期间也认 abort（原代码在突发间隙不认 abort 是一个空档）。
                S_RETRY_WAIT: begin
                    if (abort_pend) begin
                        str_aborted <= 1'b1;
                        state     <= S_DONE;
                    end else if (retry_wait >= RETRY_WAIT[18:0]) begin
                        state <= S_REQ;             // cur_lba/cur_nsec 未推进 → 原样重发
                    end else begin
                        retry_wait <= retry_wait + 1'b1;
                    end
                end

                S_NEXT: begin
                    // 段游标推进：本突发消耗 burst_nsec 个扇区
                    cur_lba  <= cur_lba + {16'd0, burst_nsec};
                    // cur_nsec cannot change between S_CALC and S_NEXT, including
                    // retries and backpressure. Reuse the active cursor.
                    cur_nsec <= cur_nsec - burst_nsec;
                    // 首扇区 skip 只作用于第一次突发
                    if (skip_bytes[8:0] != 0)
                        skip_bytes[8:0] <= 9'd0;
                    state <= S_REQ;
                end

                S_DONE: begin
                    str_done <= 1'b1;
                    blk_req  <= 1'b0;
                    state    <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
