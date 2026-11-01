//=============================================================================
// tb_fat32_timeout —— fat32_ro 的 IO 超时路径回归（Verilog-2001）
//
// 背景：io_timeout 的判定在 2026-09-26 的时序收口里从「当场做 28 位比较」
// 改成「预寄存 io_timeout_last」，检查拍只看寄存器位。该路径在既有
// tb_fat32_ro 里完全没有覆盖（那边的默认超时是"秒级"，仿真跑不到），
// 所以这里用 IO_TIMEOUT_CYCLES=200 造超时场景：
//   （注：2026-09-28 把 RTL 默认值从 28'd100_000_000(1 s) 收到 28'd5_000_000(50 ms)，
//     本 TB 一律按自己的 TMO 参数断言，两种默认值下都成立。）
//
//   T1 S_RD_REQ 超时  —— 请求发出但永远拿不到 grant（卡无响应 / 未插卡）
//   T2 S_RD_WAIT 超时 —— grant 给了一拍但数据永不到（数据阶段卡死）
//   T3 可恢复         —— 超时后复位重来，能再次正常超时（FSM 未卡死）
//
// 断言：mount_done=1 / mount_ok=0 / fat_error_code == FAT_E_TIMEOUT，
//       超时拍数落在 IO_TIMEOUT_CYCLES 附近（新实现比旧实现少 1 拍）。
//=============================================================================
`timescale 1ns/1ps
`include "fat_err_codes.vh"

