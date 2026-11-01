//=============================================================================
// tb_fat_wav_controller
//   fat_wav_controller + 真实 lba_stream(MAX_BURST=2) 的联合测试。
//   map / SD 通道 / 音频环用行为模型替身。
//
//   虚拟文件：44B 规范 WAV 头 + 1,920,000 B 载荷（48kHz/16bit/立体声 =
//   480000 帧 = 10 s）。字节内容 = 文件偏移低 8 位（头除外）⇒ seek 后首个
//   样本的期望值可以直接算出来，验证"真的从目标位置继续播"。
//
//   覆盖（T1~T5）：
//     T1 选曲 → payload_start 时 ack、o_payload_frames=480000、toggle 翻转
//     T2 正常流推进
//     T3 长按快进（核心）：str_abort → P_SEEK 重启 → 首个环字 == 目标帧内容
//     T4 连续快进 → 曲尾钳位
//     T5 seek 后换曲恢复（不 wedge）
//=============================================================================
`timescale 1ns/1ps
module tb_fat_wav_controller #(parameter EXTERNAL_POSITION=0);

    reg clk = 1'b0;
    always #5 clk = ~clk;               // 100 MHz
    reg rst = 1'b1;

    //-------------------------------------------------------------------------
    // 虚拟 WAV 文件
    //-------------------------------------------------------------------------
    localparam [31:0] PAYLOAD_BYTES = 32'd1920000;   // 480000 帧 × 4 B
    localparam [31:0] FILE_BYTES    = 32'd44 + PAYLOAD_BYTES;

    reg [7:0] hdr [0:43];
    initial begin
        hdr[ 0]="R"; hdr[ 1]="I"; hdr[ 2]="F"; hdr[ 3]="F";
        hdr[ 4]=8'h24; hdr[ 5]=8'h4A; hdr[ 6]=8'h1D; hdr[ 7]=8'h00;
        hdr[ 8]="W"; hdr[ 9]="A"; hdr[10]="V"; hdr[11]="E";
        hdr[12]="f"; hdr[13]="m"; hdr[14]="t"; hdr[15]=" ";
        hdr[16]=8'h10; hdr[17]=8'h00; hdr[18]=8'h00; hdr[19]=8'h00;
        hdr[20]=8'h01; hdr[21]=8'h00;
        hdr[22]=8'h02; hdr[23]=8'h00;
        hdr[24]=8'h80; hdr[25]=8'hBB; hdr[26]=8'h00; hdr[27]=8'h00;
        hdr[28]=8'h00; hdr[29]=8'hEE; hdr[30]=8'h02; hdr[31]=8'h00;
        hdr[32]=8'h04; hdr[33]=8'h00;
        hdr[34]=8'h10; hdr[35]=8'h00;
        hdr[36]="d"; hdr[37]="a"; hdr[38]="t"; hdr[39]="a";
        hdr[40]=8'h00; hdr[41]=8'h4C; hdr[42]=8'h1D; hdr[43]=8'h00;  // 0x1D4C00=1920000
    end

    function [7:0] file_byte;
        input [31:0] off;
        begin
            if (off < 32'd44) file_byte = hdr[off[5:0]];
            else              file_byte = off[7:0];
        end
    endfunction

    //-------------------------------------------------------------------------
    // 全部信号声明（必须在例化之前 —— 隐式网坑）
    //-------------------------------------------------------------------------
    reg         ext_play_req;
    reg  [31:0] ext_play_cluster, ext_play_size;
    wire        ext_play_ack, ext_play_rejected;
    wire        play_busy, play_idle;
    wire [3:0]  play_status;
    reg         ext_seek_fwd;
    wire [31:0] o_pos_frames, o_payload_frames;
    wire        o_stream_is_seek, o_stream_toggle;

    wire        map_start, map_abort;
    wire [31:0] map_first_cluster, map_size;
    wire        map_busy, map_done, map_ok;

    wire [8:0]  s_map_addr;
    wire [31:0] s_map_lba, s_map_nsec;
    reg  [31:0] map_rd_lba_r, map_rd_nsec_r;
    reg  [31:0] seg_lba  [0:1];
    reg  [31:0] seg_nsec [0:1];
    reg  [7:0]  map_wait;
    reg         map_done_r, map_ok_r;

    wire        str_start, str_abort, str_ready, str_busy;
    wire [31:0] str_file_off, str_len;
    wire [7:0]  str_data;
    wire        str_data_valid, str_done, str_ok, str_error, str_aborted;
    wire [1:0]  str_retry_used;

    wire        blk_req;
    wire [31:0] blk_lba;
    wire [15:0] blk_count;
    reg         gnt_hit, burst_last, bursting;
    reg  [31:0] gnt_cnt, cur_lba_r, byte_off;
    reg  [15:0] burst_left;
    reg  [7:0]  blk_data;
    wire        blk_grant      = gnt_hit;
    wire        blk_data_valid = bursting;
    wire        blk_end        = burst_last;

    wire        ring_push, ring_clear, ring_flush;
    wire [31:0] ring_data;

    integer     push_cnt;
    reg [31:0]  first_word_after_seek;
    reg         cap_arm;

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    reg [31:0] played_frames=0,absolute_target=0;
    reg absolute_seek=0,positioned_open=0;reg [31:0] open_position=0;
    fat_wav_controller #(.EXTERNAL_POSITION(EXTERNAL_POSITION)) dut (
        .clk(clk), .rst(rst),
        .ext_play_req(ext_play_req), .ext_play_cluster(ext_play_cluster),
        .ext_play_size(ext_play_size),.start_at_position(positioned_open),.initial_position(open_position),
        .ext_play_ack(ext_play_ack), .ext_play_rejected(ext_play_rejected),
        .play_stop(1'b0), .play_busy(play_busy), .play_idle(play_idle),
        .play_status(play_status),
        .map_start(map_start), .map_first_cluster(map_first_cluster),
        .map_size(map_size), .map_abort(map_abort),
        .map_busy(map_busy), .map_done(map_done), .map_ok(map_ok),
        .str_start(str_start), .str_file_off(str_file_off), .str_len(str_len),
        .str_abort(str_abort), .str_ready(str_ready),
        .str_data(str_data), .str_data_valid(str_data_valid),
        .str_done(str_done), .str_ok(str_ok), .str_error(str_error),
        .str_busy(str_busy),
        .ring_push(ring_push), .ring_data(ring_data), .ring_ready(1'b1),
        .ring_clear(ring_clear), .ring_flush(ring_flush),
        .o_payload_frames(o_payload_frames),
        .o_stream_is_seek(o_stream_is_seek),
        .o_stream_toggle(o_stream_toggle),
        .ext_seek_fwd(ext_seek_fwd), .o_pos_frames(o_pos_frames),
        .i_played_frames(played_frames),.absolute_seek(absolute_seek),.absolute_target(absolute_target),.o_stream_base()
    );

    lba_stream #(.CHANNEL(1), .MAX_BURST(2)) u_str (
        .clk(clk), .rst(rst),
        .map_rd_addr(s_map_addr[7:0]), .map_rd_lba(s_map_lba), .map_rd_nsec(s_map_nsec),
        .map_count(9'd2),
        .str_start(str_start), .str_file_off(str_file_off), .str_len(str_len),
        .str_abort(str_abort), .str_ready(str_ready),
        .str_data(str_data), .str_data_valid(str_data_valid),
        .str_done(str_done), .str_ok(str_ok), .str_error(str_error),
        .str_aborted(str_aborted), .str_busy(str_busy),
        .str_retry_used(str_retry_used),
        .blk_req(blk_req), .blk_lba(blk_lba), .blk_count(blk_count),
        .blk_grant(blk_grant), .blk_data(blk_data),
        .blk_data_valid(blk_data_valid), .blk_end(blk_end), .blk_error(1'b0)
    );

    //-------------------------------------------------------------------------
    // 假 map bank1：2 段；读延迟 1 拍（对齐 fat_chain_map 同步读）
    //-------------------------------------------------------------------------
    assign s_map_lba  = map_rd_lba_r;
    assign s_map_nsec = map_rd_nsec_r;
    always @(posedge clk) begin
        map_rd_lba_r  <= seg_lba [s_map_addr[1:0]];
        map_rd_nsec_r <= seg_nsec[s_map_addr[1:0]];
    end

    wire map_busy_f = (map_wait != 8'd0);
    assign map_busy = map_busy_f;
    assign map_done = map_done_r;
    assign map_ok   = map_ok_r;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            map_wait<=8'd0; map_done_r<=1'b0; map_ok_r<=1'b0;
        end else begin
            map_done_r <= 1'b0;
            if (map_start) begin
                map_wait <= 8'd20; map_ok_r <= 1'b1;
            end else if (map_wait != 8'd0) begin
                map_wait <= map_wait - 8'd1;
                if (map_wait == 8'd1) map_done_r <= 1'b1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 假 SD 通道
    //-------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bursting<=1'b0; gnt_cnt<=32'd0; burst_left<=16'd0;
            cur_lba_r<=32'd0; byte_off<=32'd0;
            gnt_hit<=1'b0; burst_last<=1'b0; blk_data<=8'd0;
        end else begin
            gnt_hit    <= 1'b0;
            burst_last <= 1'b0;
            blk_data   <= file_byte((cur_lba_r - 32'd1000)*32'd512 + byte_off);

            if (!bursting) begin
                if (blk_req) begin
                    if (gnt_cnt == 32'd8) begin
                        gnt_hit    <= 1'b1;
                        bursting   <= 1'b1;
                        burst_left <= blk_count;
                        cur_lba_r  <= blk_lba;
                        byte_off   <= 32'd0;
                    end else gnt_cnt <= gnt_cnt + 32'd1;
                end else gnt_cnt <= 32'd0;
            end else begin
                if (byte_off == 32'd511) begin
                    byte_off   <= 32'd0;
                    cur_lba_r  <= cur_lba_r + 32'd1;
                    burst_left <= burst_left - 16'd1;
                    if (burst_left == 16'd1) begin
                        bursting   <= 1'b0;
                        burst_last <= 1'b1;
                        gnt_cnt    <= 32'd0;
                    end
                end else byte_off <= byte_off + 32'd1;
            end
        end
    end

    initial begin
        seg_lba[0]=32'd1000;  seg_nsec[0]=32'd2000;
        seg_lba[1]=32'd5000;  seg_nsec[1]=32'd3000;
    end

    //-------------------------------------------------------------------------
    // 环监视
    //-------------------------------------------------------------------------
    initial push_cnt = 0;
    always @(posedge clk) begin
        if (ring_push) begin
            push_cnt = push_cnt + 1;
            if (cap_arm) begin
                first_word_after_seek <= ring_data;
                cap_arm <= 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 测试序列
    //-------------------------------------------------------------------------
    integer errors = 0;
    integer i;
    reg [31:0] toggle0, exp_off, tgt;

    task chk;
        input         cond;
        input [255:0] name;
        begin
            if (cond) $display("[OK]   %0s", name);
            else begin
                $display("[FAIL] %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        ext_play_req=0; ext_play_cluster=0; ext_play_size=0; ext_seek_fwd=0;
        cap_arm = 1'b0;
        rst = 1'b1; #120; @(posedge clk); rst <= 1'b0; #1;

        // ---- T1 选曲 ----
        $display("---- T1 选曲");
        ext_play_req=1; ext_play_cluster=32'd777; ext_play_size=FILE_BYTES;
        @(posedge clk); #1; ext_play_req=0;
        i=0;
        while (!ext_play_ack && i < 200000) begin @(posedge clk); #1; i=i+1; end
        if (i>=200000) begin
            $display("[FAIL] T1 ack 超时（dut.state=%0d str.state=%0d）",
                     dut.state, u_str.state);
            errors = errors + 1;
        end
        chk(!ext_play_rejected,           "T1 未被拒绝");
        chk(o_payload_frames == 32'd480000, "T1 payload_frames=480000");
        toggle0 = {31'd0, o_stream_toggle};
        chk(toggle0 == 32'd1, "T1 toggle 翻转一次");

        // ---- T2 正常流 ----
        $display("---- T2 正常流");
        i=0;
        while (push_cnt < 300 && i < 100000) begin @(posedge clk); #1; i=i+1; end
        chk(push_cnt >= 300,             "T2 推流推进");
        if(EXTERNAL_POSITION) begin
            played_frames=1234;#1;
            chk(o_pos_frames==1234,"T2 position uses playback feedback, independent of read-ahead");
        end else chk(o_pos_frames == 32'd300, "T2 pos_frames=300");

        // ---- T3 长按快进 ----
        $display("---- T3 长按快进");
        toggle0 = {31'd0, o_stream_toggle};
        @(posedge clk); #1; ext_seek_fwd=1;
        if(EXTERNAL_POSITION) played_frames=2234;
        @(posedge clk); #1; ext_seek_fwd=0;
        i=0;
        while (o_stream_toggle == toggle0[0] && i < 500000) begin
            @(posedge clk); #1; i=i+1;
        end
        if (i >= 500000) begin
            $display("[FAIL] T3 seek 重启超时（dut.state=%0d str.state=%0d str_busy=%b）",
                     dut.state, u_str.state, str_busy);
            errors = errors + 1;
        end
        chk(o_stream_is_seek == 1'b1, "T3 is_seek=1");
        tgt = dut.pos_base;
        $display("       seek_target=%0d", tgt);
        chk(tgt > 32'd200000 && tgt < 32'd280000, "T3 目标 ≈ pos+240000");
        if(EXTERNAL_POSITION) chk(tgt==242234,"T3 seek captures playback feedback on request cycle");

        cap_arm = 1'b1;
        i=0;
        while (cap_arm && i < 100000) begin @(posedge clk); #1; i=i+1; end
        exp_off = 32'd44 + tgt*4;
        $display("       first_word=%h expected=%h", first_word_after_seek,
                 {file_byte(exp_off+1), file_byte(exp_off),
                  file_byte(exp_off+3), file_byte(exp_off+2)});
        chk(first_word_after_seek === {file_byte(exp_off+1), file_byte(exp_off),
                                       file_byte(exp_off+3), file_byte(exp_off+2)},
            "T3 重启首字内容 == 目标帧样本");

        // ---- T4 快进到曲尾钳位 ----
        $display("---- T4 曲尾钳位");
        if(EXTERNAL_POSITION) played_frames=300000;
        toggle0 = {31'd0, o_stream_toggle};
        @(posedge clk); #1; ext_seek_fwd=1;
        @(posedge clk); #1; ext_seek_fwd=0;
        i=0;
        while (o_stream_toggle == toggle0[0] && i < 500000) begin
            @(posedge clk); #1; i=i+1;
        end
        if (i >= 500000) begin
            $display("[FAIL] T4 seek 超时（dut.state=%0d str.state=%0d）",
                     dut.state, u_str.state);
            errors = errors + 1;
        end
        $display("       pos_base=%0d", dut.pos_base);
        chk(dut.pos_base == 32'd432000, "T4 目标被钳到 payload-1s");
        if(EXTERNAL_POSITION) played_frames=432000;
        // 已在最后 1 秒内：再快进应被守卫忽略（toggle 不翻转）
        toggle0 = {31'd0, o_stream_toggle};
        @(posedge clk); #1; ext_seek_fwd=1;
        @(posedge clk); #1; ext_seek_fwd=0;
        i=0;
        while (o_stream_toggle == toggle0[0] && i < 5000) begin
            @(posedge clk); #1; i=i+1;
        end
        chk(i >= 5000, "T4 曲尾守卫忽略多余快进（toggle 不翻转）");
        chk(dut.pos_base == 32'd432000, "T4 守卫后位置不变");

        // ---- T5 seek 后换曲恢复 ----
        $display("---- T5 seek 后换曲恢复");
        played_frames=0;
        toggle0 = {31'd0, o_stream_toggle};
        @(posedge clk); #1;
        ext_play_req=1; ext_play_cluster=32'd888; ext_play_size=FILE_BYTES;
        @(posedge clk); #1; ext_play_req=0;
        i=0;
        while (!ext_play_ack && i < 300000) begin @(posedge clk); #1; i=i+1; end
        if (i>=300000) begin
            $display("[FAIL] T5 ack 超时（dut.state=%0d str.state=%0d）",
                     dut.state, u_str.state);
            errors = errors + 1;
        end
        chk(o_stream_toggle != toggle0[0], "T5 换曲 toggle 再翻转");
        chk(o_stream_is_seek == 1'b0,      "T5 新曲 is_seek=0");
        chk(o_pos_frames <= 32'd100,       "T5 位置回零附近");

        if(EXTERNAL_POSITION) begin
            toggle0={31'd0,o_stream_toggle};
            @(negedge clk);absolute_target=12345;absolute_seek=1;
            @(negedge clk);absolute_seek=0;
            wait(o_stream_toggle!=toggle0[0]);
            chk(dut.pos_base==12345,"T6 reconnect resumes at confirmed absolute sample");
            cap_arm=1;
            wait(!cap_arm);
            exp_off=44+12345*4;
            chk(first_word_after_seek==={file_byte(exp_off+1),file_byte(exp_off),file_byte(exp_off+3),file_byte(exp_off+2)},
                "T6 resume sample content");
        end

        // Reopen a different-file stream directly at an exact saved position.
        // Arm the sample checker BEFORE the request, so any leaked frame zero fails.
        positioned_open=1;open_position=12345;cap_arm=0;
        toggle0={31'd0,o_stream_toggle};
        @(negedge clk);ext_play_req=1;
        @(negedge clk);ext_play_req=0;
        wait(ring_clear);@(negedge clk);cap_arm=1;
        wait(ext_play_ack);wait(!cap_arm);
        exp_off=44+12345*4;
        chk(dut.pos_base==12345,"T7 reopened stream starts at saved frame");
        chk(o_stream_toggle!=toggle0[0],"T7 new epoch has a single rebase");
        chk(first_word_after_seek==={file_byte(exp_off+1),file_byte(exp_off),file_byte(exp_off+3),file_byte(exp_off+2)},
            "T7 first delivered sample is saved position, no frame-zero leakage");
        positioned_open=0;

        if (errors == 0) $display("*** PASS *** tb_fat_wav_controller");
        else             $display("*** FAIL *** %0d errors", errors);
        $finish;
    end

    // 全局看门狗
    initial begin
        #80_000_000;
        $display("*** FAIL *** 全局超时（dut.state=%0d str.state=%0d）",
                 dut.state, u_str.state);
        $finish;
    end

    // ---- 状态迁移跟踪（定位 seek 后流为何提前结束）----
    reg [3:0]  d_state_r = 4'd15;
    reg [3:0]  s_state_r = 4'd15;
    reg [31:0] fl_r = 32'hFFFFFFFF;

    // ---- unpack 门控探针 ----
    integer byte_seen = 0, pair_seen = 0;
    reg     ha_r = 1'b0;
    always @(posedge clk) begin
        if (str_data_valid) byte_seen = byte_seen + 1;
        if (dut.up_valid)   pair_seen = pair_seen + 1;
        if (dut.hdr_active !== ha_r) begin
            $display("[%0t] hdr_active %b→%b (dut.state=%0d str.state=%0d)",
                     $time, ha_r, dut.hdr_active, dut.state, u_str.state);
            ha_r = dut.hdr_active;
        end
    end

    always @(posedge clk) begin
        if (dut.state !== d_state_r || u_str.state !== s_state_r ||
            u_str.file_left !== fl_r) begin
            if ((d_state_r != dut.state) || (s_state_r != u_str.state) ||
                ((fl_r - u_str.file_left) > 32'd4096) || (u_str.file_left > fl_r))
                $display("[%0t] dut.state=%0d→%0d str.state=%0d→%0d file_left=%0d→%0d seg=%0d str_len=%0d off=%0d pf=%0d ch=%b push=%0d bytes=%0d pairs=%0d",
                         $time, d_state_r, dut.state, s_state_r, u_str.state,
                         fl_r, u_str.file_left, u_str.seg_idx,
                         str_len, str_file_off, o_payload_frames, dut.channels, push_cnt,
                         byte_seen, pair_seen);
            d_state_r = dut.state;
            s_state_r = u_str.state;
            fl_r      = u_str.file_left;
        end
    end

endmodule
