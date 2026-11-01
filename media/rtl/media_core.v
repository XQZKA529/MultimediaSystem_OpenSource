`include "pkg/video_bmp_params.vh"
`include "pkg/fat_dir_bus.vh"
module media_core(
    input wire emergency_request_valid,input wire [1:0] emergency_request_mode,
    input wire [31:0] emergency_request_revision,input wire [127:0] emergency_request_snapshot,
    output wire emergency_reply_valid,input wire emergency_reply_ready,
    output wire [31:0] emergency_reply_revision,output wire [7:0] emergency_reply_status,
    input wire [31:0] audio_epoch,audio_file_epoch,audio_consumed_epoch,audio_dispatch_epoch,input wire audio_dispatch_valid,
    input wire keypad_valid,keypad_cancel,input wire [5:0] keypad_data,
    input wire clk,rst,link_up,remote_playing,input wire KEY2,KEY3,KEY4,
    input wire subtitle_session_reset,image_presented,input wire [31:0] presented_image_id,input wire render_image_transport_idle,
    output wire subtitle_valid,input wire subtitle_ready,output wire [31:0] subtitle_revision,
    output wire subtitle_word_valid,input wire subtitle_word_ready,output wire [31:0] subtitle_word,
    input wire subtitle_applied,input wire [31:0] subtitle_applied_revision,input wire [1:0] subtitle_applied_result,
    output wire SD_CLK,inout wire SD_CMD,input wire SD_DAT0,SD_DAT1,SD_DAT2,SD_DAT3,
    output wire image_req,input wire image_ack,image_finish_toggle,image_burst_ready,image_pixel_ready,
    output wire image_word_valid,output wire [31:0] image_word,
    output wire image_source_ok,image_source_failed,input wire image_replay,
    output wire overlay_begin_req,output wire [31:0] overlay_begin_object,input wire overlay_begin_ack,overlay_begin_ready,overlay_failed,
    output wire overlay_abort_req,output wire overlay_word_valid,output wire [31:0] overlay_word,input wire overlay_word_ready,overlay_burst_ready,
    output wire overlay_source_ok,output wire overlay_source_failed,input wire overlay_applied,
    output wire pcm_push,output wire [31:0] pcm,output wire pcm_clear,pcm_eof,
    input wire pcm_burst_ready,output wire [31:0] pcm_total,pcm_base,
    output wire pcm_stream_toggle,output wire paused,seek_request,
    input wire seek_execute,resume_request,input wire [31:0] played_position,
    output wire ui_wr_en,output wire [8:0] ui_wr_addr,output wire [7:0] ui_wr_data,
    output wire [4:0] volume_level,output wire volume_changed,volume_hint,output wire [31:0] volume_revision,
    output wire [4:0] contrast_level,output wire [4:0] saturation_level,input wire [1:0] brightness_mode,output wire [3:0] brightness_level,
    output wire [1:0] transition_mode,
    output wire text_osd_page,
    output wire [3:0] ui_page,
    output wire ui_active,ui_cursor_en,ui_commit_toggle,output wire [3:0] ui_cursor_row,
    output wire [3:0] diag,output wire display_valid,
    output wire DBG_SD_INIT_DONE,DBG_SD_INIT_ERROR,DBG_SD_HIGH_SPEED,DBG_SD_BUS4,DBG_SD_RD_ERROR,
    output wire [3:0] DBG_SD_ERR_CODE,output wire [4:0] DBG_SD_STATE,
    output wire DBG_UI_ACTIVE,output wire [3:0] DBG_UI_STATE,output wire [7:0] DBG_WAV_STATUS
);
    wire sd_card_clk=clk,rst_sd=rst;
    localparam FRAME_PIXELS=`VBP_FRAME_PIXELS;
    wire frame_write_toggle_mem=image_finish_toggle;
    wire sd_pixel_valid;
    wire [23:0] sd_pixel_rgb;
    wire packed_write_en;
    wire [31:0] packed_write_data;
    wire pack_alignment_error;
    wire pack_overflow_error;
    wire sd_write_req;
    wire sd_write_req_ack;
    wire frame_write_finish;
    wire [1:0] write_buf_idx;
    wire [1:0] disp_buf_idx;

    wire [3:0] state_code;

    //--------------------------------------------------------------------------
    // SD 子系统（★ 全工程唯一持有 SD 物理引脚的地方）
    //   内部是 SDIO 4-bit 引擎；对外把 SD 卡抽象成"授权式突发读通道"，
    //   通道 0 给图像，通道 1 预留给视频播放 / 音乐读取。
    //--------------------------------------------------------------------------
    wire        sd_init_done;
    wire        sd_init_error;
    wire [7:0]  sd_init_err_code;
    wire        sd_high_speed;
    wire [1:0]  sd_bus_width;
    wire        sd_is_sdhc;
    wire [15:0] sd_card_rca;
    wire [4:0]  dbg_sd_state;
    wire [5:0]  dbg_sd_resp_cmd;
    wire [31:0] dbg_sd_resp_arg;
    wire [7:0]  dbg_sd_switch_fn;
    wire [15:0] dbg_sd_clk_div;

    // 通道 0：SD 子系统 → 存储侧（glue_storage / fat32_ro）
    wire        ch0_req;
    wire [31:0] ch0_sector;
    wire [15:0] ch0_count;
    wire        ch0_grant;
    wire [7:0]  ch0_data;
    wire        ch0_data_valid;
    wire        ch0_end;
    wire        ch0_error;

    // 通道 1：lba_stream1（WAV）
    wire        ch1_req;
    wire [31:0] ch1_sector;
    wire [15:0] ch1_count;
    wire        ch1_grant;
    wire [7:0]  ch1_data;
    wire        ch1_data_valid;
    wire        ch1_end;
    wire        ch1_error;

    wire [15:0] sd_rd_err_cnt = 16'd0;
    wire        sd_rd_err_seen;

    // 图像层给出的诊断码（上屏显示为 "ERROR n"）
    wire [3:0]  diag_code;

    sd_card_sdio #(
        .CLK_FREQ_HZ     (`VBP_SD_CLK_HZ),
        .SD_CLK_DIV_INIT (125),     // 400 kHz 初始化
        .SD_CLK_DIV_FAST (1),       // 25 MHz  默认速度（bus 50MHz ⇒ 50/(2*1)=25MHz）
        .SD_CLK_DIV_HS   (1),       // 50 MHz  High Speed（保留，勿删）
        // SAMPLE_DLY = 1: capture the card's output 20ns after the SD_CLK rise
        // instead of 10ns (div_r=2 ⇒ one step is 10ns of clk, so the sample
        // point is ck_rise + (1+SAMPLE_DLY) clk).  At 25MHz the bit period is
        // 40ns and the card launches on the SD_CLK FALLING edge, so the natural
        // centre of the card's valid window is ~20ns after the rise - exactly
        // SAMPLE_DLY=1.  The old value 0 sampled at +10ns, i.e. only 25% into
        // the period, which left no margin for the one delay element that STA
        // cannot see: the unconstrained `u_phy/sdclk_reg -> SD_CLK` output path.
        // That path adds straight into the loop (it delays the card's launch
        // relative to the host's sample clock) and moves every time P&R re-rolls
        // at high utilisation - the documented cause of "reads get slower as
        // utilisation rises".  SAMPLE_DLY=1 buys back a full 10ns of that.
        // Legal only while div_r > SAMPLE_DLY, i.e. only at DIV_FAST=2 (25MHz);
        // the knob is a no-op at DIV_HS=1, a second reason to stay at 25MHz.
        // 2026-10-30：bus_clk 降到 50 MHz 后，DIV_FAST=1、SAMPLE_DLY=0。
        // 采样点公式为 ck_rise + (1+SAMPLE_DLY) 个 clk：在 50MHz/div=1 时
        // 1 clk = 20ns，与原来 100MHz/div=2、SAMPLE_DLY=1 的"上升沿后 20ns"
        // 完全同一物理位置（25MHz 位眼中心）。SD_CLK 仍是 50/(2*1)=25MHz，
        // 读卡带宽一分不少。div_r > SAMPLE_DLY 的约束在 div=1 下要求 SAMPLE_DLY=0。
        .SAMPLE_DLY      (0),       // 上升沿后 20ns（50MHz 下 1 clk）采样
        //-------------------------------------------------------------------------
        // ★ SPEED_TARGET = 0：**停在 25 MHz**，不切 50 MHz High Speed。
        //
        // 为什么必须退回来（2026-09-28）：本设计的 SD 采样相位**没有任何约束**——
        //   · 输入侧只有 `set_max_delay 8`（见 constr/hdmi_colorbar.sdc）；
        //   · `SD_CLK` 输出侧（`u_phy/sdclk_reg` → 引脚）完全不进 STA。
        // 采样点 = 内部 ck_rise + 1 个 sd_card_clk(10 ns)，而"内部 ck_rise → 卡 → 数据回来"
        // 的总延迟里有几 ns 是不受控的布局量。50 MHz 时位周期只有 20 ns，这点偏移就会
        // 把采样点挤到位边界外 → 数据 CRC16 错 → `blk_error` → fat32_ro 判 FAT_E_RD
        // → fat_bmp_controller **整张图重读**（LOAD_RETRY_MAX=2，最坏 3 遍）。
        // 利用率 79% 时布局有余量、这个偏移小，所以"以前正常"；现在 91.5%、
        // sd_card_clk 域 14 个 setup + 7 个 hold 违例，偏移放大 ⇒ KEY2 切图要等好几秒。
        //
        // 25 MHz 位周期 40 ns，把这段不受控延迟整个吸收掉；而且 `sdio_phy` 规定
        // `SAMPLE_DLY < div_r` ⇒ **只有在 DIV_FAST=2 时相位旋钮（0/1，10 ns 步进）才可用**，
        // DIV_HS=1 时旋钮失效，这是"不能停在 HS"的第二个理由。
        // 代价：单张 1280×720 BMP 加载 0.11 s → 0.22 s（音频占 25 MHz 4-bit 的 ~1.5%，
        // 可忽略）。**0.22 s 仍小于一次整图重读的代价**，所以这是净赚。
        // 何时可以改回 1：先把 `SD_CLK` 输出路径约束上、并且利用率压回 ≤85%
        // （见 doc/area-reduction-plan-2026-09-26.md），再上板实测。
        //-------------------------------------------------------------------------
        .SPEED_TARGET    (0)        // 0 = 固定 25 MHz（不要改回 1，见上方注释）
    ) u_sd_card_sdio (
        .clk(sd_card_clk), .rst(rst_sd),

        .SD_CLK(SD_CLK), .SD_CMD(SD_CMD),
        .SD_DAT0(SD_DAT0), .SD_DAT1(SD_DAT1),
        .SD_DAT2(SD_DAT2), .SD_DAT3(SD_DAT3),

        .sd_init_done(sd_init_done), .sd_init_error(sd_init_error),
        .sd_init_err_code(sd_init_err_code), .sd_high_speed(sd_high_speed),
        .sd_bus_width(sd_bus_width), .sd_is_sdhc(sd_is_sdhc),
        .sd_card_rca(sd_card_rca),

        .ch0_req(ch0_req), .ch0_sector(ch0_sector), .ch0_count(ch0_count),
        .ch0_grant(ch0_grant), .ch0_data(ch0_data),
        .ch0_data_valid(ch0_data_valid), .ch0_end(ch0_end), .ch0_error(ch0_error),

        // ---- 通道 1：WAV / 音乐读取（lba_stream1）----
        .ch1_req(ch1_req), .ch1_sector(ch1_sector), .ch1_count(ch1_count),
        .ch1_grant(ch1_grant), .ch1_data(ch1_data),
        .ch1_data_valid(ch1_data_valid), .ch1_end(ch1_end), .ch1_error(ch1_error),

        .dbg_state(dbg_sd_state), .dbg_resp_cmd(dbg_sd_resp_cmd),
        .dbg_resp_arg(dbg_sd_resp_arg), .dbg_switch_fn(dbg_sd_switch_fn),
        .dbg_clk_div(dbg_sd_clk_div)
    );

    wire sub_busy,sub_display,sub_auto,sub_display_toggle,sub_auto_toggle,sub_clear;
    wire [3:0] sub_status;
    wire sub_load_req,sub_load_ack,sub_load_rejected;
    wire [31:0] sub_load_cluster,sub_load_size,presented_file_cluster,presented_file_size;
    wire sub_dir_req,sub_dir_gnt,sub_dir_start,sub_file_start,storage_idle;
    wire [`VDIR_DBUS_W-1:0] sub_dir_dat;
    wire [31:0] sub_file_cluster,sub_file_size,sub_wav_cluster,sub_wav_size;
    wire [7:0] sub_file_data;wire sub_file_valid,sub_file_done,sub_file_ok;
    wire sub_match_done,sub_wav_match,sub_match_pending;
    wire mount_start, mount_done, mount_ok;
    wire [7:0] fat_error_code;
    wire bmp_file_start, bmp_file_data_valid, bmp_file_done, bmp_file_ok,bmp_file_abort;
    wire fat_file_busy, fat_file_abort;
    wire [31:0] bmp_file_first_cluster,bmp_file_size,bmp_file_read_limit;
    wire [7:0] stored_file_data;
    wire stored_file_data_valid,stored_file_done,stored_file_ok;
    wire [31:0] file_first_cluster,file_size,file_read_limit;
    wire [7:0] file_data;
    wire file_start,file_data_valid,file_done,file_ok;
    wire [7:0] dbg_fat_state;
    wire [31:0] dbg_dir_count;

    // 目录双消费者口（storage_service one-hot 仲裁；req/gnt，browser 优先）
    // 目录数据面捆绑（E1，位分配见 pkg/fat_dir_bus.vh）：
    //   ctl_* → fat_bmp_controller，br_* → file_browser
    wire [`VDIR_DBUS_W-1:0] ctl_dir_dat, br_dir_dat;
    wire        ctl_dir_req, ctl_dir_gnt, ctl_dir_start;
    wire        br_dir_req, br_dir_gnt, br_dir_start;

    wire        img_idle, img_ready;

    wire [8:0]  bmp_catalog_count;
    wire video_write_sector_ready;
    wire overlay_found,overlay_busy,overlay_load_done,overlay_file_start,overlay_file_abort,overlay_file_ready;
    wire [31:0] overlay_cluster,overlay_size,overlay_file_cluster,overlay_file_size,overlay_file_read_limit;
    wire [7:0] overlay_file_data;
    wire overlay_file_valid,overlay_file_done,overlay_file_ok;
    wire overlay_candidate;

    // ---- map walker / 段表 / 双 lba_stream（图 ch0 预留、音 ch1）----
    wire        map_start, map_abort, map_busy, map_done, map_ok;
    wire [31:0] map_first_cluster, map_size;
    wire        map_bank = `VBP_MAP_BANK_WAV;  // WAV 固定走音频 bank（见 pkg 宏）
    wire        map_wr_clear, map_wr_en, map_wr_last;
    wire [31:0] map_wr_lba;
    wire [31:0] map_wr_nsec;
    wire [8:0]  map_count0, map_count1;

    wire [7:0]  s0_map_addr;
    wire [31:0] s0_map_lba;
    wire [31:0] s0_map_nsec;
    wire [7:0]  s1_map_addr;
    wire [31:0] s1_map_lba;
    wire [31:0] s1_map_nsec;

    // fat_wav_controller 流口
    wire        wav_str_start, wav_str_abort, wav_str_ready;
    wire [31:0] wav_str_off, wav_str_len;
    wire [7:0]  wav_str_data;
    wire        wav_str_dv, wav_str_done, wav_str_ok, wav_str_err, wav_str_busy;
    wire [1:0]  wav_retry_used;      // lba_stream1：本轨 SD 读重发次数（观测）
    wire        wav_ring_push, wav_ring_ready, wav_ring_clear, wav_ring_flush;
    wire [31:0] wav_ring_data;
    wire wav_pause_sd;
    wire        wav_play_busy, wav_play_idle;
    wire [3:0]  wav_play_status;
    wire        br_ext_play_req;
    wire [31:0] br_ext_play_cluster, br_ext_play_size;
    wire        wav_ext_play_ack, wav_ext_play_rejected;

    // ---- 播放进度元数据 / OSD / KEY4（声明必须在首次使用之前，否则会生成
    //      隐式网，后面的显式声明就成了 vlog-2388 重名）----
    wire [31:0] wav_payload_frames;              // → audio_osd_status
    wire        wav_stream_is_seek;
    wire        wav_stream_toggle;
    wire        wav_next_req, wav_seek_fwd;      // M5(下一首)/M6(快进) 接


    wire        fft_stream_restart;
    wire        key4_press, key4_release, key4_hold;

    // ---- M5 双击下一首 / M6 长按快进 ----
    wire [31:0] wav_pos_frames;                  // 绝对位置（观测；快进算术在控制器内）
    wire        bmp_wav_entry_valid;             // ← fat_bmp_controller 的 .WAV 捕获流
    wire [31:0] bmp_wav_entry_cluster, bmp_wav_entry_size;
    wire        wpl_ext_play_req;                // ← wav_playlist 发起的"下一首"
    wire [31:0] wpl_ext_play_cluster, wpl_ext_play_size;
    wire        wav_ext_play_req;                // 两路播放请求合并（结构上互斥）
    wire [31:0] wav_ext_play_cluster, wav_ext_play_size;
    wire em_history_hold,em_ctx_req,em_ctx_we,em_ctx_ready,em_prepare,em_prepare_size;
    wire [3:0] em_ctx_addr,em_ctx_read_addr;wire [63:0] em_ctx_data,em_ctx_q;wire [31:0] em_prepare_word,wav_prepared_cluster,wav_prepared_size;
    wire em_audio_context_busy,em_restore_pause;
    wire em_play_prepared,em_history_commit;
    reg em_sub_restore;
    wire em_block,em_restart,em_force_close,em_play_req,em_play_stop,em_play_paused,em_restore_selection,em_found,em_catalog_done;
    always @(posedge clk or posedge rst)
        if(rst) em_sub_restore<=0;else em_sub_restore<=em_restore_selection;
    wire [31:0] em_play_position,em_restore_cluster,em_restore_size;
    wire [31:0] em_cluster,em_size,wav_current_cluster,wav_current_size;
    wire bmp_auto_enabled;
    reg paired_track_active,paired_stream_started,pair_repeat_req,audio_next_pending;
    reg pair_pending,background_valid,background_pause,pair_departed,background_restoring;
    wire kp_stop;
    reg audio_exit_hold;
    // Ignore late companion lookup results for the picture whose audio was
    // explicitly exited. A new picture or explicit selection enables playback.
    always @(posedge clk or posedge rst)
      if(rst) audio_exit_hold<=0;
      else if(kp_stop) audio_exit_hold<=1;
      else if(image_presented || br_ext_play_req || wpl_ext_play_req) audio_exit_hold<=0;
    reg [31:0] pair_cluster,pair_size,background_cluster,background_size,background_position;
    reg wav_stream_seen;
    wire auto_audio_next;
    // POSITION is accepted by seam_media only for the current epoch. Wait for
    // the renderer to confirm that epoch before associating it with the file.
    wire background_exists = wav_payload_frames!=0 && played_position<wav_payload_frames &&
      (!wav_play_idle || remote_playing || (audio_dispatch_valid && audio_dispatch_epoch==audio_epoch));
    wire background_confirmed = audio_dispatch_valid && audio_dispatch_epoch==audio_epoch &&
      audio_file_epoch==audio_epoch && audio_consumed_epoch==audio_epoch && !em_audio_context_busy;
    wire pair_launch=pair_pending && !audio_exit_hold && !kp_stop && !em_block && link_up && !image_presented &&
      !br_ext_play_req && !wpl_ext_play_req && !wav_next_req &&
      ((background_valid && (!background_restoring || background_confirmed || (!background_exists && wav_play_idle))) ||
       (pair_departed && !background_valid) || (!background_exists && wav_play_idle) ||
       (background_exists && background_confirmed));
    wire background_restore=(image_presented || wav_ext_play_rejected) && paired_track_active && background_valid && !kp_stop && !em_block &&
      !br_ext_play_req && !wpl_ext_play_req && !wav_next_req;
    wire pair_repeat_play=pair_repeat_req && !kp_stop && !audio_exit_hold && !image_presented && !em_block &&
      !br_ext_play_req && !wpl_ext_play_req && !wav_next_req;
    always @(posedge clk or posedge rst) begin
      if(rst) begin paired_track_active<=0;paired_stream_started<=0;pair_repeat_req<=0;audio_next_pending<=0;wav_stream_seen<=0;
        pair_pending<=0;background_valid<=0;background_pause<=0;pair_departed<=0;background_restoring<=0;pair_cluster<=0;pair_size<=0;
        background_cluster<=0;background_size<=0;background_position<=0;end
      else begin
        pair_repeat_req<=0;
        wav_stream_seen<=wav_stream_toggle;
        if(wav_stream_toggle!=wav_stream_seen) begin
          if(paired_track_active) paired_stream_started<=1;
        end
        if(sub_match_done && !sub_wav_match) begin paired_track_active<=0;background_valid<=0;pair_departed<=0;background_restoring<=0;end
        // Retire the outgoing picture's companion as soon as its replacement
        // is actually presented. A later lookup may start the new companion.
        if(image_presented && !em_block) begin
          paired_track_active<=0;paired_stream_started<=0;audio_next_pending<=0;pair_pending<=0;
          if(paired_track_active) pair_departed<=1;
        end
        if(br_ext_play_req || wpl_ext_play_req || wav_next_req) begin
          paired_track_active<=0;paired_stream_started<=0;audio_next_pending<=0;pair_pending<=0;background_valid<=0;pair_departed<=0;background_restoring<=0;
        end
        if(background_restore) background_restoring<=1;
        if(wav_ext_play_rejected && paired_track_active) begin paired_track_active<=0;end
        if(sub_match_done && sub_wav_match && !audio_exit_hold && !kp_stop && !br_ext_play_req && !wpl_ext_play_req && !em_block) begin
          pair_pending<=1;pair_cluster<=sub_wav_cluster;pair_size<=sub_wav_size;
        end
        if(pair_launch) begin
          pair_pending<=0;pair_departed<=0;background_restoring<=0;
          paired_track_active<=1;paired_stream_started<=0;
          if(!background_valid && !pair_departed && background_exists) begin
            background_valid<=1;background_cluster<=wav_current_cluster;background_size<=wav_current_size;
            background_position<=played_position;background_pause<=wav_pause_sd;
          end
          if(background_valid && background_restoring) begin
            if(!background_exists) background_valid<=0;
            else begin background_position<=played_position;background_pause<=wav_pause_sd;end
          end
        end
        if(pair_repeat_play) begin paired_track_active<=1;paired_stream_started<=0;end
        if(paired_track_active && paired_stream_started &&
           wav_payload_frames!=0 && played_position>=wav_payload_frames-1'b1 &&
           !remote_playing && !wav_pause_sd && !em_block && !image_presented &&
           !br_ext_play_req && !wpl_ext_play_req && !wav_next_req) begin
          paired_stream_started<=0;
          if(bmp_auto_enabled) audio_next_pending<=1;
          else pair_repeat_req<=1;
        end
        if(auto_audio_next) audio_next_pending<=0;
        if(kp_stop) begin
          paired_track_active<=0;paired_stream_started<=0;pair_repeat_req<=0;audio_next_pending<=0;
          pair_pending<=0;background_valid<=0;pair_departed<=0;background_restoring<=0;
        end
      end
    end
    wire [31:0] normal_play_cluster=br_ext_play_req ? br_ext_play_cluster:wpl_ext_play_cluster;
    wire [31:0] normal_play_size=br_ext_play_req ? br_ext_play_size:wpl_ext_play_size;
    assign wav_ext_play_req = em_block ? em_play_req:(!kp_stop && (br_ext_play_req | wpl_ext_play_req | pair_launch | pair_repeat_play | background_restore));
    // cluster/size 按请求方二选一（两路结构互斥，不会同拍）
    // Restores use the WAV controller's prepared registers directly; their
    // metadata never needs the external request mux. Only emergency opens
    // consume external metadata while normal operations are blocked.
    assign wav_ext_play_cluster=em_block ? em_cluster:(br_ext_play_req ? br_ext_play_cluster:
      wpl_ext_play_req ? wpl_ext_play_cluster:background_restore ? background_cluster:pair_launch ? pair_cluster:
      pair_repeat_play ? wav_current_cluster:wpl_ext_play_cluster);
    assign wav_ext_play_size=em_block ? em_size:(br_ext_play_req ? br_ext_play_size:
      wpl_ext_play_req ? wpl_ext_play_size:background_restore ? background_size:pair_launch ? pair_size:
      pair_repeat_play ? wav_current_size:wpl_ext_play_size);
    emergency_media_controller #(.CLK_HZ(`VBP_SD_CLK_HZ)) u_emergency(
      .clk(clk),.rst(rst),.link_up(link_up),.session_reset(subtitle_session_reset),
      .request_valid(emergency_request_valid),.request_mode(emergency_request_mode),
      .request_revision(emergency_request_revision),.request_snapshot(emergency_request_snapshot),
      .emergency_found(em_found),.catalog_done(em_catalog_done),.emergency_cluster(em_cluster),.emergency_size(em_size),
      .track_stream_toggle(wav_stream_toggle),.track_cluster(wav_current_cluster),.track_size(wav_current_size),.audio_epoch(audio_epoch),.audio_file_epoch(audio_file_epoch),.audio_consumed_epoch(audio_consumed_epoch),.audio_dispatch_epoch(audio_dispatch_epoch),.audio_dispatch_valid(audio_dispatch_valid),
      .total_frames(wav_payload_frames),.played_position(played_position),
      .track_ack(wav_ext_play_ack),.track_rejected(wav_ext_play_rejected),.track_idle(wav_play_idle),.track_status(wav_play_status),
      .normal_pause(wav_pause_sd),.image_presented(image_presented),.image_id(presented_image_id),
      .image_cluster(presented_file_cluster),.image_size(presented_file_size),.image_idle(img_idle),
      .ctx_req(em_ctx_req),.ctx_we(em_ctx_we),.ctx_addr(em_ctx_addr),.ctx_read_addr(em_ctx_read_addr),.ctx_data(em_ctx_data),.ctx_ready(em_ctx_ready),.ctx_q(em_ctx_q),
      .prepare_restore(em_prepare),.prepare_size(em_prepare_size),.prepare_word(em_prepare_word),.prepared_cluster(wav_prepared_cluster),.prepared_size(wav_prepared_size),
      .audio_context_busy(em_audio_context_busy),.restore_pause(em_restore_pause),.history_hold(em_history_hold),.block_normal(em_block),.restart_normal(em_restart),.force_close(em_force_close),.play_req(em_play_req),.play_stop(em_play_stop),
      .history_commit(em_history_commit),.play_prepared(em_play_prepared),.play_cluster(),.play_size(),.play_position(em_play_position),.play_paused(em_play_paused),
      .restore_selection(em_restore_selection),.restore_cluster(em_restore_cluster),.restore_size(em_restore_size),
      .reply_valid(emergency_reply_valid),.reply_ready(emergency_reply_ready),.reply_revision(emergency_reply_revision),
      .reply_epoch(),.reply_status(emergency_reply_status));

    sd_subtitle_controller u_subtitle(.clk(clk),.rst(rst),.link_up(link_up),.session_reset(subtitle_session_reset),
      .storage_idle(storage_idle && img_idle && !br_dir_req),
      .display_toggle(sub_display_toggle),.auto_toggle(sub_auto_toggle),.clear_manual(sub_clear),
      .match_done(sub_match_done),.wav_match(sub_wav_match),.match_pending(sub_match_pending),.wav_cluster(sub_wav_cluster),.wav_size(sub_wav_size),
      .display_enable(sub_display),.auto_enable(sub_auto),.status(sub_status),.busy(sub_busy),
      .load_req(sub_load_req),.load_cluster(sub_load_cluster),.load_size(sub_load_size),.load_ack(sub_load_ack),.load_rejected(sub_load_rejected),
      // Publish only stable, committed descriptors; restore writes settle first.
      .image_presented(em_history_commit || em_sub_restore),.image_suppress_audio(em_sub_restore),.image_cluster(presented_file_cluster),.image_size(presented_file_size),.image_id(em_sub_restore ? emergency_request_snapshot[127:96]:presented_image_id),
      .dir_req(sub_dir_req),.dir_gnt(sub_dir_gnt),.dir_start(sub_dir_start),.dir_dat(sub_dir_dat),
      .file_start(sub_file_start),.file_cluster(sub_file_cluster),.file_size(sub_file_size),
      .file_data(sub_file_data),.file_valid(sub_file_valid),.file_done(sub_file_done),.file_ok(sub_file_ok),
      .message_valid(subtitle_valid),.message_ready(subtitle_ready),.message_revision(subtitle_revision),
      .word_valid(subtitle_word_valid),.word_ready(subtitle_word_ready),.word_data(subtitle_word),
      .applied(subtitle_applied),.applied_revision(subtitle_applied_revision),.applied_result(subtitle_applied_result));
    glue_storage #(.FILE_MAX_BURST(4)) u_glue_storage (
        .clk(sd_card_clk), .rst(rst_sd),
        .txt_dir_req(sub_dir_req),.txt_dir_gnt(sub_dir_gnt),.txt_dir_start(sub_dir_start),.txt_dir_dat(sub_dir_dat),
        .txt_file_start(sub_file_start),.txt_file_cluster(sub_file_cluster),.txt_file_size(sub_file_size),
        .txt_file_data(sub_file_data),.txt_file_valid(sub_file_valid),.txt_file_done(sub_file_done),.txt_file_ok(sub_file_ok),.operation_idle(storage_idle),
        .blk_req(ch0_req), .blk_lba(ch0_sector), .blk_count(ch0_count),
        .blk_grant(ch0_grant), .blk_data(ch0_data), .blk_data_valid(ch0_data_valid),
        .blk_end(ch0_end), .blk_error(ch0_error),
        .mount_start(mount_start), .mount_done(mount_done), .mount_ok(mount_ok),
        .fat_error_code(fat_error_code), .sd_rd_err_seen(sd_rd_err_seen),
        .file_start(file_start), .file_first_cluster(file_first_cluster),
        .file_size(file_size), .file_read_limit(file_read_limit),
        .file_abort(fat_file_abort), .file_data(stored_file_data),
        .file_data_valid(stored_file_data_valid), .file_done(stored_file_done), .file_ok(stored_file_ok),
        .file_busy(fat_file_busy),
        .map_start(map_start), .map_first_cluster(map_first_cluster),
        .map_size(map_size), .map_abort(map_abort), .map_bank(map_bank),
        .map_busy(map_busy), .map_done(map_done), .map_ok(map_ok),
        .map_wr_clear(map_wr_clear), .map_wr_en(map_wr_en),
        .map_wr_lba(map_wr_lba), .map_wr_nsec(map_wr_nsec), .map_wr_last(map_wr_last),
        .write_bp(video_write_sector_ready),
        .ctl_dir_req(ctl_dir_req), .ctl_dir_gnt(ctl_dir_gnt),
        .ctl_dir_start(ctl_dir_start), .ctl_dir_dat(ctl_dir_dat),
        .br_dir_req(br_dir_req), .br_dir_gnt(br_dir_gnt),
        .br_dir_start(br_dir_start), .br_dir_dat(br_dir_dat),
        .dbg_fat_state(dbg_fat_state),
        .dbg_dir_count(dbg_dir_count)
    );

    fat_chain_map u_fat_chain_map (
        .clk(sd_card_clk), .rst(rst_sd),
        .wr_bank(map_bank), .wr_clear(map_wr_clear), .wr_en(map_wr_en),
        .wr_lba(map_wr_lba), .wr_nsec(map_wr_nsec), .wr_count(), .wr_overflow(),
        .rd_bank(`VBP_MAP_BANK_IMG), .rd_addr(s0_map_addr),
        .rd_lba(s0_map_lba), .rd_nsec(s0_map_nsec),
        .rd_count_sel(9'd0), .count0(map_count0), .count1(map_count1),
        .rd2_bank(`VBP_MAP_BANK_WAV), .rd2_addr(s1_map_addr),
        .rd2_lba(s1_map_lba), .rd2_nsec(s1_map_nsec)
    );

    // stream0：图像 map+lba 预留（本相位图像仍走 legacy file_* on ch0，stream0 空闲）
    lba_stream #(.CHANNEL(0), .MAX_BURST(64)) u_lba_stream0 (
        .clk(sd_card_clk), .rst(rst_sd),
        .map_rd_addr(s0_map_addr), .map_rd_lba(s0_map_lba), .map_rd_nsec(s0_map_nsec),
        .map_count(map_count0),
        .str_start(1'b0), .str_file_off(32'd0), .str_len(32'd0),
        .str_abort(1'b0), .str_ready(1'b1),
        .str_data(), .str_data_valid(), .str_done(), .str_ok(), .str_error(),
        .str_busy(),
        .str_retry_used(),
        .blk_req(), .blk_lba(), .blk_count(),
        .blk_grant(1'b0), .blk_data(8'd0), .blk_data_valid(1'b0),
        .blk_end(1'b0), .blk_error(1'b0)
    );

    // A mono 16-bit sector produces 256 packed L/R frames. The media FIFO
    // grants 260 frames, so one non-preemptible sector is the safe maximum
    // for both mono and stereo (two mono sectors would produce 512 frames).
    lba_stream #(.CHANNEL(1), .MAX_BURST(1)) u_lba_stream1 (
        .clk(sd_card_clk), .rst(rst_sd),
        .map_rd_addr(s1_map_addr), .map_rd_lba(s1_map_lba), .map_rd_nsec(s1_map_nsec),
        .map_count(map_count1),
        .str_start(wav_str_start), .str_file_off(wav_str_off), .str_len(wav_str_len),
        .str_abort(wav_str_abort), .str_ready(wav_str_ready),
        .str_data(wav_str_data), .str_data_valid(wav_str_dv),
        .str_done(wav_str_done), .str_ok(wav_str_ok), .str_error(wav_str_err),
        .str_busy(wav_str_busy),
        .str_retry_used(wav_retry_used),
        .blk_req(ch1_req), .blk_lba(ch1_sector), .blk_count(ch1_count),
        .blk_grant(ch1_grant), .blk_data(ch1_data), .blk_data_valid(ch1_data_valid),
        .blk_end(ch1_end), .blk_error(ch1_error)
    );

    fat_wav_controller #(.EXTERNAL_POSITION(1)) u_fat_wav_controller (
        .clk(sd_card_clk), .rst(rst_sd),
        // ★ 必须接合并信号：wav_playlist 的"下一首"也走这里。
        //   接成 br_ext_play_req 的话双击下一首的请求发进虚空（上板实测踩过）。
        .ext_play_req(wav_ext_play_req),
        .ext_play_cluster(wav_ext_play_cluster),
        .ext_play_size(wav_ext_play_size),
        .ext_play_ack(wav_ext_play_ack),
        .ext_play_rejected(wav_ext_play_rejected),
        .use_prepared(em_play_prepared),.defer_new_file(em_audio_context_busy),.play_stop(kp_stop || em_play_stop || (image_presented && paired_track_active && !em_block)),.start_at_position(em_block || background_restore),.initial_position(em_block ? em_play_position:background_position),
        .current_cluster(wav_current_cluster),.current_size(wav_current_size),
        .prepare_restore(em_prepare),.prepare_size(em_prepare_size),.prepare_word(em_prepare_word),.prepared_cluster(wav_prepared_cluster),.prepared_size(wav_prepared_size),
        .play_busy(wav_play_busy), .play_idle(wav_play_idle),
        .play_status(wav_play_status),
        .map_start(map_start), .map_first_cluster(map_first_cluster),
        .map_size(map_size), .map_abort(map_abort),
        .map_busy(map_busy), .map_done(map_done), .map_ok(map_ok),
        .str_start(wav_str_start), .str_file_off(wav_str_off), .str_len(wav_str_len),
        .str_abort(wav_str_abort), .str_ready(wav_str_ready),
        .str_data(wav_str_data), .str_data_valid(wav_str_dv),
        .str_done(wav_str_done), .str_ok(wav_str_ok), .str_error(wav_str_err),
        .str_busy(wav_str_busy),
        .ring_push(wav_ring_push), .ring_data(wav_ring_data), .ring_ready(wav_ring_ready),
        .ring_clear(wav_ring_clear), .ring_flush(wav_ring_flush),
        // ---- 播放进度元数据 → audio_osd_status（准静态 + toggle 跨域握手）----
        .o_payload_frames(wav_payload_frames),
        .o_stream_is_seek(wav_stream_is_seek),
        .o_stream_toggle (wav_stream_toggle),
        // ---- 长按 KEY4 = 快进 5 秒（M6）----
        .ext_seek_fwd(seek_execute), .i_played_frames(played_position),
        .absolute_seek(resume_request), .absolute_target(played_position), .o_stream_base(pcm_base),
        .o_pos_frames(wav_pos_frames)
    );

    //--------------------------------------------------------------------------
    // 文件浏览器（KEY3/KEY2/KEY4 + 文本窗口渲染器）
    //   窗口打开期间 KEY2 不再去切图（喂给控制器的 key_next 拉高 = 未按下），
    //   否则一次按键既移光标又切背景图。
    //--------------------------------------------------------------------------
    wire        br_ui_active, br_ui_commit, br_ui_wr_en;
    assign auto_audio_next=audio_next_pending && !kp_stop && !br_ui_active && !em_block;
    wire [8:0]  br_ui_wr_addr;
    wire [7:0]  br_ui_wr_data;
    wire [3:0]  br_cursor_row;
    wire        br_cursor_en;
    wire        br_ext_load_req;
    wire [31:0] br_ext_cluster, br_ext_size;
    wire        br_auto_toggle;
    wire        ctl_ext_load_ack, ctl_ext_load_rejected;
    wire [6:0]  dbg_br_ent_cnt;
    wire [5:0]  dbg_br_cursor;

    wire legacy_next_image;

    wire kp_open,kp_back,kp_up,kp_down,kp_left,kp_right,kp_confirm,kp_prev,kp_next,kp_auto,kp_pause,kp_track;
    wire [3:0] kp_page;wire kp_nav;
    wire [5:0] auto_interval_steps;
    wire auto_interval_changed;
    wire kp_volume_up,kp_volume_down,menu_volume_up,menu_volume_down;
    volume_controller u_volume(.clk(clk),.rst(rst),
        .increase(kp_volume_up || menu_volume_up),.decrease(kp_volume_down || menu_volume_down),
        .shortcut(kp_volume_up || kp_volume_down),.level(volume_level),
        .changed(volume_changed),.hint(volume_hint),.revision(volume_revision));
    keypad_action_router #(.CLK_HZ(`VBP_SD_CLK_HZ)) u_keypad_router(
        .clk(sd_card_clk),.rst(rst_sd),.cancel(keypad_cancel || em_block),.event_valid(keypad_valid && !em_block),.event_data(keypad_data),
        .ui_active(br_ui_active),.text_osd_page(text_osd_page),.ui_page(kp_page),.navigable(kp_nav),.playing(~wav_play_idle || remote_playing),.new_track(wav_ext_play_req),
        .open_menu(kp_open),.back(kp_back),.up(kp_up),.down(kp_down),.left(kp_left),.right(kp_right),.confirm(kp_confirm),
        .volume_up(kp_volume_up),.volume_down(kp_volume_down),.stop_track(kp_stop),.prev_image(kp_prev),.next_image(kp_next),.auto_toggle(kp_auto),.pause_toggle(kp_pause),.next_track(kp_track));
    file_browser #(.CLK_FREQ_HZ(`VBP_SD_CLK_HZ)) u_file_browser (
        .clk(sd_card_clk), .rst(rst_sd),
        .force_close(em_force_close),.input_block(em_block),
        .volume_level(volume_level),.volume_increase(menu_volume_up),.volume_decrease(menu_volume_down),
        .text_osd_page(text_osd_page),.action_open(kp_open),.action_back(kp_back),.action_up(kp_up),.action_down(kp_down),.action_left(kp_left),.action_right(kp_right),.action_confirm(kp_confirm),.ui_page(kp_page),.ui_navigable(kp_nav),
        .ev_ok_press(key4_press),.ev_ok_release(key4_release),.ev_ok_hold(key4_hold),.legacy_next_pulse(legacy_next_image),
        .key_open(KEY3), .key_sel(KEY2), .key_ok(1'b1),
        .contrast_level(contrast_level),.saturation_level(saturation_level),.brightness_mode(brightness_mode),.brightness_level(brightness_level),
        .transition_mode(transition_mode),
        .auto_interval_steps(auto_interval_steps),
        .auto_interval_changed(auto_interval_changed),
        .subtitle_display(sub_display),.subtitle_auto(sub_auto),.subtitle_status(sub_status),
        .subtitle_display_toggle(sub_display_toggle),.subtitle_auto_toggle(sub_auto_toggle),.subtitle_clear(sub_clear),
        .ext_txt_req(sub_load_req),.ext_txt_cluster(sub_load_cluster),.ext_txt_size(sub_load_size),.ext_txt_ack(sub_load_ack),.ext_txt_rejected(sub_load_rejected),
        .img_idle(img_idle && !sub_busy && !overlay_busy), .img_ready(img_ready), .fat_busy(fat_file_busy || sub_busy || overlay_busy),
        .dir_req(br_dir_req), .dir_gnt(br_dir_gnt), .dir_start(br_dir_start),
        .dir_dat(br_dir_dat),
        .ui_active(br_ui_active), .ui_commit_toggle(br_ui_commit),
        .cursor_row(br_cursor_row), .cursor_en(br_cursor_en),
        .ui_wr_en(br_ui_wr_en), .ui_wr_addr(br_ui_wr_addr), .ui_wr_data(br_ui_wr_data),
        .ext_load_req(br_ext_load_req), .ext_load_cluster(br_ext_cluster),
        .ext_load_size(br_ext_size),
        .ext_load_ack(ctl_ext_load_ack), .ext_load_rejected(ctl_ext_load_rejected),
        .ext_play_req(br_ext_play_req), .ext_play_cluster(br_ext_play_cluster),
        .ext_play_size(br_ext_play_size),
        .ext_play_ack(wav_ext_play_ack), .ext_play_rejected(wav_ext_play_rejected),
        .auto_toggle_pulse(br_auto_toggle),
        .dbg_browser_state(DBG_UI_STATE), .dbg_entry_count(dbg_br_ent_cnt),
        .dbg_cursor(dbg_br_cursor)
    );

    wire bmp_file_burst_ready,bmp_load_success,bmp_load_failed;
    fat_bmp_controller #(.CLK_FREQ_HZ(`VBP_SD_CLK_HZ)) u_fat_bmp_controller (
        .clk(sd_card_clk), .rst(rst_sd),
        .ctx_req(em_ctx_req),.ctx_we(em_ctx_we),.ctx_addr(em_ctx_addr),.ctx_read_addr(em_ctx_read_addr),.ctx_data(em_ctx_data),.ctx_ready(em_ctx_ready),.ctx_q(em_ctx_q),
        .emergency_hold(em_block),.restore_selection(em_restore_selection),.restore_cluster(em_restore_cluster),.restore_size(em_restore_size),
        .emergency_found(em_found),.catalog_done(em_catalog_done),.emergency_cluster(em_cluster),.emergency_size(em_size),
        .storage_hold(sub_busy || overlay_busy || overlay_candidate || em_block || em_history_hold),.presented_file_cluster(presented_file_cluster),.presented_file_size(presented_file_size),
        // 浏览器窗口打开时 key_next 被拉高（未按下），避免一次 KEY2 既移光标又切图
        .action_prev(kp_prev),.action_next(kp_next || legacy_next_image || auto_audio_next),
        .replay_request(image_replay || em_restart), .key_next(1'b1), .key_auto(1'b1),
        // 文件浏览器接入
        .ext_load_req(br_ext_load_req), .ext_load_cluster(br_ext_cluster),
        .ext_load_size(br_ext_size), .ext_load_ack(ctl_ext_load_ack),
        .ext_load_rejected(ctl_ext_load_rejected),
        .auto_toggle(br_auto_toggle || kp_auto), .ui_active(br_ui_active),
        .auto_interval_steps(auto_interval_steps),
        .auto_interval_changed(auto_interval_changed),
        .auto_audio_active(paired_track_active),
        .auto_timer_hold(sub_match_pending || overlay_busy || overlay_candidate || em_block || em_history_hold),
        .bmp_width(`VBP_BMP_W), .bmp_height(`VBP_BMP_H),
        .scale_mode(2'd0),.write_ready(image_pixel_ready),.write_error(pack_alignment_error || pack_overflow_error),.file_burst_ready(bmp_file_burst_ready),
        .load_success(bmp_load_success),.load_failed(bmp_load_failed),
        .img_idle(img_idle), .img_ready(img_ready),.auto_enabled(bmp_auto_enabled),
        .display_valid(display_valid), .state_code(state_code),
        // sd_init_done is a LOCAL fact: the card either initialised or it did
        // not.  It must NOT be gated on link_up.
        //
        // This was `sd_init_done && link_up` (introduced in the initial split
        // commit, "初版分离，暂未上机验证").  It fused two independent facts and
        // stalled the whole storage chain whenever the peer was absent:
        //   link_up low -> fat_bmp_controller stays in C_WAIT_SD
        //   -> FAT32 never mounts -> no catalog, no image data -> render shows
        //   WAIT DATA forever.  That is exactly the "media reads no SD data"
        //   symptom, and it is a DESIGN cause, not an SD hardware fault.
        //
        // Backpressure is already expressed where it belongs, on the data path:
        // seam_media.v gates image_burst_ready / pcm_burst_ready on link_up, so
        // a missing peer throttles the <=4-sector SD read burst without ever
        // preventing the card from being initialised or the FS from mounting.
        .sd_init_done(sd_init_done),
        .sd_init_error(sd_init_error),
        .sd_init_err_code(sd_init_err_code),
        .diag_code(diag_code),
        .mount_start(mount_start), .mount_done(mount_done), .mount_ok(mount_ok),
        .fat_error_code(fat_error_code),
        .dir_req(ctl_dir_req), .dir_gnt(ctl_dir_gnt), .dir_start(ctl_dir_start),
        .dir_dat(ctl_dir_dat), .file_start(bmp_file_start),
        .file_first_cluster(bmp_file_first_cluster), .file_size(bmp_file_size),
        .file_read_limit(bmp_file_read_limit), .file_data(overlay_busy ? 8'd0:stored_file_data),
        .file_data_valid(!overlay_busy && stored_file_data_valid), .file_done(!overlay_busy && stored_file_done), .file_ok(stored_file_ok),
        .file_busy(fat_file_busy), .file_abort(bmp_file_abort),
        .write_finish_toggle(frame_write_toggle_mem),
        .write_buf_idx(write_buf_idx), .disp_buf_idx(disp_buf_idx),
        .write_req(sd_write_req), .write_req_ack(sd_write_req_ack),
        .write_en(sd_pixel_valid), .write_data(sd_pixel_rgb),
        .catalog_count(bmp_catalog_count),
        .overlay_found(overlay_found),.overlay_cluster(overlay_cluster),.overlay_size(overlay_size),
        // ---- .WAV 捕获流 → wav_playlist（开机枚举时顺手转发）----
        .o_wav_entry_valid  (bmp_wav_entry_valid),
        .o_wav_entry_cluster(bmp_wav_entry_cluster),
        .o_wav_entry_size   (bmp_wav_entry_size)
    );

    sd_overlay_controller u_sd_overlay_controller(
        .clk(sd_card_clk),.rst(rst_sd),.link_up(link_up),.session_reset(subtitle_session_reset),
        .sd_ready(sd_init_done && !sd_init_error),.catalog_done(em_catalog_done),.overlay_found(overlay_found),
        .render_image_transport_idle(render_image_transport_idle),
        .overlay_cluster(overlay_cluster),.overlay_size(overlay_size),.image_idle(img_idle),.image_valid(display_valid),
        .storage_idle(storage_idle),.subtitle_busy(sub_busy),.emergency_hold(em_block),.ui_active(br_ui_active),
        .file_start(overlay_file_start),.file_cluster(overlay_file_cluster),.file_size(overlay_file_size),
        .file_read_limit(overlay_file_read_limit),.file_abort(overlay_file_abort),.file_busy(fat_file_busy),
        .file_data(overlay_file_data),.file_valid(overlay_file_valid),.file_done(overlay_file_done),.file_ok(overlay_file_ok),
        .file_ready(overlay_file_ready),.begin_req(overlay_begin_req),.begin_ack(overlay_begin_ack),
        .begin_ready(overlay_begin_ready),.begin_failed(overlay_failed),.begin_object(overlay_begin_object),
        .abort_req(overlay_abort_req),.word_valid(overlay_word_valid),.word_data(overlay_word),
        .word_ready(overlay_word_ready),.source_ok(overlay_source_ok),.source_failed(overlay_source_failed),
        .applied(overlay_applied),.busy(overlay_busy),.load_done(overlay_load_done));

    assign overlay_candidate=sd_init_done && link_up && em_catalog_done && overlay_found && img_idle && display_valid && render_image_transport_idle &&
        storage_idle && !sub_busy && !em_block && !br_ui_active && !overlay_load_done;
    assign file_start=overlay_busy ? overlay_file_start:bmp_file_start;
    assign file_first_cluster=overlay_busy ? overlay_file_cluster:bmp_file_first_cluster;
    assign file_size=overlay_busy ? overlay_file_size:bmp_file_size;
    assign file_read_limit=overlay_busy ? overlay_file_read_limit:bmp_file_read_limit;
    // The shared file service produces these signals. Demultiplex its return
    // path to the current reader, just as the request path above is selected.
    assign overlay_file_data=stored_file_data;
    assign overlay_file_valid=overlay_busy && stored_file_data_valid;
    assign overlay_file_done=overlay_busy && stored_file_done;
    assign overlay_file_ok=stored_file_ok;
    assign file_data=stored_file_data;
    assign file_data_valid=stored_file_data_valid;
    assign file_done=stored_file_done;
    assign file_ok=stored_file_ok;
    // Session cancellation drops overlay_busy and pulses abort together. The
    // abort must still reach storage after ownership has been released.
    assign fat_file_abort=overlay_file_abort || (!overlay_busy && bmp_file_abort);

    rgb888_word_packer #(
        .FRAME_PIXELS(FRAME_PIXELS)
    ) u_rgb888_word_packer (
        .clk(sd_card_clk), .rst(rst_sd || bmp_load_failed),
        .frame_start(sd_write_req && sd_write_req_ack),
        .pixel_valid(sd_pixel_valid), .pixel_rgb(sd_pixel_rgb),
        .word_valid(packed_write_en), .word_data(packed_write_data),
        .alignment_error(pack_alignment_error),
        .overflow_error(pack_overflow_error)
    );

    key_debounce #(
        .CLK_FREQ_HZ (`VBP_SD_CLK_HZ),
        .DEBOUNCE_MS (50),
        .HOLD_MS     (2000)
    ) u_key4_debounce (
        .clk           (sd_card_clk),
        .rst           (rst_sd),
        .button_in     (KEY4),
        .press_pulse   (key4_press),
        .release_pulse (key4_release),
        .hold_pulse    (key4_hold)
    );

    audio_transport #(
        .CLK_FREQ_HZ (`VBP_SD_CLK_HZ),
        .DBL_WIN_MS  (300)
    ) u_audio_transport (
        .clk         (sd_card_clk),
        .rst         (rst_sd),
        .action_pause(kp_pause),.action_next(kp_track),
        .i_playing   (~wav_play_idle || remote_playing),
        .i_ui_active (br_ui_active || em_block || kp_stop),.i_restore_pause(em_restore_pause || background_restore),.i_restore_value(em_block ? em_play_paused:background_pause),
        .i_new_track ((wav_ext_play_req && !em_block) || kp_stop),
        .ev_press    (key4_press),
        .ev_release  (key4_release),
        .ev_hold     (key4_hold),
        .o_pause     (wav_pause_sd),
        .o_next_req  (wav_next_req),
        .o_seek_fwd  (wav_seek_fwd)
    );

    // 双击 KEY4 → 下一首：曲目表来自开机枚举的 .WAV 捕获流，游标用 cluster 反查。
    // 浏览器打开时让位（结构上与浏览器的"确认选中"互斥）。
    // WAV_MAX=64：表已推断成 BRAM（1 块），地址位宽与深度严格一致
    // （详见 wav_playlist.v 头部资源红线）。曾因 7 位地址访问 16 条表被
    // TD 拒绝 BRAM 推断摊成寄存器堆，96.84% 利用率 ⇒ 布线拥塞 ⇒ 黑屏。
    wav_playlist #(
        .WAV_MAX ( 64 )
    ) u_wav_playlist (
        .clk               (sd_card_clk),
        .rst               (rst_sd),
        .i_entry_valid     (bmp_wav_entry_valid),
        .i_entry_cluster   (bmp_wav_entry_cluster),
        .i_entry_size      (bmp_wav_entry_size),
        .i_restore_req(em_play_prepared),.i_restore_cluster(wav_prepared_cluster),
        .i_play_req        ((br_ext_play_req || sub_wav_match) && !em_block),
        .i_play_cluster    (br_ext_play_req ? br_ext_play_cluster:sub_wav_cluster),
        .i_next_req        (wav_next_req),
        .i_ui_active       (br_ui_active || em_block),
        .o_ext_play_req    (wpl_ext_play_req),
        .o_ext_play_cluster(wpl_ext_play_cluster),
        .o_ext_play_size   (wpl_ext_play_size)
    );

    assign DBG_SD_INIT_DONE  = sd_init_done;
    assign DBG_BMP_LOAD_DONE = display_valid;
    assign DBG_SD_INIT_ERROR = sd_init_error;
    assign DBG_SD_HIGH_SPEED = sd_high_speed;
    assign DBG_SD_BUS4       = (sd_bus_width == 2'd1);
    assign DBG_SD_RD_ERROR   = sd_rd_err_seen;
    // 初始化失败时 diag_code 已直接透传 sdio_core 原始错误码 1~8；
    // 这样 ChipWatcher 与屏上的数字一致，不再把多个失败原因压成 ERROR 0。
    assign DBG_SD_ERR_CODE   = diag_code;
    assign DBG_SD_STATE      = dbg_sd_state;
    assign DBG_UI_ACTIVE     = br_ui_active;

    // WAV 观察总线：让"偶发 SD 读错"在板上自证，不用再猜
    //   retry_used>0 && !err_sticky → 出过错但被重试救回来了（听不出来的一次卡顿）
    //   err_sticky=1               → 重试用尽仍失败，看 play_status 分辨原因是 map 还是 str
    reg wav_err_sticky;
    always @(posedge sd_card_clk or posedge rst_sd) begin
        if (rst_sd)
            wav_err_sticky <= 1'b0;
        else if (wav_ext_play_req)
            wav_err_sticky <= 1'b0;          // 新选曲/下一首清零
        else if (wav_str_err)
            wav_err_sticky <= 1'b1;          // 流内出错（含 SD 读失败重试用尽）
    end
    assign DBG_WAV_STATUS    = {wav_play_idle, wav_err_sticky,
                                wav_retry_used, wav_play_status};

    // Board KEY2/KEY4 debounce is shared with UI/audio instead of duplicated.
    assign sd_write_req_ack=image_ack;
    // A bounded header probe emits no pixels and precedes image_req/IMG_READY.
    // Requiring remote image credit here would deadlock the first BMP probe.
    // Full-file reads use local raw-byte FIFO credit; scaled output has separate credit.
    assign video_write_sector_ready=overlay_busy ? overlay_burst_ready:((file_read_limit!=0) || bmp_file_burst_ready);
    assign wav_ring_ready=pcm_burst_ready;
    assign image_req=sd_write_req;
    assign image_word_valid=packed_write_en;assign image_word=packed_write_data;
    assign image_source_ok=bmp_load_success;
    assign image_source_failed=bmp_load_failed;
    // A source rejection terminates the remote epoch as well as the local
    // reader; otherwise paused/prefetched PCM could survive an SD read error.
    assign pcm_push=wav_ring_push;assign pcm=wav_ring_data;
    assign pcm_clear=wav_ring_clear || wav_ext_play_rejected;
    assign pcm_eof=wav_ring_flush;assign pcm_total=wav_payload_frames;assign pcm_stream_toggle=wav_stream_toggle;
    assign paused=em_block ? em_play_paused:wav_pause_sd;assign seek_request=wav_seek_fwd;
    assign ui_wr_en=br_ui_wr_en;assign ui_wr_addr=br_ui_wr_addr;assign ui_wr_data=br_ui_wr_data;
    assign ui_active=br_ui_active;assign ui_cursor_en=br_cursor_en;assign ui_cursor_row=br_cursor_row;
    assign ui_page=kp_page;
    assign ui_commit_toggle=br_ui_commit;assign diag=diag_code;
endmodule
