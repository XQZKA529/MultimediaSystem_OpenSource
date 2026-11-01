//=============================================================================
// module : audio_ring_bram
// 文件名 : rtl/audio/audio_ring_bram.v
// 功  能 : 【音频缓冲层】简单双时钟 BRAM 弹性 FIFO。
//          写口可挂在 sd_card_clk / write_clk（unpack 写入），
//          读口挂在 video_clk 75MHz（audio_wav_pcm 取样），
//          也可作为 audio_sdma_ring 内部与 SDRAM 突发引擎之间的弹性级。
//
// 设计要点：
//   1) 推断式真双口 BRAM（reg 数组 + 双时钟），风格对齐 fat32_ro.sector_buf，
//      不依赖 EG_LOGIC_RAMFIFO / wfifo_*，便于 ModelSim 行为仿真。
//   2) 读写指针转 Gray 码后 2FF 同步（对齐 afifo_* 的跨时钟习惯），
//      各时钟域给出独立水位 wr_level / rd_level。
//   3) 读时序为标准同步 FIFO：
//        rd_en=1 且 !rd_empty → 下一拍 rd_valid=1 且 rd_data 为弹出字。
//   4) almost_full / almost_empty 为水位比较输出，供上层做回填/反压。
//
// 打包约定（本工程音频环统一）：
//   DATA_WIDTH 默认 32：一字 = 一对 16bit 立体声样本 {L[15:0], R[15:0]}，
//   L 在高半字（[31:16]），R 在低半字（[15:0]）。见 audio_sdma_ring.v。
//=============================================================================
module audio_ring_bram #(
    parameter DATA_WIDTH    = 32,
    parameter ADDR_WIDTH    = 11,                   // 默认 2048 字 = 8KB @32bit
    parameter AL_FULL_NUM   = (1<<ADDR_WIDTH) - 32, // 写侧 almost_full 阈值
    parameter AL_EMPTY_NUM  = 8                     // 读侧 almost_empty 阈值
)(
    // ---- 写时钟域 ----
    input  wire                    wr_clk,
    input  wire                    wr_rst_n,       // 低有效（本工程统一约定）
    input  wire                    wr_en,
    input  wire [DATA_WIDTH-1:0]   wr_data,
    output wire                    wr_full,
    output wire [ADDR_WIDTH:0]     wr_level,       // 写侧可见占用 0..DEPTH
    output wire                    almost_full,

    // ---- 读时钟域 ----
    input  wire                    rd_clk,
    input  wire                    rd_rst_n,
    input  wire                    rd_en,
    output reg  [DATA_WIDTH-1:0]   rd_data,
    output reg                     rd_valid,       // 弹出成功后的 1 拍数据有效
    output wire                    rd_empty,
    output wire [ADDR_WIDTH:0]     rd_level,       // 读侧可见可读字数 0..DEPTH
    output wire                    almost_empty
);

    localparam [ADDR_WIDTH:0] DEPTH_C   = (1 << ADDR_WIDTH);
    localparam [ADDR_WIDTH:0] AFULL_C   = AL_FULL_NUM;
    localparam [ADDR_WIDTH:0] AEMPTY_C  = AL_EMPTY_NUM;

    //--------------------------------------------------------------------------
    // 存储体：推断 BRAM（简单双口，写口写、读口读）
    //--------------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1] /* fehdl force_ram=1, ram_style="bram" */;

    //--------------------------------------------------------------------------
    // 二进制 / Gray 指针与跨时钟同步
    //--------------------------------------------------------------------------
    reg  [ADDR_WIDTH:0] wr_ptr_bin, wr_ptr_gray;
    reg  [ADDR_WIDTH:0] rd_ptr_bin, rd_ptr_gray;
    reg  [ADDR_WIDTH:0] wr_ptr_gray_s1, wr_ptr_gray_s2;  // rd_ptr → wr 域
    reg  [ADDR_WIDTH:0] rd_ptr_gray_s1, rd_ptr_gray_s2;  // wr_ptr → rd 域

    function [ADDR_WIDTH:0] bin2gray;
        input [ADDR_WIDTH:0] b;
        begin
            bin2gray = b ^ (b >> 1);
        end
    endfunction

    function [ADDR_WIDTH:0] gray2bin;
        input [ADDR_WIDTH:0] g;
        integer i;
        begin
            gray2bin[ADDR_WIDTH] = g[ADDR_WIDTH];
            for (i = ADDR_WIDTH-1; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    wire [ADDR_WIDTH:0] wr_ptr_bin_nxt  = wr_ptr_bin + 1'b1;
    wire [ADDR_WIDTH:0] rd_ptr_bin_nxt  = rd_ptr_bin + 1'b1;
    wire                wr_do           = wr_en && !wr_full;
    wire                rd_do           = rd_en && !rd_empty;

    // 同步后的对端指针（二进制）
    wire [ADDR_WIDTH:0] rd_ptr_in_wr = gray2bin(wr_ptr_gray_s2);
    wire [ADDR_WIDTH:0] wr_ptr_in_rd = gray2bin(rd_ptr_gray_s2);

    // 占用：指针宽度多 1 bit，可区分 full / empty
    assign wr_level = wr_ptr_bin - rd_ptr_in_wr;
    assign rd_level = wr_ptr_in_rd - rd_ptr_bin;
    assign wr_full  = (wr_level >= DEPTH_C);
    assign rd_empty = (rd_ptr_gray == rd_ptr_gray_s2);

    assign almost_full  = (wr_level >= AFULL_C);
    assign almost_empty = (rd_level <= AEMPTY_C);

    //--------------------------------------------------------------------------
    // 写口
    //--------------------------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin  <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
        end else if (wr_do) begin
            wr_ptr_bin  <= wr_ptr_bin_nxt;
            wr_ptr_gray <= bin2gray(wr_ptr_bin_nxt);
        end
    end

    always @(posedge wr_clk) begin
        if (wr_do)
            mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
    end

    // rd 指针 → wr 域
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_gray_s1 <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray_s2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            wr_ptr_gray_s1 <= rd_ptr_gray;
            wr_ptr_gray_s2 <= wr_ptr_gray_s1;
        end
    end

    //--------------------------------------------------------------------------
    // 读口（标准同步读：rd_valid 相对 rd_en 延迟 1 拍）
    //--------------------------------------------------------------------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin  <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
            rd_data     <= {DATA_WIDTH{1'b0}};
            rd_valid    <= 1'b0;
        end else begin
            rd_valid <= 1'b0;
            if (rd_do) begin
                rd_ptr_bin  <= rd_ptr_bin_nxt;
                rd_ptr_gray <= bin2gray(rd_ptr_bin_nxt);
                rd_data     <= mem[rd_ptr_bin[ADDR_WIDTH-1:0]];
                rd_valid    <= 1'b1;
            end
        end
    end

    // wr 指针 → rd 域
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_gray_s1 <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray_s2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            rd_ptr_gray_s1 <= wr_ptr_gray;
            rd_ptr_gray_s2 <= rd_ptr_gray_s1;
        end
    end

endmodule