module tb_fat32_timeout;

    localparam integer TMO = 200;               // DUT 的 IO_TIMEOUT_CYCLES

    reg         clk = 1'b0;
    always #5 clk = ~clk;
    reg         rst = 1'b1;

    // ---- DUT 端口 ----
    wire        blk_req;
    wire [31:0] blk_lba;
    wire [15:0] blk_count;
    reg         blk_grant   = 1'b0;
    reg  [7:0]  blk_data    = 8'h00;
    reg         blk_data_valid = 1'b0;
    reg         blk_end     = 1'b0;
    reg         blk_error   = 1'b0;

    reg         mount_start = 1'b0;
    wire        mount_done, mount_ok;
    wire [7:0]  fat_error_code;

    reg         dir_start = 1'b0;
    wire        dir_entry_start, dir_name_valid, dir_entry_end, dir_done, dir_ok;
    wire [7:0]  dir_name_char, dir_name_index, dir_entry_name_len, dir_entry_attr;
    wire [31:0] dir_entry_first_cluster, dir_entry_size;
    wire        dir_entry_is_dir, dir_entry_is_lfn;

    reg         file_start = 1'b0;
    reg  [31:0] file_first_cluster = 32'd0, file_size = 32'd0, file_read_limit = 32'd0;
    reg         file_read_ready = 1'b1, file_abort = 1'b0;
    wire        file_busy, file_done, file_ok, file_data_valid;
    wire [7:0]  file_data;

    reg         map_start = 1'b0, map_abort = 1'b0;
    reg  [31:0] map_first_cluster = 32'd0, map_size = 32'd0;
    wire        map_busy, map_accept, map_done, map_ok, map_entry_valid, map_entry_last;
    wire [31:0] map_entry_lba, map_entry_nsec;

    wire [7:0]  dbg_fat_state;
    wire [31:0] dbg_dir_entry_count;

    fat32_ro #(
        .IO_TIMEOUT_CYCLES ( TMO )
    ) dut (
        .clk(clk), .rst(rst),
        .blk_req(blk_req), .blk_lba(blk_lba), .blk_count(blk_count),
        .blk_grant(blk_grant), .blk_data(blk_data),
        .blk_data_valid(blk_data_valid), .blk_end(blk_end), .blk_error(blk_error),
        .mount_start(mount_start), .mount_done(mount_done), .mount_ok(mount_ok),
        .fat_error_code(fat_error_code),
        .dir_start(dir_start), .dir_entry_start(dir_entry_start),
        .dir_name_valid(dir_name_valid), .dir_name_char(dir_name_char),
        .dir_name_index(dir_name_index), .dir_entry_end(dir_entry_end),
        .dir_entry_name_len(dir_entry_name_len),
        .dir_entry_first_cluster(dir_entry_first_cluster),
        .dir_entry_size(dir_entry_size), .dir_entry_attr(dir_entry_attr),
        .dir_entry_is_dir(dir_entry_is_dir), .dir_entry_is_lfn(dir_entry_is_lfn),
        .dir_done(dir_done), .dir_ok(dir_ok),
        .file_start(file_start), .file_first_cluster(file_first_cluster),
        .file_size(file_size), .file_read_limit(file_read_limit),
        .file_read_ready(file_read_ready), .file_abort(file_abort), .file_busy(file_busy),
        .map_start(map_start), .map_first_cluster(map_first_cluster),
        .map_size(map_size), .map_abort(map_abort), .map_busy(map_busy),
        .map_accept(map_accept), .map_done(map_done), .map_ok(map_ok),
        .map_entry_valid(map_entry_valid), .map_entry_lba(map_entry_lba),
        .map_entry_nsec(map_entry_nsec), .map_entry_last(map_entry_last),
        .file_data(file_data), .file_data_valid(file_data_valid),
        .file_done(file_done), .file_ok(file_ok),
        .dbg_fat_state(dbg_fat_state), .dbg_dir_entry_count(dbg_dir_entry_count)
    );

    integer errors = 0;
    integer cyc;

    task do_reset;
        begin
            rst = 1'b1;
            mount_start = 1'b0; dir_start = 1'b0; file_start = 1'b0; map_start = 1'b0;
            blk_grant = 1'b0; blk_end = 1'b0; blk_error = 1'b0; blk_data_valid = 1'b0;
            repeat (4) @(posedge clk);
            #1 rst = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    task chk;
        input cond;
        input [255:0] msg;
        begin
            if (!cond) begin
                $display("[FAIL] %0s", msg);
                errors = errors + 1;
            end else $display("[OK]   %0s", msg);
        end
    endtask

    // 等 mount_done，最多 maxc 拍；cyc 返回实际等到第几拍
    task wait_mount;
        input integer maxc;
        begin
            cyc = 0;
            while (!mount_done && cyc < maxc) begin
                @(posedge clk); #1;
                cyc = cyc + 1;
            end
        end
    endtask

    initial begin
        $display("==== tb_fat32_timeout (IO_TIMEOUT_CYCLES=%0d) ====", TMO);

        //-------------------------------------------------------------------
        // T1：S_RD_REQ 超时 —— 请求永不 grant
        //-------------------------------------------------------------------
        $display("---- T1 S_RD_REQ timeout");
        do_reset;
        mount_start = 1'b1;
        @(posedge clk); #1; mount_start = 1'b0;
        wait_mount(TMO*4);
        chk(mount_done === 1'b1,               "T1 mount_done asserted");
        chk(mount_ok   === 1'b0,               "T1 mount_ok=0");
        chk(fat_error_code === `FAT_E_TIMEOUT, "T1 error code = FAT_E_TIMEOUT");
        chk(cyc >= TMO-3 && cyc <= TMO+3,      "T1 timeout cycle near IO_TIMEOUT_CYCLES");
        $display("       T1 elapsed = %0d cycles", cyc);

        //-------------------------------------------------------------------
        // T2：S_RD_WAIT 超时 —— grant 一拍，数据永不到
        //-------------------------------------------------------------------
        $display("---- T2 S_RD_WAIT timeout");
        do_reset;
        mount_start = 1'b1;
        @(posedge clk); #1; mount_start = 1'b0;
        // 等 DUT 发出块请求
        cyc = 0;
        while (!blk_req && cyc < 40) begin @(posedge clk); #1; cyc = cyc + 1; end
        chk(blk_req === 1'b1, "T2 blk_req asserted");
        @(posedge clk); #1 blk_grant = 1'b1;      // 给一拍 grant
        @(posedge clk); #1 blk_grant = 1'b0;
        wait_mount(TMO*4);
        chk(mount_done === 1'b1,               "T2 mount_done asserted");
        chk(mount_ok   === 1'b0,               "T2 mount_ok=0");
        chk(fat_error_code === `FAT_E_TIMEOUT, "T2 error code = FAT_E_TIMEOUT");
        chk(dbg_fat_state === 8'd0,            "T2 FSM back to S_IDLE");
        $display("       T2 elapsed = %0d cycles", cyc);

        //-------------------------------------------------------------------
        // T3：可恢复 —— 复位后再来一次，仍能正常超时（FSM 未卡死）
        //-------------------------------------------------------------------
        $display("---- T3 recover / repeat");
        do_reset;
        mount_start = 1'b1;
        @(posedge clk); #1; mount_start = 1'b0;
        wait_mount(TMO*4);
        chk(mount_done === 1'b1,               "T3 second timeout completes");
        chk(fat_error_code === `FAT_E_TIMEOUT, "T3 error code = FAT_E_TIMEOUT");
        chk(dbg_fat_state === 8'd0,            "T3 FSM idle after timeout");
        $display("       T3 elapsed = %0d cycles", cyc);

        if (errors == 0) $display("*** PASS *** fat32_ro IO timeout paths");
        else             $display("*** FAIL *** %0d error(s)", errors);
        $finish;
    end

    initial begin
        #4000000;
        $display("*** FAIL *** global timeout (state=%0d)", dbg_fat_state);
        $finish;
    end

endmodule
