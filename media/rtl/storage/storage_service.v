//=============================================================================
// storage_service — 保留请求的统一 FAT 操作协调层
//
// 职责：收口 FAT 只读服务的对外契约；内部仍例化现有 fat32_ro（不改其 FSM）。
//   · 挂载 / 文件流：与 fat32_ro 同名端口语义一致
//   · 目录：三个 client 经 dir_owner_req/gnt one-hot 仲裁，持有到完成
//   · 反压：file_read_ready 直通（P1，无 C_LOAD 特判）
//   · 错误语义：sd_rd_err_seen 由错误码宏派生（D4，上层不再解码裸数字）
//
// 仲裁语义：
//   · grant one-hot，高优先 client1（file_browser）——与旧 br_dir_owner 选择子一致
//   · 持有到 dir_done（fat32 无独立 dir_abort；file_abort 不影响目录占用）
//   · 不抢占：dir 进行中的第二请求等待，不丢
//   · 未 grant 的 client 目录响应恒 0
//=============================================================================
`include "../pkg/fat_err_codes.vh"
`include "../pkg/fat_dir_bus.vh"
module storage_service #(parameter integer FILE_MAX_BURST=4) (
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

    // ---- 挂载 ----
    input  wire        mount_start,
    output wire        mount_done,
    output wire        mount_ok,
    output wire [7:0]  fat_error_code,
    // D4: 语义化错误信号——底层 SD 块读失败（错误码宏见 pkg/fat_err_codes.vh）
    output wire        sd_rd_err_seen,

    // ---- 文件流（单消费者）----
    input  wire        file_start,
    input  wire [31:0] file_first_cluster,
    input  wire [31:0] file_size,
    input  wire [31:0] file_read_limit,
    input  wire        file_abort,
    // ---- 簇链→LBA 段表 walker ----
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
    output reg         file_done,
    output reg         file_ok,
    output wire        file_busy,

    // ---- 反压（P1：write_bp → file_read_ready）----
    input  wire        file_read_ready,

    // ---- 目录仲裁 ----
    //   req[1] = file_browser（优先，与旧 dir_owner 一致）
    //   req[0] = fat_bmp_controller
    input  wire [2:0]  dir_owner_req,
    output wire [2:0]  dir_owner_gnt,

    // ---- 目录 client 0：fat_bmp_controller ----
    //   数据面捆绑（位分配见 pkg/fat_dir_bus.vh；req/gnt/start 独立在外）
    input  wire        c0_dir_start,
    output wire [`VDIR_DBUS_W-1:0] c0_dir_dat,

    // ---- 目录 client 1：file_browser ----
    input  wire        c1_dir_start,
    output wire [`VDIR_DBUS_W-1:0] c1_dir_dat,

    input wire c2_dir_start,output wire [`VDIR_DBUS_W-1:0] c2_dir_dat,
    input wire txt_file_start,input wire [31:0] txt_file_cluster,txt_file_size,
    output wire [7:0] txt_file_data,output wire txt_file_valid,output reg txt_file_done,txt_file_ok,
    output wire operation_idle,
    // ---- FAT 调试 ----
    // E3: dbg_current_cluster/lba/file_remaining 是无消费者的死口（仅为
    //    调试保活会多出 96 个寄存器与 64 位宽扇出网，曾致布线 ECO 冲突），
    //    已从 fat32_ro 移除；仅保留 dbg_fat_state / dbg_dir_count。
    output wire [7:0]  dbg_fat_state,
    output wire [31:0] dbg_dir_count
);

    //--------------------------------------------------------------------------
    // fat32_ro 目录口 2:1：grant 方向收/放，未 grant 侧全 0
    // E1: 数据面 10 信号打包为 ro_dir_dat（位分配见 pkg/fat_dir_bus.vh），
    //     原 20 条逐信号门控 assign 收敛为 2 条宽 mux。
    //--------------------------------------------------------------------------
    wire [`VDIR_DBUS_W-1:0] ro_dir_dat;
    wire ro_map_accept,ro_map_busy,ro_file_busy;
    wire [7:0] ro_data;
    wire ro_file_valid,ro_file_done,ro_file_ok;
    reg [2:0] gnt_r;
    reg dir_busy;
    wire [2:0] gnt_sel=dir_owner_req[1] ? 3'b010:dir_owner_req[0] ? 3'b001:dir_owner_req[2] ? 3'b100:3'b000;
    wire [2:0] gnt=dir_busy ? gnt_r:gnt_sel;
    assign dir_owner_gnt=gnt;
    wire dir_command=(c0_dir_start && gnt[0]) || (c1_dir_start && gnt[1]) || (c2_dir_start && gnt[2]);
    always @(posedge clk) begin
        if(rst) begin gnt_r<=0;dir_busy<=0;end
        else if(!dir_busy) begin gnt_r<=gnt_sel;if(dir_command) dir_busy<=1;end
        else if(ro_dir_dat[`VDIR_D_DONE]) begin dir_busy<=0;gnt_r<=0;end
    end
    // Only the accepted directory owner receives responses. The prospective
    // combinational grant is for requests, never for a lingering done pulse.
    // This also isolates browser request decode from the image result FSM.
    assign c0_dir_dat=(dir_busy && gnt_r[0]) ? ro_dir_dat:0;
    assign c1_dir_dat=(dir_busy && gnt_r[1]) ? ro_dir_dat:0;
    assign c2_dir_dat=(dir_busy && gnt_r[2]) ? ro_dir_dat:0;
    assign map_wr_clear=ro_map_accept;
    assign sd_rd_err_seen=(fat_error_code==`FAT_E_RD);
    // One owner covers ALL FAT operations. Queue request pulses with their
    // metadata, and retain ownership until the corresponding completion.
    // No client can accidentally launch into a directory or map operation.
    localparam NONE=0,MOUNT=1,DIR=2,BMP=3,TXT=4,MAP=5;
    reg [2:0] owner;
    reg mount_pending,dir_pending,bmp_pending,txt_pending,map_pending;
    reg [31:0] bmp_cluster_q,bmp_size_q,bmp_limit_q,txt_cluster_q,txt_size_q,map_cluster_q,map_size_q;
    reg ro_mount_start,ro_dir_start,ro_file_start,ro_map_start;
    // FAT latches arguments with the registered start pulse. Queued copies
    // remain stable through that edge; a second set of launch registers is unnecessary.
    wire [31:0] ro_cluster=owner==TXT ? txt_cluster_q:bmp_cluster_q;
    wire [31:0] ro_size=owner==TXT ? txt_size_q:bmp_size_q;
    wire [31:0] ro_limit=owner==TXT ? 32'd260:bmp_limit_q;
    wire [31:0] ro_map_cluster=map_cluster_q,ro_map_size=map_size_q;
    wire ro_idle;
    assign operation_idle=owner==NONE && !mount_pending && !dir_pending && !bmp_pending && !txt_pending && !map_pending && !dir_busy && ro_idle;
    assign file_busy=owner!=NONE || bmp_pending || txt_pending || dir_pending || map_pending;
    assign map_busy=ro_map_busy || map_pending || owner==MAP;
    assign file_data=ro_data;assign file_data_valid=ro_file_valid && owner==BMP;
    assign txt_file_data=ro_data;assign txt_file_valid=ro_file_valid && owner==TXT;
    // Freeze completion and its owner before the client result FSM. The last
    // byte has already been delivered; pending requests can launch on the
    // following edge without redirecting this completion to a new owner.
    always @(posedge clk or posedge rst) begin
        if(rst) begin file_done<=0;file_ok<=0;txt_file_done<=0;txt_file_ok<=0;end
        else begin
            file_done<=ro_file_done && owner==BMP;
            txt_file_done<=ro_file_done && owner==TXT;
            if(ro_file_done && owner==BMP) file_ok<=ro_file_ok;
            if(ro_file_done && owner==TXT) txt_file_ok<=ro_file_ok;
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            owner<=NONE;mount_pending<=0;dir_pending<=0;bmp_pending<=0;txt_pending<=0;map_pending<=0;
            bmp_cluster_q<=0;bmp_size_q<=0;bmp_limit_q<=0;txt_cluster_q<=0;txt_size_q<=0;map_cluster_q<=0;map_size_q<=0;
            ro_mount_start<=0;ro_dir_start<=0;ro_file_start<=0;ro_map_start<=0;
        end else begin
            ro_mount_start<=0;ro_dir_start<=0;ro_file_start<=0;ro_map_start<=0;
            if(mount_start) mount_pending<=1;
            if(dir_command) dir_pending<=1;
            if(file_start) begin bmp_pending<=1;bmp_cluster_q<=file_first_cluster;bmp_size_q<=file_size;bmp_limit_q<=file_read_limit;end
            if(txt_file_start) begin txt_pending<=1;txt_cluster_q<=txt_file_cluster;txt_size_q<=txt_file_size;end
            if(map_start) begin map_pending<=1;map_cluster_q<=map_first_cluster;map_size_q<=map_size;end
            if(file_abort && bmp_pending) bmp_pending<=0;
            if(map_abort && map_pending) map_pending<=0;
            if(owner==NONE && ro_idle) begin
                if(mount_pending) begin owner<=MOUNT;ro_mount_start<=1;mount_pending<=0;end
                else if(map_pending && !map_abort) begin owner<=MAP;ro_map_start<=1;map_pending<=0;end
                else if(dir_pending) begin owner<=DIR;ro_dir_start<=1;dir_pending<=0;end
                else if(bmp_pending && !file_abort) begin owner<=BMP;ro_file_start<=1;bmp_pending<=0;end
                else if(txt_pending) begin owner<=TXT;ro_file_start<=1;txt_pending<=0;end
            end else if((owner==MOUNT && mount_done) || (owner==DIR && ro_dir_dat[`VDIR_D_DONE]) ||
                        ((owner==BMP || owner==TXT) && ro_file_done) || (owner==MAP && map_done)) owner<=NONE;
        end
    end

    fat32_ro #(.FILE_MAX_BURST(FILE_MAX_BURST)) u_fat32_ro (
        .clk(clk), .rst(rst),
        .blk_req(blk_req), .blk_lba(blk_lba), .blk_count(blk_count),
        .blk_grant(blk_grant), .blk_data(blk_data), .blk_data_valid(blk_data_valid),
        .blk_end(blk_end), .blk_error(blk_error),
        .mount_start(ro_mount_start), .mount_done(mount_done), .mount_ok(mount_ok),
        .fat_error_code(fat_error_code),
        // dir 数据面在端口处打包（E1）——fat32_ro 端口面保持逐信号不动
        .dir_start(ro_dir_start),
        .dir_entry_start(ro_dir_dat[`VDIR_D_ESTART]),
        .dir_name_valid(ro_dir_dat[`VDIR_D_NVLD]),
        .dir_name_char(ro_dir_dat[`VDIR_D_CHAR]),
        .dir_name_index(ro_dir_dat[`VDIR_D_INDEX]),
        .dir_entry_end(ro_dir_dat[`VDIR_D_EEND]),
        .dir_entry_name_len(),
        .dir_entry_first_cluster(ro_dir_dat[`VDIR_D_FCLUST]),
        .dir_entry_size(ro_dir_dat[`VDIR_D_SIZE]),
        .dir_entry_attr(), .dir_entry_is_dir(ro_dir_dat[`VDIR_D_ISDIR]),
        .dir_entry_is_lfn(), .dir_done(ro_dir_dat[`VDIR_D_DONE]),
        .dir_ok(ro_dir_dat[`VDIR_D_OK]),
        .file_start(ro_file_start), .file_first_cluster(ro_cluster),
        .file_size(ro_size), .file_read_limit(ro_limit),
        .file_read_ready(owner==TXT || file_read_ready), .file_abort(file_abort && owner==BMP),
        .map_start(ro_map_start), .map_first_cluster(ro_map_cluster),
        .map_size(ro_map_size), .map_abort(map_abort && owner==MAP),
        .map_busy(ro_map_busy), .map_done(map_done), .map_ok(map_ok),
        .map_accept(ro_map_accept),
        .map_entry_valid(map_wr_en), .map_entry_lba(map_wr_lba),
        .map_entry_nsec(map_wr_nsec), .map_entry_last(map_wr_last),
        .file_busy(ro_file_busy),.operation_idle(ro_idle),
        .file_data(ro_data), .file_data_valid(ro_file_valid),
        .file_done(ro_file_done), .file_ok(ro_file_ok),
        .dbg_fat_state(dbg_fat_state),
        .dbg_dir_entry_count(dbg_dir_count)
    );

endmodule
