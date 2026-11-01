//=============================================================================
// module : sdram_app_mux
// 文件名 : rtl/framebuffer/sdram_app_mux.v
// 功  能 : 在 frame_read_write 与音频桥之间仲裁 SDRAM App_* 字访问口。
//          帧口最高优先；音频口仅在帧口本拍无请求时访问（可被连续帧推迟）。
//=============================================================================
module sdram_app_mux (
    input  wire        mem_clk,
    input  wire        rst,

    // frame (priority)
    input  wire        f_wr_en,
    input  wire [20:0] f_wr_addr,
    input  wire [31:0] f_wr_din,
    input  wire [3:0]  f_wr_dm,
    input  wire        f_rd_en,
    input  wire [20:0] f_rd_addr,

    // audio (secondary)
    input  wire        a_wr_en,
    input  wire [20:0] a_wr_addr,
    input  wire [31:0] a_wr_din,
    input  wire [3:0]  a_wr_dm,
    input  wire        a_rd_en,
    input  wire [20:0] a_rd_addr,
    output wire        a_gnt,          // 1 = 本拍音频访问被放到总线上

    // to sdram.v
    output wire        App_wr_en,
    output wire [20:0] App_wr_addr,
    output wire [3:0]  App_wr_dm,
    output wire [31:0] App_wr_din,
    output wire        App_rd_en,
    output wire [20:0] App_rd_addr
);
    wire f_act = f_wr_en | f_rd_en;
    wire a_act = a_wr_en | a_rd_en;
    assign a_gnt = a_act & ~f_act;

    assign App_wr_en  = f_wr_en | (a_gnt & a_wr_en);
    assign App_wr_addr= f_wr_en ? f_wr_addr : a_wr_addr;
    assign App_wr_dm  = f_wr_en ? f_wr_dm   : a_wr_dm;
    assign App_wr_din = f_wr_en ? f_wr_din  : a_wr_din;
    assign App_rd_en  = f_rd_en | (a_gnt & a_rd_en);
    assign App_rd_addr= f_rd_en ? f_rd_addr : a_rd_addr;
endmodule
