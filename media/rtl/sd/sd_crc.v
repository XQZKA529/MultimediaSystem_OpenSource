//=============================================================================
// module : sd_crc7 / sd_crc16
// 文件名 : rtl/sd/sd_crc.v
// 功  能 : SD 总线的两个 CRC 生成器（增量式，随收发流水更新，不占组合长路径）
//
//   sd_crc7  —— 命令 CRC，生成多项式 G(x) = x^7 + x^3 + 1（0x09）
//                每次 en 移入 1 bit；对命令帧的 40 bit 载荷
//                （start=0, tx=1, cmd_idx[5:0], arg[31:0]）算出 7 bit 校验。
//   sd_crc16 —— 4-bit 宽总线数据 CRC，生成多项式
//                G(x) = x^16 + x^12 + x^5 + 1（0x1021）。
//                SD 规范要求 DAT0..DAT3 每根线各自计算一个 CRC16；
//                每个 SD 时钟到来时，每根线只移入 1 bit。
//
// 为什么是增量式而不是 40 bit 一次性计算：
//   40 bit 串行 LFSR 是一条约 80 级 XOR 的组合链，在 100 MHz 下建立时间不够；
//   按"发一位/收一位就更新一次"来做，每个时钟只有 1~4 级，时序轻松。
//
// 校验判据（接收侧，父模块使用）：
//   CRC7  —— 载荷 40 bit 收完后 crc 即为期望值，其后 7 个 bit 应依次等于
//            crc[6]、crc[5] … crc[0]（即 crc[46-k]，k 为接收位序号 40..46）
//   CRC16 —— 数据收完后 crc_dat* 即为各 DAT 线的期望值，
//            其后 16 个 SD 时钟依次传输各路 CRC[15]..CRC[0]。
//=============================================================================

//-----------------------------------------------------------------------------
// CRC7：逐 bit 更新
//-----------------------------------------------------------------------------
module sd_crc7(
    input  wire       clk,
    input  wire       rst,      // 异步复位，高有效
    input  wire       clr,      // 同步清零（1 拍）
    input  wire       en,       // 移入使能（1 拍 = 1 bit）
    input  wire       bit_in,   // 本拍移入的 bit
    output reg [6:0]  crc
);

    // t = crc[6] ^ bit_in 时做一次 G(x) 除法；等价于 crc = (crc<<1) ^ 0x09
    wire t = crc[6] ^ bit_in;
    wire [6:0] crc_nxt = {crc[5:0], t} ^ {3'b000, t, 3'b000};

    always @(posedge clk or posedge rst) begin
        if (rst)
            crc <= 7'd0;
        else if (clr)
            crc <= 7'd0;
        else if (en)
            crc <= crc_nxt;
    end

endmodule


//-----------------------------------------------------------------------------
// CRC16：DAT0..DAT3 四路独立、每路逐 bit 更新
//-----------------------------------------------------------------------------
module sd_crc16(
    input  wire        clk,
    input  wire        rst,      // 异步复位，高有效
    input  wire        clr,      // 同步清零（1 拍）
    input  wire        en,       // 移入使能（1 拍 = 每根 DAT 线各 1 bit）
    input  wire [3:0]  dat_in,
    output reg [15:0]  crc_dat0,
    output reg [15:0]  crc_dat1,
    output reg [15:0]  crc_dat2,
    output reg [15:0]  crc_dat3
);

    // 单 bit 一步：crc = (crc<<1) ^ (t ? 0x1021 : 0)
    function [15:0] crc16_step;
        input [15:0] c;
        input        b;
        reg          t;
        begin
            t          = c[15] ^ b;
            crc16_step = {c[14:0], 1'b0} ^ (t ? 16'h1021 : 16'h0000);
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            crc_dat0 <= 16'd0;
            crc_dat1 <= 16'd0;
            crc_dat2 <= 16'd0;
            crc_dat3 <= 16'd0;
        end else if (clr) begin
            crc_dat0 <= 16'd0;
            crc_dat1 <= 16'd0;
            crc_dat2 <= 16'd0;
            crc_dat3 <= 16'd0;
        end else if (en) begin
            crc_dat0 <= crc16_step(crc_dat0, dat_in[0]);
            crc_dat1 <= crc16_step(crc_dat1, dat_in[1]);
            crc_dat2 <= crc16_step(crc_dat2, dat_in[2]);
            crc_dat3 <= crc16_step(crc_dat3, dat_in[3]);
        end
    end

endmodule
