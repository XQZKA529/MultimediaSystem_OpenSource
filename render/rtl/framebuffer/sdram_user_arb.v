//=============================================================================
// module : sdram_user_arb
// 文件名 : rtl/framebuffer/sdram_user_arb.v
// 功  能 : 【SDRAM 用户口仲裁】把 frame_read_write 的图像突发（高优先）
//          与 audio_sdma_ring 的音频突发（低优先）复用到一组 SDRAM 用户突发口。
//
// 优先级（完整突发粒度，不可中途抢占）：
//      1. 帧读  frame_rd   —— 最高，保证视频带宽
//      2. 帧写  frame_wr
//      3. 音频读 audio_rd
//      4. 音频写 audio_wr  —— 最低，只吃帧侧空闲隙
//
// 突发握手（与 frame_read_write 注释中的经典 burst 口一致，
//            宽度对齐 BURST_BITS=9 / BURST_SIZE=256 / ADDR_BITS=21）：
//   写：主→从 wr_burst_req + wr_burst_len + wr_burst_addr
//       从→主 wr_burst_data_req（提前 1 拍要数）→ 主下一拍给 wr_burst_data
//       从→主 wr_burst_finish
//   读：主→从 rd_burst_req + rd_burst_len + rd_burst_addr
//       从→主 rd_burst_data_valid + rd_burst_data（逐拍）→ rd_burst_finish
//
// 说明：
//   - 同一时刻只授权一条突发（读或写），避免底层控制器写读互踩；
//     与 frame_fifo_* 内部用 App_wr_busy/App_rd_busy 串行化的习惯一致。
//   - 授权期间信号直通锁定客户端；请求可在间隙被更高级别顶掉。
//=============================================================================
module sdram_user_arb #(
    parameter MEM_DATA_BITS = 32,
    parameter ADDR_BITS     = 21,
    parameter BURST_BITS    = 9
)(
    input  wire                        clk,
    input  wire                        rst,            // 高有效复位（对齐 frame_*）

    //======== 帧客户端（高优先，来自 frame_read_write）========
    // 写突发
    input  wire                        f_wr_req,
    input  wire [BURST_BITS-1:0]       f_wr_len,
    input  wire [ADDR_BITS-1:0]        f_wr_addr,
    output wire                        f_wr_data_req,
    input  wire [MEM_DATA_BITS-1:0]    f_wr_data,
    output wire                        f_wr_finish,
    // 读突发
    input  wire                        f_rd_req,
    input  wire [BURST_BITS-1:0]       f_rd_len,
    input  wire [ADDR_BITS-1:0]        f_rd_addr,
    output wire                        f_rd_data_valid,
    output wire [MEM_DATA_BITS-1:0]    f_rd_data,
    output wire                        f_rd_finish,
    output wire                        f_busy,         // 任一帧侧突发在途

    //======== 音频客户端（低优先，来自 audio_sdma_ring）========
    input  wire                        a_wr_req,
    input  wire [BURST_BITS-1:0]       a_wr_len,
    input  wire [ADDR_BITS-1:0]        a_wr_addr,
    output wire                        a_wr_data_req,
    input  wire [MEM_DATA_BITS-1:0]    a_wr_data,
    output wire                        a_wr_finish,
    input  wire                        a_rd_req,
    input  wire [BURST_BITS-1:0]       a_rd_len,
    input  wire [ADDR_BITS-1:0]        a_rd_addr,
    output wire                        a_rd_data_valid,
    output wire [MEM_DATA_BITS-1:0]    a_rd_data,
    output wire                        a_rd_finish,
    output wire                        a_busy,

    //======== 共享 SDRAM 用户突发口（单一从设备）========
    output wire                        sdr_wr_burst_req,
    output wire [BURST_BITS-1:0]       sdr_wr_burst_len,
    output wire [ADDR_BITS-1:0]        sdr_wr_burst_addr,
    input  wire                        sdr_wr_burst_data_req,
    output wire [MEM_DATA_BITS-1:0]    sdr_wr_burst_data,
    input  wire                        sdr_wr_burst_finish,

    output wire                        sdr_rd_burst_req,
    output wire [BURST_BITS-1:0]       sdr_rd_burst_len,
    output wire [ADDR_BITS-1:0]        sdr_rd_burst_addr,
    input  wire                        sdr_rd_burst_data_valid,
    input  wire [MEM_DATA_BITS-1:0]    sdr_rd_burst_data,
    input  wire                        sdr_rd_burst_finish
);

    //--------------------------------------------------------------------------
    // 授权状态：一条完整突发独占共享口
    //--------------------------------------------------------------------------
    localparam G_IDLE     = 3'd0;
    localparam G_F_WR     = 3'd1;
    localparam G_F_RD     = 3'd2;
    localparam G_A_WR     = 3'd3;
    localparam G_A_RD     = 3'd4;

    reg [2:0] gnt;

    // req 捕获/skid：audio_sdma_ring 会保持 req 到 data_req/data_valid，
    // 本侧仍要兜住“同拍对向胜出 / 仲裁忙”时的请求，不得丢。
    reg                        a_wr_pend, a_rd_pend;
    reg [BURST_BITS-1:0]       a_wr_len_p, a_rd_len_p;
    reg [ADDR_BITS-1:0]        a_wr_addr_p, a_rd_addr_p;

    wire                       a_wr_any = a_wr_req | a_wr_pend;
    wire                       a_rd_any = a_rd_req | a_rd_pend;
    wire [BURST_BITS-1:0]      a_wr_len_a  = a_wr_req ? a_wr_len  : a_wr_len_p;
    wire [BURST_BITS-1:0]      a_rd_len_a  = a_rd_req ? a_rd_len  : a_rd_len_p;
    wire [ADDR_BITS-1:0]       a_wr_addr_a = a_wr_req ? a_wr_addr : a_wr_addr_p;
    wire [ADDR_BITS-1:0]       a_rd_addr_a = a_rd_req ? a_rd_addr : a_rd_addr_p;

    // 优先级编码：帧读 > 帧写 > 音频读 > 音频写
    wire sel_f_wr = f_wr_req;
    wire sel_f_rd = f_rd_req;
    wire sel_a_wr = a_wr_any;
    wire sel_a_rd = a_rd_any;

    // 锁存的共享口输出
    reg                        m_wr_req;
    reg [BURST_BITS-1:0]       m_wr_len;
    reg [ADDR_BITS-1:0]        m_wr_addr;
    reg                        m_rd_req;
    reg [BURST_BITS-1:0]       m_rd_len;
    reg [ADDR_BITS-1:0]        m_rd_addr;

    assign sdr_wr_burst_req  = m_wr_req;
    assign sdr_wr_burst_len  = m_wr_len;
    assign sdr_wr_burst_addr = m_wr_addr;
    assign sdr_rd_burst_req  = m_rd_req;
    assign sdr_rd_burst_len  = m_rd_len;
    assign sdr_rd_burst_addr = m_rd_addr;

    // 写数据 / data_req：按授权源选择
    assign sdr_wr_burst_data = (gnt == G_F_WR) ? f_wr_data :
                               (gnt == G_A_WR) ? a_wr_data : {MEM_DATA_BITS{1'b0}};
    assign f_wr_data_req = sdr_wr_burst_data_req && (gnt == G_F_WR);
    assign a_wr_data_req = sdr_wr_burst_data_req && (gnt == G_A_WR);

    // 写完成：只打给当前授权客户端
    assign f_wr_finish = sdr_wr_burst_finish && (gnt == G_F_WR);
    assign a_wr_finish = sdr_wr_burst_finish && (gnt == G_A_WR);

    // 读回数据：广播数据，valid/finish 按授权源选通
    assign f_rd_data       = sdr_rd_burst_data;
    assign a_rd_data       = sdr_rd_burst_data;
    assign f_rd_data_valid = sdr_rd_burst_data_valid && (gnt == G_F_RD);
    assign a_rd_data_valid = sdr_rd_burst_data_valid && (gnt == G_A_RD);
    assign f_rd_finish     = sdr_rd_burst_finish     && (gnt == G_F_RD);
    assign a_rd_finish     = sdr_rd_burst_finish     && (gnt == G_A_RD);

    assign f_busy = (gnt == G_F_WR) || (gnt == G_F_RD);
    assign a_busy = (gnt == G_A_WR) || (gnt == G_A_RD);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            gnt      <= G_IDLE;
            m_wr_req <= 1'b0;
            m_rd_req <= 1'b0;
            m_wr_len <= {BURST_BITS{1'b0}};
            m_rd_len <= {BURST_BITS{1'b0}};
            m_wr_addr<= {ADDR_BITS{1'b0}};
            m_rd_addr<= {ADDR_BITS{1'b0}};
            a_wr_pend <= 1'b0; a_rd_pend <= 1'b0;
            a_wr_len_p <= 0; a_rd_len_p <= 0;
            a_wr_addr_p <= 0; a_rd_addr_p <= 0;
        end else begin
            // 捕获 req：只要本客户端不在途、且本拍没有把 grant 给它，就 skid。
            // 原先要求 gnt!=G_IDLE，会漏掉“空闲同拍对向更高优先级胜出”的 1 拍
            // 脉冲 —— 写读同时到达时写请求被丢，audio_sdma_ring 死等 finish。
            if (a_wr_req && (gnt != G_A_WR) &&
                !((gnt == G_IDLE) && sel_a_wr && !sel_a_rd && !sel_f_rd && !sel_f_wr)) begin
                a_wr_pend  <= 1'b1;
                a_wr_len_p <= a_wr_len;
                a_wr_addr_p<= a_wr_addr;
            end
            if (a_rd_req && (gnt != G_A_RD) &&
                !((gnt == G_IDLE) && sel_a_rd && !sel_f_rd && !sel_f_wr)) begin
                a_rd_pend  <= 1'b1;
                a_rd_len_p <= a_rd_len;
                a_rd_addr_p<= a_rd_addr;
            end
            case (gnt)
                G_IDLE: begin
                    m_wr_req <= 1'b0;
                    m_rd_req <= 1'b0;
                    // 帧读最高优先
                    if (sel_f_rd) begin
                        gnt       <= G_F_RD;
                        m_rd_req  <= 1'b1;
                        m_rd_len  <= f_rd_len;
                        m_rd_addr <= f_rd_addr;
                    end else if (sel_f_wr) begin
                        gnt       <= G_F_WR;
                        m_wr_req  <= 1'b1;
                        m_wr_len  <= f_wr_len;
                        m_wr_addr <= f_wr_addr;
                    end else if (sel_a_rd) begin
                        gnt       <= G_A_RD;
                        m_rd_req  <= 1'b1;
                        m_rd_len  <= a_rd_len_a;
                        m_rd_addr <= a_rd_addr_a;
                        a_rd_pend <= 1'b0;
                    end else if (sel_a_wr) begin
                        gnt       <= G_A_WR;
                        m_wr_req  <= 1'b1;
                        m_wr_len  <= a_wr_len_a;
                        m_wr_addr <= a_wr_addr_a;
                        a_wr_pend <= 1'b0;
                    end
                end
                G_F_WR: begin
                    // req 保持到从设备应答后拉低；finish 结束回 IDLE
                    if (sdr_wr_burst_data_req)
                        m_wr_req <= 1'b0;
                    if (sdr_wr_burst_finish) begin
                        gnt      <= G_IDLE;
                        m_wr_req <= 1'b0;
                    end
                end
                G_A_WR: begin
                    if (sdr_wr_burst_data_req)
                        m_wr_req <= 1'b0;
                    if (sdr_wr_burst_finish) begin
                        gnt      <= G_IDLE;
                        m_wr_req <= 1'b0;
                    end
                end
                G_F_RD: begin
                    if (sdr_rd_burst_data_valid)
                        m_rd_req <= 1'b0;
                    if (sdr_rd_burst_finish) begin
                        gnt      <= G_IDLE;
                        m_rd_req <= 1'b0;
                    end
                end
                G_A_RD: begin
                    if (sdr_rd_burst_data_valid)
                        m_rd_req <= 1'b0;
                    if (sdr_rd_burst_finish) begin
                        gnt      <= G_IDLE;
                        m_rd_req <= 1'b0;
                    end
                end
                default: gnt <= G_IDLE;
            endcase
        end
    end

endmodule
