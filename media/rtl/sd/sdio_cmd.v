//=============================================================================
// module : sdio_cmd
// 文件名 : rtl/sd/sdio_cmd.v
// 功  能 : 【SDIO 命令层】发送 48 bit 命令帧、接收并解析卡的响应
//
//  一、命令帧（48 bit，CMD 线上 MSB 先发）
//        bit47      = 0        起始位
//        bit46      = 1        传输位
//        bit45:40   = cmd_idx  命令号
//        bit39:8    = cmd_arg  参数
//        bit7:1     = CRC7     对 bit47..8 这 40 bit 求 CRC7
//        bit0       = 1        结束位
//      CRC7 用"发一位就更新一次"的增量算法（见 sd_crc.v），载荷发完时
//      累加器刚好装好正确值，再把它装进 crc_sr 逐位移出，全程无长组合路径、
//      也没有可变下标取位（避免越界取到 x）。
//
//  二、响应类型（resp_type）
//        0 = 无响应      （CMD0）
//        1 = R1 / R6     （48 bit，带 CRC7，做校验）
//        2 = R3 / R7     （48 bit，CRC 不可靠，不校验）
//        3 = R2          （136 bit，CID/CSD，只收不解析）
//      48 bit 响应解析：sr[47]=起始位 sr[46]=传输位
//                       sr[45:40]=命令号 sr[39:8]=状态/参数 sr[7:1]=CRC7 sr[0]=结束位
//
//  三、时序（与 SD 规范一致）
//      - 主机在 SD_CLK 下降沿驱动 CMD（ck_fall 节拍）
//      - 主机在 SD_CLK 上升沿采样 CMD（ck_rise 节拍）
//      - 发命令前给 8 个空闲时钟，命令结束后给 8 个空闲时钟
//      - 发完结束位后释放 CMD 总线，等卡的起始位；NCR 超时用 resp_timeout 保护
//      - 命令后置空闲期间主动把 CMD 驱高（比只靠 10K 上拉爬升快得多）
//=============================================================================
module sdio_cmd(
    input  wire         clk,
    input  wire         rst,          // 异步复位，高有效
    input  wire         ck_rise,      // 见 sdio_phy
    input  wire         ck_fall,

    // ---- 命令请求 ----
    input  wire         issue,        // 1 拍脉冲：发起一条命令
    input  wire [5:0]   cmd_idx,
    input  wire [31:0]  cmd_arg,
    input  wire [1:0]   resp_type,
    input  wire [15:0]  resp_timeout, // NCR 等待上限（SD 时钟数）

    // ---- 结果 ----
    output reg          busy,
    output reg          done,         // 1 拍脉冲：本次命令（含响应）结束
    output reg          no_resp,      // 等待响应超时
    output reg          crc_err,      // 响应 CRC7 校验失败
    output reg          end_bad,      // 响应结束位不是 1（一般只做观察）
    output reg  [5:0]   resp_cmd,     // 响应里的命令号
    output reg  [31:0]  resp_arg,     // 响应里的 32 bit 参数/状态
    output reg  [135:0] resp_r2,      // R2 原始 136 bit

    // ---- CMD 线 ----
    output reg          cmd_oe,       // 1 = 主机驱动
    output reg          cmd_out,
    input  wire         cmd_in,

    // ---- 调试 ----
    output wire [3:0]   dbg_state,
    output reg  [15:0]  dbg_tmo_clk
);

    localparam S_IDLE = 3'd0;
    localparam S_PRE  = 3'd1;   // 8 个空闲时钟
    localparam S_SEND = 3'd2;   // 48 bit 命令帧
    localparam S_TURN = 3'd3;   // 总线转向（释放 CMD）
    localparam S_WAIT = 3'd4;   // 等响应起始位
    localparam S_RECV = 3'd5;   // 收 48 / 136 bit
    localparam S_POST = 3'd6;   // 8 个空闲时钟

    // Keep the raw SD input out of a binary next-state priority encoder.
    // Public/legacy diagnostics retain the original 0..6 state numbers.
    reg [6:0] command_hot;
    wire [2:0] state={
        command_hot[S_WAIT] | command_hot[S_RECV] | command_hot[S_POST],
        command_hot[S_SEND] | command_hot[S_TURN] | command_hot[S_POST],
        command_hot[S_PRE] | command_hot[S_TURN] | command_hot[S_RECV]};
    reg [3:0]  idle_cnt;
    reg [5:0]  tx_cnt;      // 47 → 0
    reg [7:0]  rx_cnt;
    reg        tmo_en;
    reg [15:0] tmo_cnt;

    reg [39:0]  tx_sr;      // 命令帧前 40 bit：{start=0, tx=1, cmd_idx, arg}
    reg [6:0]   crc_sr;     // CRC7 字段的移出寄存器
    reg         crc_load;
    reg [47:0]  sr;         // 48 bit 响应移位寄存器
    reg [1:0]   rtype;

    reg         crc_clr_tx, crc_en_tx, crc_bit_tx;
    reg         crc_clr_rx, crc_en_rx, crc_bit_rx;
    wire [6:0]  crc7_tx;
    wire [6:0]  crc7_rx;

    reg         crc_bad;

    // crc7_tx 在子模块中也是用非阻塞赋值更新的。发送第 40 个
    // 载荷 bit 后的下一个 clk，crc7_tx 仍是只包含前 39 bit 的旧值；
    // 因此装入移位寄存器时必须显式再计算最后一位。
    wire        crc7_tx_fb    = crc7_tx[6] ^ crc_bit_tx;
    wire [6:0]  crc7_tx_final = {crc7_tx[5:0], crc7_tx_fb} ^
                                 {3'b000, crc7_tx_fb, 3'b000};

    assign dbg_state = {1'b0, state};

    sd_crc7 u_crc_tx (
        .clk(clk), .rst(rst), .clr(crc_clr_tx), .en(crc_en_tx),
        .bit_in(crc_bit_tx), .crc(crc7_tx)
    );

    sd_crc7 u_crc_rx (
        .clk(clk), .rst(rst), .clr(crc_clr_rx), .en(crc_en_rx),
        .bit_in(crc_bit_rx), .crc(crc7_rx)
    );

    // 本拍要驱动到 CMD 线上的值
    wire tx_bit = (tx_cnt >= 6'd8) ? tx_sr[39] :          // 帧前 40 bit（MSB 先）
                  (tx_cnt >= 6'd1) ? crc_sr[6] :          // CRC7 字段（MSB 先）
                                     1'b1;                // 结束位

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            command_hot <= (7'b1<<S_IDLE);
            busy        <= 1'b0;
            done        <= 1'b0;
            no_resp     <= 1'b0;
            crc_err     <= 1'b0;
            end_bad     <= 1'b0;
            resp_cmd    <= 6'd0;
            resp_arg    <= 32'd0;
            resp_r2     <= 136'd0;
            cmd_oe      <= 1'b0;
            cmd_out     <= 1'b1;
            idle_cnt    <= 4'd0;
            tx_cnt      <= 6'd0;
            rx_cnt      <= 8'd0;
            tmo_en      <= 1'b0;
            tmo_cnt     <= 16'd0;
            tx_sr       <= 40'd0;
            crc_sr      <= 7'd0;
            crc_load    <= 1'b0;
            sr          <= 48'd0;
            rtype       <= 2'd0;
            crc_clr_tx  <= 1'b0;
            crc_en_tx   <= 1'b0;
            crc_bit_tx  <= 1'b0;
            crc_clr_rx  <= 1'b0;
            crc_en_rx   <= 1'b0;
            crc_bit_rx  <= 1'b0;
            crc_bad     <= 1'b0;
            dbg_tmo_clk <= 16'd0;
        end else begin
            done       <= 1'b0;
            no_resp    <= 1'b0;
            crc_clr_tx <= 1'b0;
            crc_en_tx  <= 1'b0;
            crc_clr_rx <= 1'b0;
            crc_en_rx  <= 1'b0;

            // CRC7 载荷累加完毕后装进移出寄存器（比 ck_fall 晚 1 拍，确保已收敛）
            if (crc_load) begin
                crc_sr   <= crc7_tx_final;
                crc_load <= 1'b0;
            end

            // resp_timeout 的单位是 SD_CLK，不是 100MHz 系统 clk。
            if (tmo_en && ck_rise) begin
                tmo_cnt     <= tmo_cnt + 16'd1;
                dbg_tmo_clk <= tmo_cnt;
            end

            case (1'b1) // synthesis parallel_case

            //---------------------------------------------------------------
            command_hot[S_IDLE]: begin
                busy    <= 1'b0;
                // 空闲态主动把 CMD 驱高：① 满足"初始化前 ≥74 个时钟 CMD 为高"；
                // ② 比只靠卡座 10K 上拉爬升快得多（上拉约 100ns 才到高电平）
                cmd_oe  <= 1'b1;
                cmd_out <= 1'b1;
                tmo_en  <= 1'b0;
                if (issue) begin
                    tx_sr   <= {1'b0, 1'b1, cmd_idx, cmd_arg};
                    rtype   <= resp_type;
                    busy    <= 1'b1;
                    cmd_oe  <= 1'b1;     // 起始位之前必须先把 CMD 驱高
                    cmd_out <= 1'b1;
                    idle_cnt<= 4'd0;
                    crc_bad <= 1'b0;
                    crc_err <= 1'b0;
                    end_bad <= 1'b0;
                    tmo_cnt <= 16'd0;
                    dbg_tmo_clk <= 16'd0;
                    command_hot <= (7'b1<<S_PRE);
                end
            end

            //---------------------------------------------------------------
            // 命令前置空闲时钟（CMD 保持高）
            command_hot[S_PRE]: if (ck_fall) begin
                idle_cnt <= idle_cnt + 4'd1;
                cmd_oe   <= 1'b1;
                cmd_out  <= 1'b1;
                if (idle_cnt == 4'd7) begin
                    tx_cnt     <= 6'd47;
                    crc_clr_tx <= 1'b1;      // 下一拍开始发帧，同时清 CRC
                    command_hot <= (7'b1<<S_SEND);
                end
            end

            //---------------------------------------------------------------
            // 发 48 bit 命令帧
            command_hot[S_SEND]: if (ck_fall) begin
                cmd_oe  <= 1'b1;
                cmd_out <= tx_bit;
                if (tx_cnt >= 6'd8) begin
                    tx_sr      <= {tx_sr[38:0], 1'b0};
                    crc_en_tx  <= 1'b1;
                    crc_bit_tx <= tx_sr[39];
                    if (tx_cnt == 6'd8)
                        crc_load <= 1'b1;
                end else if (tx_cnt >= 6'd1) begin
                    crc_sr <= {crc_sr[5:0], 1'b0};
                end
                if (tx_cnt == 6'd0) begin
                    command_hot <= (7'b1<<S_TURN);
                end else begin
                    tx_cnt <= tx_cnt - 6'd1;
                end
            end

            //---------------------------------------------------------------
            // 总线转向：释放 CMD（1 个 SD 时钟），随后进入等响应
            //   规范里卡的 NCR 只要 ≥1 个时钟就可能开始应答，所以这里**只等 1 拍**；
            //   若等 2 拍，遇到 NCR=1 的卡就会漏掉响应起始位。
            //   释放期间 CMD 悬空由卡座 10K 上拉为高，采样到 z 不会被判成起始位
            //   （`!cmd_in` 对 z 为 x → if 不成立），所以早进入不会误触发。
            command_hot[S_TURN]: if (ck_fall) begin
                cmd_oe  <= 1'b0;
                cmd_out <= 1'b1;
                tmo_cnt <= 16'd0;
                tmo_en  <= (rtype != 2'd0);
                command_hot <= (rtype == 2'd0) ? (7'b1<<S_POST) : (7'b1<<S_WAIT);
            end

            //---------------------------------------------------------------
            // 等响应起始位（起始位为 0）
            command_hot[S_WAIT]: if (ck_rise) begin
                if (!cmd_in) begin
                    sr         <= 48'd0;      // 起始位本身（值 0）计入第 0 位
                    resp_r2    <= 136'd0;
                    rx_cnt     <= 8'd1;
                    crc_clr_rx <= 1'b1;       // 开始累积响应载荷的 CRC7
                    tmo_en     <= 1'b0;
                    tmo_cnt    <= 16'd0;
                    command_hot <= (7'b1<<S_RECV);
                end else if (tmo_en && (tmo_cnt >= resp_timeout - 16'd1)) begin
                    no_resp <= 1'b1;
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    tmo_en  <= 1'b0;
                    command_hot <= (7'b1<<S_IDLE);
                end
            end

            //---------------------------------------------------------------
            // 收响应
            command_hot[S_RECV]: if (ck_rise) begin

                if (rtype == 2'd3) begin
                    // ---------------- R2：136 bit，只收不解析 ----------------
                    resp_r2 <= {resp_r2[134:0], cmd_in};
                    if (rx_cnt >= 8'd135) begin
                        busy   <= 1'b0;
                        done   <= 1'b1;
                        tmo_en <= 1'b0;
                        command_hot <= (7'b1<<S_IDLE);
                    end else begin
                        rx_cnt <= rx_cnt + 8'd1;
                    end
                end else begin
                    // ---------------- 48 bit：R1/R3/R6/R7 ----------------
                    sr <= {sr[46:0], cmd_in};
                    if (rx_cnt <= 8'd39) begin
                        crc_en_rx  <= 1'b1;
                        crc_bit_rx <= cmd_in;
                        rx_cnt     <= rx_cnt + 8'd1;
                    end else if (rx_cnt <= 8'd46) begin
                        // CRC7 字段：MSB 先出，逐 bit 与累加器比对
                        // rx_cnt=40 → crc7_rx[6]；rx_cnt=46 → crc7_rx[0]
                        if (cmd_in != crc7_rx[8'd46 - rx_cnt])
                            crc_bad <= 1'b1;
                        rx_cnt <= rx_cnt + 8'd1;
                    end else begin
                        // 结束位
                        if (!cmd_in)
                            end_bad <= 1'b1;
                        crc_err <= (rtype == 2'd1) ? crc_bad : 1'b0;
                        idle_cnt<= 4'd0;
                        tmo_en  <= 1'b0;
                        command_hot <= (7'b1<<S_POST);
                    end
                end
            end

            //---------------------------------------------------------------
            // 命令后置空闲时钟，并把响应装载到输出
            command_hot[S_POST]: begin
                cmd_oe  <= 1'b1;             // 主动驱高
                cmd_out <= 1'b1;
                if (ck_rise) begin
                    if (idle_cnt == 4'd0) begin
                        resp_cmd <= sr[45:40];
                        resp_arg <= sr[39:8];
                    end
                    if (idle_cnt == 4'd7) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        command_hot <= (7'b1<<S_IDLE);
                    end else begin
                        idle_cnt <= idle_cnt + 4'd1;
                    end
                end
            end

            default: command_hot <= (7'b1<<S_IDLE);
            endcase
        end
    end

endmodule
