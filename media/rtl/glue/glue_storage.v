//=============================================================================
// glue_storage — 存储侧 client 汇接（P0：storage_service + client 映射）
//
// 内部例化 storage_service（fat32_ro + one-hot 目录仲裁 + write_bp 反压）。
// 对外仍是 ctl_*（fat_bmp_controller）/ br_*（file_browser）两套目录口。
// D4: 错误语义（sd_rd_err_seen）由 storage_service 派生，本层纯透传。
//
//   目录所有权：ctl_dir_req / br_dir_req → dir_owner_req = {br, ctl}
//     · 两 req 皆 0：不授权
//     · 高优先 br（file_browser），持有到 dir_done；重叠请求不抢占
//     · ctl_dir_gnt / br_dir_gnt 为 one-hot 反馈，纯 assign
//   · 目录数据面经 ctl_dir_dat / br_dir_dat 捆绑过端口（E1，位分配见
//     pkg/fat_dir_bus.vh），req/gnt/start 保持独立
//   · 错误语义：sd_rd_err_seen 由 storage_service 派生（D4），本层纯透传
//=============================================================================
`include "../pkg/fat_dir_bus.vh"
module glue_storage #(parameter integer FILE_MAX_BURST=4) (
    input  wire        clk,
    input  wire        rst,

    // ---- SDIO 授权式突发读通道（ch0）----
    output wire        blk_req,
    output wire [31:0] blk_lba,
    output wire [15:0] blk_count,
    input  wire        blk_grant,
    input  wire [7:0]  blk_data,
    input  wire        blk_data_valid,
    input  wire        blk_end,
    input  wire        blk_error,

    // ---- 挂载（共享）----
    input  wire        mount_start,
    output wire        mount_done,
    output wire        mount_ok,
    output wire [7:0]  fat_error_code,
    output wire        sd_rd_err_seen,

    // ---- 文件流（单消费者：fat_bmp_controller）----
    input  wire        file_start,
    input  wire [31:0] file_first_cluster,
    input  wire [31:0] file_size,
    input  wire [31:0] file_read_limit,
    input  wire        file_abort,
    // ---- map walker + fat_chain_map 写口 ----
    input  wire        map_start,
    input  wire [31:0] map_first_cluster,
    input  wire [31:0] map_size,
    input  wire        map_abort,
    input  wire        map_bank,
    output wire        map_busy,
    output wire        map_done,
    output wire        map_ok,
    output wire        map_wr_clear,
    output wire        map_wr_en,
    output wire [31:0] map_wr_lba,
    output wire [31:0] map_wr_nsec,
    output wire        map_wr_last,
    output wire [7:0]  file_data,
    output wire        file_data_valid,
    output wire        file_done,
    output wire        file_ok,
    output wire        file_busy,

    // ---- 反压（P1：write_bp 直通）----
    input  wire        write_bp,

    // ---- 目录 client 0：fat_bmp_controller ----
    //   数据面捆绑（位分配见 pkg/fat_dir_bus.vh；req/gnt/start 独立在外）
    input  wire        ctl_dir_req,
    output wire        ctl_dir_gnt,
    input  wire        ctl_dir_start,
    output wire [`VDIR_DBUS_W-1:0] ctl_dir_dat,

    // ---- 目录 client 1：file_browser ----
    input  wire        br_dir_req,
    output wire        br_dir_gnt,
    input  wire        br_dir_start,
    output wire [`VDIR_DBUS_W-1:0] br_dir_dat,

    input wire txt_dir_req,output wire txt_dir_gnt,input wire txt_dir_start,output wire [`VDIR_DBUS_W-1:0] txt_dir_dat,
    input wire txt_file_start,input wire [31:0] txt_file_cluster,txt_file_size,
    output wire [7:0] txt_file_data,output wire txt_file_valid,txt_file_done,txt_file_ok,
    output wire operation_idle,
    // ---- FAT 调试（E3: 死口 dbg_fat_cluster/lba/file_remaining 已移除）----
    output wire [7:0]  dbg_fat_state,
    output wire [31:0] dbg_dir_count
);

    wire [2:0] dir_owner_req = {txt_dir_req,br_dir_req,ctl_dir_req};
    wire [2:0] dir_owner_gnt;
    assign txt_dir_gnt=dir_owner_gnt[2];

    assign ctl_dir_gnt = dir_owner_gnt[0];
    assign br_dir_gnt  = dir_owner_gnt[1];
    // D4: sd_rd_err_seen 由 storage_service 依据 pkg/fat_err_codes.vh 宏派生，
    // 本层纯透传（原先的 fat_error_code==8'd1 魔法数已删除）。

    storage_service #(.FILE_MAX_BURST(FILE_MAX_BURST)) u_storage_service (
        .clk(clk), .rst(rst),
        .c2_dir_start(txt_dir_start),.c2_dir_dat(txt_dir_dat),
        .txt_file_start(txt_file_start),.txt_file_cluster(txt_file_cluster),.txt_file_size(txt_file_size),
        .txt_file_data(txt_file_data),.txt_file_valid(txt_file_valid),.txt_file_done(txt_file_done),.txt_file_ok(txt_file_ok),
        .operation_idle(operation_idle),
        .blk_req(blk_req), .blk_lba(blk_lba), .blk_count(blk_count),
        .blk_grant(blk_grant), .blk_data(blk_data), .blk_data_valid(blk_data_valid),
        .blk_end(blk_end), .blk_error(blk_error),
        .mount_start(mount_start), .mount_done(mount_done), .mount_ok(mount_ok),
        .fat_error_code(fat_error_code), .sd_rd_err_seen(sd_rd_err_seen),
        .file_start(file_start), .file_first_cluster(file_first_cluster),
        .file_size(file_size), .file_read_limit(file_read_limit),
        .file_abort(file_abort), .file_data(file_data),
        .map_start(map_start), .map_first_cluster(map_first_cluster),
        .map_size(map_size), .map_abort(map_abort), .map_bank(map_bank),
        .map_busy(map_busy), .map_done(map_done), .map_ok(map_ok),
        .map_wr_clear(map_wr_clear), .map_wr_en(map_wr_en),
        .map_wr_lba(map_wr_lba), .map_wr_nsec(map_wr_nsec), .map_wr_last(map_wr_last),
        .file_data_valid(file_data_valid), .file_done(file_done), .file_ok(file_ok),
        .file_busy(file_busy),
        .file_read_ready(write_bp),
        .dir_owner_req(dir_owner_req), .dir_owner_gnt(dir_owner_gnt),
        .c0_dir_start(ctl_dir_start),
        .c0_dir_dat(ctl_dir_dat),
        .c1_dir_start(br_dir_start),
        .c1_dir_dat(br_dir_dat),
        .dbg_fat_state(dbg_fat_state),
        .dbg_dir_count(dbg_dir_count)
    );

endmodule
