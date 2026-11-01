//=============================================================================
// module : wav_pcm_unpack
// 文件名 : rtl/audio/wav_pcm_unpack.v
// 功  能 : 【PCM 解包】data 载荷 16-bit 小端 PCM → 24-bit 有符号 L/R。
//          单声道复制 L=R；立体声按 L,R 交错。输出对齐契约 2 的样本对
//          （out_valid 一拍 = 一对，与 audio_tone_pcm 同语义）。
//
// 设计要点：
//   1) 小端：先到字节为 16-bit 低 8 位。样本 16-bit 左移 8 位成 24-bit
//      有符号（符号位落在 bit23，数值上等价 sample16<<8）。
//   2) channels=0 单声道（2 字节/样本，L=R）；channels=1 立体声
//      （4 字节/帧：L_lo L_hi R_lo R_hi）。
//   3) start_pulse 清字节对齐计数（新文件 / 头解析完成后对齐）。
//=============================================================================
module wav_pcm_unpack (
    input  wire        clk,
    input  wire        rst,            // 高有效复位（与 fat32_ro 同约定）

    input  wire        start_pulse,    // 1 拍：重新对齐到样本边界
    input  wire        channels,       // 0=mono 1=stereo（来自 wav_header_parse）
    input  wire        byte_valid,
    input  wire [7:0]  byte_data,

    output reg         out_valid,      // 1 拍 = 一对 24bit 样本
    output reg  [23:0] out_left,
    output reg  [23:0] out_right
);

    reg [1:0]  byte_idx;
    reg [7:0]  lo_byte;     // 当前 16-bit 样本低字节
    reg [15:0] smp_left;    // 立体声：完整左样本（等右声道到齐）

    // 本拍收齐一个 16-bit 样本（小端：lo_byte 在前）
    wire [15:0] W_smp16 = {byte_data, lo_byte};
    wire [23:0] W_smp24 = {W_smp16, 8'h00};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            byte_idx  <= 2'd0;
            lo_byte   <= 8'd0;
            smp_left  <= 16'd0;
            out_valid <= 1'b0;
            out_left  <= 24'd0;
            out_right <= 24'd0;
        end
        else begin
            out_valid <= 1'b0;

            if (start_pulse) begin
                // Align to sample boundary. The first payload byte may arrive
                // on the same cycle as start_pulse (header parser and stream
                // are same-cycle handoff); accept it as byte_idx 0.
                byte_idx <= 2'd0;
                lo_byte  <= 8'd0;
                if (byte_valid) begin
                    lo_byte  <= byte_data;
                    byte_idx <= 2'd1;
                end
            end
            else if (byte_valid) begin
                if (!channels) begin
                    // ---- 单声道：2 字节一组，L=R ----
                    if (byte_idx == 2'd0) begin
                        lo_byte  <= byte_data;
                        byte_idx <= 2'd1;
                    end
                    else begin
                        out_valid <= 1'b1;
                        out_left  <= W_smp24;
                        out_right <= W_smp24;
                        byte_idx  <= 2'd0;
                    end
                end
                else begin
                    // ---- 立体声：4 字节一帧（L_lo L_hi R_lo R_hi）----
                    case (byte_idx)
                        2'd0: begin
                            lo_byte  <= byte_data;
                            byte_idx <= 2'd1;
                        end
                        2'd1: begin
                            // 左样本收齐，锁存后等右样本
                            smp_left <= W_smp16;
                            byte_idx <= 2'd2;
                        end
                        2'd2: begin
                            lo_byte  <= byte_data;
                            byte_idx <= 2'd3;
                        end
                        default: begin
                            out_valid <= 1'b1;
                            out_left  <= {smp_left, 8'h00};
                            out_right <= W_smp24;
                            byte_idx  <= 2'd0;
                        end
                    endcase
                end
            end
        end
    end

endmodule
