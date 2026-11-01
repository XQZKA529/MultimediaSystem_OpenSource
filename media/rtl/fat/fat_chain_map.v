//=============================================================================
// module : fat_chain_map
// 文件名 : rtl/fat/fat_chain_map.v
// 功  能 : 簇链→LBA 段表双 bank BRAM。walker（fat32_ro map 模式）写入连续段
//          {start_lba, nsec}；lba_stream 只读查表。物理 SD 仍单路，段表使
//          多文件可各自持有 LBA 游标、轮流突发（ch0/ch1）。
//
//  bank 0 = 图像 / bank 1 = 音频（约定，模块本身不关心语义）
//  归属宏唯一出处：rtl/pkg/video_bmp_params.vh（VBP_MAP_BANK_IMG/WAV）。
//  写口与读口均为同步 BRAM 读（下拍出数据）。
//=============================================================================
module fat_chain_map #(
    parameter integer MAP_DEPTH = 256,
    parameter integer MAP_AW    = 8
)(
    input  wire        clk,
    input  wire        rst,

    // ---- walker 写口（sd_card_clk）----
    input  wire        wr_bank,            // 0/1
    input  wire        wr_clear,           // 1 拍：清零该 bank 条目计数
    input  wire        wr_en,              // 1 拍：写入一段
    input  wire [31:0] wr_lba,
    input  wire [31:0] wr_nsec,
    output reg  [MAP_AW:0] wr_count,       // 当前 bank 已写入段数（写后有效）
    output reg         wr_overflow,        // bug4: sticky — write beyond MAP_DEPTH (C1 error)

    // ---- stream 读口 0（同步读：addr 本拍，q 下拍）----
    input  wire        rd_bank,
    input  wire [MAP_AW-1:0] rd_addr,
    output reg  [31:0] rd_lba,
    output reg  [31:0] rd_nsec,
    input  wire [MAP_AW:0] rd_count_sel,   // 可选：外部锁存的段数；也可由 stream 自带
    output reg  [MAP_AW:0] count0,
    output reg  [MAP_AW:0] count1,

    // ---- stream 读口 1（双流并存：stream0/1 各占一读口）----
    input  wire        rd2_bank,
    input  wire [MAP_AW-1:0] rd2_addr,
    output reg  [31:0] rd2_lba,
    output reg  [31:0] rd2_nsec
);

    // 打包存储：{nsec[31:0], lba[31:0]} → 64 bit（nsec 全链 32 位，修复 >32MiB 连续段静默回绕）
    reg [63:0] mem0 [0:MAP_DEPTH-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [63:0] mem1 [0:MAP_DEPTH-1] /* fehdl force_ram=1, ram_style="bram" */;

    reg [MAP_AW:0] wr_ptr;
    wire [MAP_AW:0] wr_count_next = wr_count + 1'b1;

    always @(posedge clk) begin
        if (rd_bank) begin
            {rd_nsec, rd_lba} <= mem1[rd_addr];
        end else begin
            {rd_nsec, rd_lba} <= mem0[rd_addr];
        end
        if (rd2_bank) begin
            {rd2_nsec, rd2_lba} <= mem1[rd2_addr];
        end else begin
            {rd2_nsec, rd2_lba} <= mem0[rd2_addr];
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_count <= 0;
            count0   <= 0;
            count1   <= 0;
            wr_ptr   <= 0;
            wr_overflow <= 1'b0;
        end else begin
            if (wr_clear) begin
                wr_ptr <= 0;
                if (wr_bank) count1 <= 0;
                else         count0 <= 0;
                wr_count <= 0;
                wr_overflow <= 1'b0;
            end else if (wr_en) begin
                if (wr_bank) begin
                    if (wr_ptr < MAP_DEPTH) begin
                        mem1[wr_ptr[MAP_AW-1:0]] <= {wr_nsec, wr_lba};
                        wr_ptr   <= wr_ptr + 1'b1;
                        count1   <= wr_count_next;
                        wr_count <= wr_count_next;
                    end else begin
                        wr_overflow <= 1'b1;   // C1: overflow is an error
                    end
                end else begin
                    if (wr_ptr < MAP_DEPTH) begin
                        mem0[wr_ptr[MAP_AW-1:0]] <= {wr_nsec, wr_lba};
                        wr_ptr   <= wr_ptr + 1'b1;
                        count0   <= wr_count_next;
                        wr_count <= wr_count_next;
                    end else begin
                        wr_overflow <= 1'b1;   // C1: overflow is an error
                    end
                end
            end
        end
    end

endmodule
