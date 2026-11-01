//=============================================================================
// module : sdram_app_arb
// 文件名 : rtl/framebuffer/sdram_app_arb.v
// 功  能 : frame_read_write 与音频桥共享 SDRAM App_* 字口。
//          帧优先；音频仅在帧本拍无 App_* 请求时占用。
//          SDRAM 读返回有延迟，故每个被接受的读请求都把 owner 写入 tag FIFO，
//          Sdr_rd_en 到来时按请求顺序出队，不能使用“返回当拍的 grant”路由。
//          参数 ADDR_BITS / MEM_DATA_BITS / TAG_AW 与 top 例化一致。
//
//  ★ 帧读时序极脆（frame_fifo_read 用 rd_delay==10 判 burst 结束）：
//    不要改 f_Sdr_rd_en / Sdr_rd_dout 的对齐与延迟，也不要加大 tag 读组合深度。
//    音频与帧共存的问题不在本模块解决：top 生产构建传 ENABLE_AUDIO=0，
//    把“音频不进 SDRAM”的隔离决策固化为结构（a_*_gnt 恒 0，App_* 口退化为帧直通）；
//    ENABLE_AUDIO=1 仅供 tb_sdram_app_arb 等单测验证双 client 行为。
//=============================================================================
module sdram_app_arb #(
    parameter ADDR_BITS     = 21,
    parameter MEM_DATA_BITS = 32,
    parameter TAG_AW        = 2,
    // 1 = 音频分支可用（单测默认）；0 = 结构性禁止音频进 App_* 口。
    // 两种取值共用同一套 mux / tag / 返回寄存级，仅 gnt 生成不同，
    // 保证 ENABLE_AUDIO=0 构建与“顶层把 a_* 绑 0”逐比特等价（零回归风险）。
    parameter ENABLE_AUDIO  = 1
)(
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     sdr_busy,

    // frame
    input  wire                     f_App_wr_en,
    input  wire [ADDR_BITS-1:0]     f_App_wr_addr,
    input  wire [MEM_DATA_BITS-1:0] f_App_wr_din,
    input  wire [3:0]               f_App_wr_dm,
    input  wire                     f_App_rd_en,
    input  wire [ADDR_BITS-1:0]     f_App_rd_addr,
    output wire                     f_Sdr_rd_en,
    output wire [MEM_DATA_BITS-1:0] f_Sdr_rd_dout,

    // audio
    input  wire                     a_App_wr_en,
    input  wire [ADDR_BITS-1:0]     a_App_wr_addr,
    input  wire [MEM_DATA_BITS-1:0] a_App_wr_din,
    input  wire [3:0]               a_App_wr_dm,
    input  wire                     a_App_rd_en,
    input  wire [ADDR_BITS-1:0]     a_App_rd_addr,
    output wire                     a_Sdr_rd_en,
    output wire [MEM_DATA_BITS-1:0] a_Sdr_rd_dout,
    output wire                     a_wr_gnt,
    output wire                     a_rd_gnt,

    // sdram.v
    output wire                     App_wr_en,
    output wire [ADDR_BITS-1:0]     App_wr_addr,
    output wire [3:0]               App_wr_dm,
    output wire [MEM_DATA_BITS-1:0] App_wr_din,
    output wire                     App_rd_en,
    output wire [ADDR_BITS-1:0]     App_rd_addr,
    input  wire                     Sdr_rd_en,
    input  wire [MEM_DATA_BITS-1:0] Sdr_rd_dout
);
    localparam [TAG_AW:0] TAG_DEPTH_C = (1 << TAG_AW);

    wire f_act = f_App_wr_en | f_App_rd_en;

    // 帧侧状态机本身已经观察 Sdr_busy；音频桥没有该端口，所以在此门控。
    // 只有真正送入 SDRAM 的读请求才能 push tag。
    // ENABLE_AUDIO=0 时 gnt 恒 0：音频请求永远进不了 SDRAM，App_* 口
    // 组合塌缩为帧直通（a_* 输入悬空也不影响帧路径）。
    generate
        if (ENABLE_AUDIO != 0) begin : g_audio_on
            assign a_wr_gnt = a_App_wr_en & ~f_act & ~sdr_busy;
            assign a_rd_gnt = a_App_rd_en & ~f_act & ~sdr_busy;
        end else begin : g_audio_off
            assign a_wr_gnt = 1'b0;
            assign a_rd_gnt = 1'b0;
        end
    endgenerate

    assign App_wr_en   = f_App_wr_en | a_wr_gnt;
    assign App_wr_addr = f_App_wr_en ? f_App_wr_addr : a_App_wr_addr;
    assign App_wr_dm   = f_App_wr_en ? f_App_wr_dm   : a_App_wr_dm;
    assign App_wr_din  = f_App_wr_en ? f_App_wr_din  : a_App_wr_din;
    assign App_rd_en   = f_App_rd_en | a_rd_gnt;
    assign App_rd_addr = f_App_rd_en ? f_App_rd_addr : a_App_rd_addr;

    //--------------------------------------------------------------------------
    // 读返回归属 FIFO
    // SDRAM 控制器保证读数据按 App_rd_en 的接受顺序返回。帧请求始终优先，
    // 音频请求只有 a_rd_gnt=1 才真正进入 SDRAM，因此 tag push 与 App_rd_en
    // 完全一一对应。TAG_AW=9 时可容纳 512 个在途请求，覆盖整段帧突发。
    //--------------------------------------------------------------------------
    reg                  rd_tag_mem [0:(1<<TAG_AW)-1]; // 0=frame, 1=audio
    reg [TAG_AW-1:0]     rd_tag_wr_ptr;
    reg [TAG_AW-1:0]     rd_tag_rd_ptr;
    reg [TAG_AW:0]       rd_tag_count;

    wire rd_tag_push  = App_rd_en;
    wire rd_tag_pop   = Sdr_rd_en && (rd_tag_count != {(TAG_AW+1){1'b0}});
    wire rd_tag_full  = (rd_tag_count >= TAG_DEPTH_C);
    wire rd_return_is_a = rd_tag_mem[rd_tag_rd_ptr];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rd_tag_wr_ptr <= {TAG_AW{1'b0}};
            rd_tag_rd_ptr <= {TAG_AW{1'b0}};
            rd_tag_count  <= {(TAG_AW+1){1'b0}};
        end else begin
            if (rd_tag_push && !rd_tag_full) begin
                rd_tag_mem[rd_tag_wr_ptr] <= a_rd_gnt;
                rd_tag_wr_ptr <= rd_tag_wr_ptr + 1'b1;
            end
            if (rd_tag_pop)
                rd_tag_rd_ptr <= rd_tag_rd_ptr + 1'b1;

            case ({rd_tag_push && !rd_tag_full, rd_tag_pop})
                2'b10: rd_tag_count <= rd_tag_count + 1'b1;
                2'b01: rd_tag_count <= rd_tag_count - 1'b1;
                default: rd_tag_count <= rd_tag_count;
            endcase
        end
    end

    // 把 owner 与数据同拍锁存后再输出。这样既保持二者严格对齐，也切断
    // tag RAM -> frame/audio FIFO 写使能的长组合路径；下游接口只要求
    // Sdr_rd_en 与数据同拍，不要求相对物理 SDRAM 的固定延迟。
    // ★ ENABLE_AUDIO=0 时这拍寄存级必须原样保留：帧路径相对当前构建
    //   逐比特等价的前提就是它（"10 拍"标定包含本拍），不得直通化。
    reg                  f_sdr_rd_en_r, a_sdr_rd_en_r;
    reg [MEM_DATA_BITS-1:0] sdr_rd_dout_r;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            f_sdr_rd_en_r <= 1'b0;
            a_sdr_rd_en_r <= 1'b0;
            sdr_rd_dout_r <= {MEM_DATA_BITS{1'b0}};
        end else begin
            f_sdr_rd_en_r <= rd_tag_pop && !rd_return_is_a;
            a_sdr_rd_en_r <= rd_tag_pop &&  rd_return_is_a;
            if (rd_tag_pop)
                sdr_rd_dout_r <= Sdr_rd_dout;
        end
    end

    assign f_Sdr_rd_en   = f_sdr_rd_en_r;
    assign f_Sdr_rd_dout = sdr_rd_dout_r;
    assign a_Sdr_rd_en   = a_sdr_rd_en_r;
    assign a_Sdr_rd_dout = sdr_rd_dout_r;
endmodule
