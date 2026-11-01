//=============================================================================
// module : wav_header_parse
// 文件名 : rtl/audio/wav_header_parse.v
// 功  能 : 【WAV 头解析】纯字节流 RIFF/WAVE 解析器。
//          跳过未知块（LIST / fact / ...），定位 `fmt ` 与 `data`，
//          抽出 PCM 参数与 data 载荷起始偏移。
//
// 设计要点：
//   1) 纯字节流：byte_valid/byte_data 逐字节送入，与 FAT/LBA 文件流解耦。
//      start_pulse 重新开始解析（换文件时对齐）。
//   2) 仅接受：wFormatTag=1(PCM)、nSamplesPerSec=48000、
//      wBitsPerSample=16、nChannels=1 或 2（见 spec [S2].4）。
//   3) 块结构：允许 fmt 与 data 之间夹 LIST 等；未知块按 chunk size
//      跳过（奇数 size 再跳 1 字节 RIFF pad）。
//   4) 成功时 parse_done + payload_start 同拍脉冲；此后流上的下一个
//      byte 即 PCM 载荷（本模块不再消费）。
//
// reject_code：
//   0=OK  1=not RIFF  2=not WAVE  3=fmt 缺失/data 先于 fmt
//   4=wFormatTag!=1  5=采样率!=48000  6=位深!=16  7=声道非 1/2
//   8=fmt 块过短(<16)
//=============================================================================
module wav_header_parse (
    input  wire        clk,
    input  wire        rst,                // 高有效复位（与 fat32_ro 同约定）

    input  wire        start_pulse,        // 1 拍：重新开始解析
    input  wire        byte_valid,
    input  wire [7:0]  byte_data,

    output reg         parse_done,         // 1 拍：解析结束（成败皆发）
    output reg         parse_ok,
    output reg  [3:0]  reject_code,
    output reg  [31:0] data_byte_offset,   // 文件内 PCM 载荷字节偏移
    output reg  [31:0] data_byte_len,      // data 块 chunk size
    output reg         channels,           // 0=mono 1=stereo
    output reg         payload_start       // 1 拍：头结束，下一字节即 PCM
);

    localparam S_IDLE     = 4'd0;
    localparam S_RIFF     = 4'd1;
    localparam S_RIFF_SZ  = 4'd2;
    localparam S_WAVE     = 4'd3;
    localparam S_CHUNK_ID = 4'd4;
    localparam S_CHUNK_SZ = 4'd5;
    localparam S_FMT      = 4'd6;
    localparam S_SKIP     = 4'd7;

    localparam [3:0] REJ_OK        = 4'd0;
    localparam [3:0] REJ_NOT_RIFF  = 4'd1;
    localparam [3:0] REJ_NOT_WAVE  = 4'd2;
    localparam [3:0] REJ_NO_FMT    = 4'd3;
    localparam [3:0] REJ_BAD_TAG   = 4'd4;
    localparam [3:0] REJ_BAD_RATE  = 4'd5;
    localparam [3:0] REJ_BAD_BITS  = 4'd6;
    localparam [3:0] REJ_BAD_CH    = 4'd7;
    localparam [3:0] REJ_FMT_SHORT = 4'd8;

    reg [3:0]  state;
    reg [1:0]  byte_idx;
    reg prefix_ok,chunk_is_fmt,chunk_is_data;
    reg [31:0] chunk_size;
    reg [31:0] skip_left;
    reg [31:0] file_off;            // 已消费字节数（下一字节偏移）
    reg [4:0]  fmt_idx;
    // Only the supported-format predicates are consumed at byte 15.
    // Keep them separately to retain the original rejection priority.
    reg fmt_tag_ok,fmt_mono,fmt_stereo,fmt_rate_ok,fmt_bits_low_ok;
    reg        fmt_seen;
    reg        fmt_ok;

    //--------------------------------------------------------------------------
    // 组合：本拍到达的 chunk size（小端拼装）
    //--------------------------------------------------------------------------
    wire [31:0] W_off_next  = file_off + 32'd1;
    // size 四字节：b0(LSB)..b3(MSB)，本拍 byte_data 为最高字节
    wire [31:0] W_csize     = {byte_data, chunk_size[31:8]};
    wire        W_size_odd  = W_csize[0];
    wire [31:0] W_skip_raw  = W_csize + {31'd0, W_size_odd};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= S_IDLE;
            byte_idx         <= 2'd0;
            prefix_ok        <= 1'b0;
            chunk_is_fmt     <= 1'b0;
            chunk_is_data    <= 1'b0;
            chunk_size       <= 32'd0;
            skip_left        <= 32'd0;
            file_off         <= 32'd0;
            fmt_idx          <= 5'd0;
            fmt_tag_ok       <= 1'b0;
            fmt_mono         <= 1'b0;
            fmt_stereo       <= 1'b0;
            fmt_rate_ok      <= 1'b0;
            fmt_bits_low_ok  <= 1'b0;
            fmt_seen         <= 1'b0;
            fmt_ok           <= 1'b0;
            parse_done       <= 1'b0;
            parse_ok         <= 1'b0;
            reject_code      <= REJ_OK;
            data_byte_offset <= 32'd0;
            data_byte_len    <= 32'd0;
            channels         <= 1'b0;
            payload_start    <= 1'b0;
        end
        else begin
            parse_done    <= 1'b0;
            payload_start <= 1'b0;

            if (start_pulse) begin
                // ---- 换文件 / 重新对齐：清空解析现场 ----
                state    <= S_RIFF;
                byte_idx <= 2'd0;
                prefix_ok<=1'b0;chunk_is_fmt<=1'b0;chunk_is_data<=1'b0;
                file_off <= 32'd0;
                fmt_idx  <= 5'd0;
                fmt_seen <= 1'b0;
                fmt_ok   <= 1'b0;
                parse_ok <= 1'b0;
                reject_code <= REJ_OK;
                data_byte_offset <= 32'd0;
                data_byte_len    <= 32'd0;
                channels         <= 1'b0;
            end
            else if (byte_valid && state != S_IDLE) begin
                file_off <= W_off_next;
                case (state)
                    //----------------------------------------------------------
                    // "RIFF" / "WAVE"：逐字节匹配，第四字节给出结果
                    //----------------------------------------------------------
                    S_RIFF: begin
                        if (byte_idx == 2'd3) begin
                            byte_idx <= 2'd0;
                            if (!prefix_ok || byte_data!="F") begin
                                parse_done  <= 1'b1;
                                parse_ok    <= 1'b0;
                                reject_code <= REJ_NOT_RIFF;
                                state       <= S_IDLE;
                            end
                            else begin
                                state <= S_RIFF_SZ;
                            end
                        end
                        else begin
                            if(byte_idx==0) prefix_ok<=byte_data=="R";
                            else prefix_ok<=prefix_ok && ((byte_idx==1) ? byte_data=="I":byte_data=="F");
                            byte_idx <= byte_idx + 2'd1;
                        end
                    end

                    S_RIFF_SZ: begin
                        // RIFF size 不参与判定，吞掉即可
                        if (byte_idx == 2'd3) begin
                            byte_idx <= 2'd0;
                            state    <= S_WAVE;
                        end
                        else begin
                            byte_idx <= byte_idx + 2'd1;
                        end
                    end

                    S_WAVE: begin
                        if (byte_idx == 2'd3) begin
                            byte_idx <= 2'd0;
                            if (!prefix_ok || byte_data!="E") begin
                                parse_done  <= 1'b1;
                                parse_ok    <= 1'b0;
                                reject_code <= REJ_NOT_WAVE;
                                state       <= S_IDLE;
                            end
                            else begin
                                state <= S_CHUNK_ID;
                            end
                        end
                        else begin
                            if(byte_idx==0) prefix_ok<=byte_data=="W";
                            else prefix_ok<=prefix_ok && ((byte_idx==1) ? byte_data=="A":byte_data=="V");
                            byte_idx <= byte_idx + 2'd1;
                        end
                    end

                    //----------------------------------------------------------
                    // 块头：ID(4) + size(4)，随后按 ID 分流
                    //----------------------------------------------------------
                    S_CHUNK_ID: begin
                        case(byte_idx)
                            0:begin chunk_is_fmt<=byte_data=="f";chunk_is_data<=byte_data=="d";end
                            1:begin chunk_is_fmt<=chunk_is_fmt && byte_data=="m";chunk_is_data<=chunk_is_data && byte_data=="a";end
                            2:begin chunk_is_fmt<=chunk_is_fmt && byte_data=="t";chunk_is_data<=chunk_is_data && byte_data=="t";end
                            3:begin chunk_is_fmt<=chunk_is_fmt && byte_data==" ";chunk_is_data<=chunk_is_data && byte_data=="a";end
                        endcase
                        if (byte_idx == 2'd3) begin
                            byte_idx <= 2'd0;
                            state    <= S_CHUNK_SZ;
                        end
                        else begin
                            byte_idx <= byte_idx + 2'd1;
                        end
                    end

                    S_CHUNK_SZ: begin
                        // 小端 chunk size，第 4 字节到齐后分流
                        chunk_size <= W_csize;
                        if (byte_idx == 2'd3) begin
                            byte_idx <= 2'd0;
                            if (chunk_is_fmt) begin
                                if (W_csize < 32'd16) begin
                                    parse_done  <= 1'b1;
                                    parse_ok    <= 1'b0;
                                    reject_code <= REJ_FMT_SHORT;
                                    state       <= S_IDLE;
                                end
                                else begin
                                    fmt_idx <= 5'd0;
                                    state   <= S_FMT;
                                end
                            end
                            else if (chunk_is_data) begin
                                if (!fmt_ok) begin
                                    parse_done  <= 1'b1;
                                    parse_ok    <= 1'b0;
                                    reject_code <= REJ_NO_FMT;
                                    state       <= S_IDLE;
                                end
                                else begin
                                    // 头结束：下一字节即 PCM
                                    data_byte_offset <= W_off_next;
                                    data_byte_len    <= W_csize;
                                    parse_done       <= 1'b1;
                                    parse_ok         <= 1'b1;
                                    reject_code      <= REJ_OK;
                                    payload_start    <= 1'b1;
                                    state            <= S_IDLE;
                                end
                            end
                            else begin
                                // 未知块（LIST/fact/...）：size + 奇数 pad
                                // Rounded size wraps to zero for exactly these two inputs.
                                if (W_csize == 32'd0 || W_csize == 32'hffffffff)
                                    state <= S_CHUNK_ID;
                                else begin
                                    skip_left <= W_skip_raw;
                                    state     <= S_SKIP;
                                end
                            end
                        end
                        else begin
                            chunk_size <= W_csize;
                            byte_idx   <= byte_idx + 2'd1;
                        end
                    end

                    //----------------------------------------------------------
                    // fmt 块体：固定 16 字节 PCM 基本字段（小端）
                    // 0:tagL 1:tagH 2:chL 3:chH 4..7:rate 8..11:avg
                    // 12..13:align 14:bitsL 15:bitsH
                    //----------------------------------------------------------
                    S_FMT: begin
                        case (fmt_idx)
                            5'd0:  fmt_tag_ok<=byte_data==8'd1;
                            5'd1:  fmt_tag_ok<=fmt_tag_ok && byte_data==8'd0;
                            5'd2:  begin fmt_mono<=byte_data==8'd1;fmt_stereo<=byte_data==8'd2;end
                            5'd3:  begin fmt_mono<=fmt_mono && byte_data==8'd0;fmt_stereo<=fmt_stereo && byte_data==8'd0;end
                            5'd4:  fmt_rate_ok<=byte_data==8'h80;
                            5'd5:  fmt_rate_ok<=fmt_rate_ok && byte_data==8'hbb;
                            5'd6,5'd7: fmt_rate_ok<=fmt_rate_ok && byte_data==8'd0;
                            5'd14: fmt_bits_low_ok<=byte_data==8'd16;
                            default: ;
                        endcase

                        if (fmt_idx == 5'd15) begin
                            fmt_seen <= 1'b1;
                            // bits 高字节本拍到达，直接参与校验
                            if (!fmt_tag_ok) begin
                                parse_done  <= 1'b1;
                                parse_ok    <= 1'b0;
                                reject_code <= REJ_BAD_TAG;
                                state       <= S_IDLE;
                            end
                            else if (!fmt_rate_ok) begin
                                parse_done  <= 1'b1;
                                parse_ok    <= 1'b0;
                                reject_code <= REJ_BAD_RATE;
                                state       <= S_IDLE;
                            end
                            else if (byte_data!=8'd0 || !fmt_bits_low_ok) begin
                                parse_done  <= 1'b1;
                                parse_ok    <= 1'b0;
                                reject_code <= REJ_BAD_BITS;
                                state       <= S_IDLE;
                            end
                            else if (!fmt_mono && !fmt_stereo) begin
                                parse_done  <= 1'b1;
                                parse_ok    <= 1'b0;
                                reject_code <= REJ_BAD_CH;
                                state       <= S_IDLE;
                            end
                            else begin
                                fmt_ok   <= 1'b1;
                                channels <= fmt_stereo;
                                // 剩余扩展字节 + 奇数 pad
                                if (chunk_size > 32'd16) begin
                                    skip_left <= (chunk_size - 32'd16)
                                                 + {31'd0, chunk_size[0]};
                                    state <= S_SKIP;
                                end
                                else begin
                                    state <= S_CHUNK_ID;
                                end
                            end
                        end
                        else begin
                            fmt_idx <= fmt_idx + 5'd1;
                        end
                    end

                    //----------------------------------------------------------
                    // 跳过未知块数据 / fmt 扩展
                    //----------------------------------------------------------
                    S_SKIP: begin
                        if (skip_left <= 32'd1) begin
                            skip_left <= 32'd0;
                            byte_idx  <= 2'd0;
                            state     <= S_CHUNK_ID;
                        end
                        else begin
                            skip_left <= skip_left - 32'd1;
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
