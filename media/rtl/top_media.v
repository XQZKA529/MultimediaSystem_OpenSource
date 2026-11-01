`include "pkg/board_link.vh"
`include "pkg/video_bmp_params.vh"
module top_media(
    input wire sys_clk,sys_rst_n,input wire KEY2,KEY3,KEY4,
    output wire SD_CLK,inout wire SD_CMD,input wire SD_DAT0,SD_DAT1,SD_DAT2,SD_DAT3,
    output wire LED1,
    input wire rgmii_rxc,rgmii_rx_ctl,input wire [3:0] rgmii_rxd,
    output wire rgmii_txc,rgmii_tx_ctl,output wire [3:0] rgmii_txd,output wire mdc,inout wire mdio);

    wire clk,mem_clk,mem_sft,tx_clk_90,pll_lock,board_rst,rst;
    wire rx_clk,phy_ok;wire [7:0] mac_tx_data,mac_rx_data;wire mac_tx_valid,mac_tx_ack,mac_rx_valid,mac_rx_good,mac_rx_bad;
    wire link_up,session_reset;
    wire tx_meta_valid,tx_meta_ready,tx_valid,tx_ready,tx_last;
    wire [7:0] tx_channel,tx_opcode;wire [31:0] tx_object,tx_offset,tx_data;wire [15:0] tx_length;
    wire rx_meta_valid,rx_meta_ready,rx_valid,rx_ready,rx_last,rx_required;
    wire [7:0] rx_channel,rx_opcode;wire [31:0] rx_object,rx_offset,rx_data;wire [15:0] rx_length;
    board_sys_pll  u_sys_pll(
        .refclk(sys_clk),
        .reset(1'b0),
        .extlock(pll_lock),
        .clk0_out(clk),
        .clk1_out(mem_clk),
        .clk2_out(mem_sft),
        .clk3_out(tx_clk_90)
    );
    board_reset  u_reset_hold(
        .clk(sys_clk),
        .rst_n(sys_rst_n),
        .locked(pll_lock),
        .rst(board_rst)
    );
    reset_sync  u_bus_reset(
        .clk(clk),
        .rst_in(board_rst),
        .rst_out(rst)
    );
    db_ethernet #(.LOCAL_MAC(`DB_MAC_MEDIA)) u_ethernet(
        .rst(rst),
        .tx_clk_90(tx_clk_90),
        .rx_clk(rx_clk),
        .phy_ok(phy_ok),
        .rgmii_rxc(rgmii_rxc),
        .rgmii_rx_ctl(rgmii_rx_ctl),
        .rgmii_rxd(rgmii_rxd),
        .rgmii_txc(rgmii_txc),
        .rgmii_tx_ctl(rgmii_tx_ctl),
        .rgmii_txd(rgmii_txd),
        .mdc(mdc),
        .mdio(mdio),
        .tx_clk(mem_clk),
        .bus_clk(clk),
        .tx_data(mac_tx_data),
        .tx_valid(mac_tx_valid),
        .tx_ack(mac_tx_ack),
        .rx_data(mac_rx_data),
        .rx_valid(mac_rx_valid),
        .rx_good(mac_rx_good),
        .rx_bad(mac_rx_bad)
    );
    // CLK_HZ 显式传入：HELLO 20ms / peer timeout 100ms / retry 5ms 都按 bus_clk
    // 换算，降频后必须同步，否则协议时间窗会跟着拉长。
    // 1 ms ARQ retry timeout (half-rate retry clock, see db_link): measured fastest
    // on hardware (0.6 s vs 4 s at 5 ms;
    // 500 us and 250 us both regress because they fall below the typical ACK latency.
    db_link #(.ROLE(1),.CLK_HZ(`VBP_SD_CLK_HZ),.RETRY_CYCLES(`VBP_SD_CLK_HZ/2000),
              .LOCAL_MAC(`DB_MAC_MEDIA),.PEER_MAC(`DB_MAC_RENDER)) u_link(
        .retry_seen(),.error_seen(),.drop_seen(),
        .clk(clk),
        .rst(rst),
        .phy_ok(phy_ok),
        .link_up(link_up),
        .session_reset(session_reset),
        .tx_meta_valid(tx_meta_valid),
        .tx_meta_ready(tx_meta_ready),
        .tx_channel(tx_channel),
        .tx_opcode(tx_opcode),
        .tx_object(tx_object),
        .tx_offset(tx_offset),
        .tx_length(tx_length),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_data(tx_data),
        .tx_last(tx_last),
        .rx_meta_valid(rx_meta_valid),
        .rx_meta_ready(rx_meta_ready),
        .rx_required(rx_required),
        .rx_channel(rx_channel),
        .rx_opcode(rx_opcode),
        .rx_object(rx_object),
        .rx_offset(rx_offset),
        .rx_length(rx_length),
        .rx_valid(rx_valid),
        .rx_ready(rx_ready),
        .rx_data(rx_data),
        .rx_last(rx_last),
        .mac_tx_data(mac_tx_data),
        .mac_tx_valid(mac_tx_valid),
        .mac_tx_ack(mac_tx_ack),
        .mac_rx_data(mac_rx_data),
        .mac_rx_valid(mac_rx_valid),
        .mac_rx_good(mac_rx_good),
        .mac_rx_bad(mac_rx_bad),
        .mac_tx_clk(mem_clk),
        .mac_rx_clk(rx_clk),
        .retry_count(),
        .crc_errors(),
        .rx_drops()
    );

    wire em_request_valid,em_reply_valid,em_reply_ready;wire [1:0] em_request_mode;
    wire [31:0] em_request_revision,em_reply_revision,em_audio_epoch,em_audio_file_epoch,em_audio_consumed_epoch,em_audio_dispatch_epoch;wire em_audio_dispatch_valid;wire [127:0] em_request_snapshot;
    wire [7:0] em_reply_status;
    wire subtitle_valid,subtitle_ready,subtitle_word_valid,subtitle_word_ready,subtitle_applied,image_presented,image_transport_idle;
    wire [31:0] subtitle_revision,subtitle_word,subtitle_applied_revision,presented_image_id;
    wire [1:0] subtitle_applied_result;
    wire image_req,image_ack,image_finish_toggle,image_burst_ready,image_pixel_ready,image_word_valid,image_source_ok,image_source_failed,display_valid;
    wire [31:0] image_word,pcm,pcm_total,pcm_base,played_position;
    wire overlay_begin_req,overlay_begin_ack,overlay_begin_ready,overlay_failed,overlay_abort_req;
    wire overlay_word_valid,overlay_word_ready,overlay_burst_ready,overlay_source_ok,overlay_source_failed,overlay_applied;
    wire [31:0] overlay_begin_object,overlay_word;
    wire pcm_push,pcm_clear,pcm_eof,pcm_burst_ready,pcm_stream_toggle,paused,seek_request,seek_execute,resume_request,remote_playing;
    wire [4:0] contrast_level,saturation_level;wire [3:0] brightness_level;wire [1:0] brightness_mode;
    wire ui_wr_en,ui_active,ui_cursor_en,ui_commit_toggle;wire [8:0] ui_wr_addr;wire [7:0] ui_wr_data;wire [3:0] ui_cursor_row,diag;
    reg link_seen,ever_link;reg image_replay;
    always @(posedge clk or posedge rst)
        if(rst) begin link_seen<=0;ever_link<=0;image_replay<=0;end
        else begin
            // A quick render reset can replace its session before the PHY or
            // link-up level drops. Replay on that session event as well.
            image_replay<=link_up && ever_link && (!link_seen || session_reset);
            link_seen<=link_up;if(link_up) ever_link<=1;
        end
    wire text_osd_page;wire [3:0] ui_page;wire [1:0] transition_mode;
    wire [4:0] volume_level;wire volume_changed,volume_hint;wire [31:0] volume_revision;
    wire kp_valid;wire [5:0] kp_data;
    media_core  u_media(
        .emergency_request_valid(em_request_valid),.emergency_request_mode(em_request_mode),.emergency_request_revision(em_request_revision),
        .emergency_request_snapshot(em_request_snapshot),.emergency_reply_valid(em_reply_valid),.emergency_reply_ready(em_reply_ready),
        .emergency_reply_revision(em_reply_revision),.emergency_reply_status(em_reply_status),.audio_epoch(em_audio_epoch),.audio_file_epoch(em_audio_file_epoch),.audio_consumed_epoch(em_audio_consumed_epoch),.audio_dispatch_epoch(em_audio_dispatch_epoch),.audio_dispatch_valid(em_audio_dispatch_valid),
        .subtitle_session_reset(session_reset),
        .image_presented(image_presented),.presented_image_id(presented_image_id),
        .render_image_transport_idle(image_transport_idle),
        .subtitle_valid(subtitle_valid),.subtitle_ready(subtitle_ready),.subtitle_revision(subtitle_revision),
        .subtitle_word_valid(subtitle_word_valid),.subtitle_word_ready(subtitle_word_ready),.subtitle_word(subtitle_word),
        .subtitle_applied(subtitle_applied),.subtitle_applied_revision(subtitle_applied_revision),.subtitle_applied_result(subtitle_applied_result),
        .volume_level(volume_level),.volume_changed(volume_changed),.volume_hint(volume_hint),.volume_revision(volume_revision),
        .keypad_valid(kp_valid),.keypad_data(kp_data),.keypad_cancel(session_reset || !link_up),
        .contrast_level(contrast_level),.saturation_level(saturation_level),.brightness_level(brightness_level),.brightness_mode(brightness_mode),
        .transition_mode(transition_mode),
        .clk(clk),
        .rst(rst),
        .link_up(link_up),
        .remote_playing(remote_playing),
        .KEY2(KEY2),
        .KEY3(KEY3),
        .KEY4(KEY4),
        .SD_CLK(SD_CLK),
        .SD_CMD(SD_CMD),
        .SD_DAT0(SD_DAT0),
        .SD_DAT1(SD_DAT1),
        .SD_DAT2(SD_DAT2),
        .SD_DAT3(SD_DAT3),
        .image_req(image_req),
        .image_ack(image_ack),
        .image_finish_toggle(image_finish_toggle),
        .image_burst_ready(image_burst_ready),.image_pixel_ready(image_pixel_ready),
        .image_word_valid(image_word_valid),
        .image_word(image_word),
        .image_source_ok(image_source_ok),
        .image_source_failed(image_source_failed),
        .image_replay(image_replay),
        .overlay_begin_req(overlay_begin_req),.overlay_begin_object(overlay_begin_object),
        .overlay_begin_ack(overlay_begin_ack),.overlay_begin_ready(overlay_begin_ready),.overlay_failed(overlay_failed),
        .overlay_abort_req(overlay_abort_req),.overlay_word_valid(overlay_word_valid),.overlay_word(overlay_word),
        .overlay_word_ready(overlay_word_ready),.overlay_burst_ready(overlay_burst_ready),.overlay_source_ok(overlay_source_ok),
        .overlay_source_failed(overlay_source_failed),.overlay_applied(overlay_applied),
        .pcm_push(pcm_push),
        .pcm(pcm),
        .pcm_clear(pcm_clear),
        .pcm_eof(pcm_eof),
        .pcm_burst_ready(pcm_burst_ready),
        .pcm_total(pcm_total),
        .pcm_base(pcm_base),
        .pcm_stream_toggle(pcm_stream_toggle),
        .paused(paused),
        .seek_request(seek_request),
        .seek_execute(seek_execute),
        .resume_request(resume_request),
        .played_position(played_position),
        .ui_wr_en(ui_wr_en),
        .ui_wr_addr(ui_wr_addr),
        .ui_wr_data(ui_wr_data),
        .text_osd_page(text_osd_page),.ui_active(ui_active),
        .ui_page(ui_page),
        .ui_cursor_en(ui_cursor_en),
        .ui_cursor_row(ui_cursor_row),
        .ui_commit_toggle(ui_commit_toggle),
        .diag(diag),
        .display_valid(display_valid)
    );
    seam_media  u_seam(
        .emergency_request_valid(em_request_valid),.emergency_request_mode(em_request_mode),.emergency_request_revision(em_request_revision),
        .emergency_request_snapshot(em_request_snapshot),.emergency_reply_valid(em_reply_valid),.emergency_reply_ready(em_reply_ready),
        .emergency_reply_revision(em_reply_revision),.emergency_reply_status(em_reply_status),.audio_epoch(em_audio_epoch),.audio_file_epoch(em_audio_file_epoch),.audio_consumed_epoch(em_audio_consumed_epoch),.audio_dispatch_epoch(em_audio_dispatch_epoch),.audio_dispatch_valid(em_audio_dispatch_valid),
        .image_presented(image_presented),.presented_image_id(presented_image_id),.image_transport_idle(image_transport_idle),
        .subtitle_valid(subtitle_valid),.subtitle_ready(subtitle_ready),.subtitle_revision(subtitle_revision),
        .subtitle_word_valid(subtitle_word_valid),.subtitle_word_ready(subtitle_word_ready),.subtitle_word(subtitle_word),
        .subtitle_applied(subtitle_applied),.subtitle_applied_revision(subtitle_applied_revision),.subtitle_applied_result(subtitle_applied_result),
        .volume_level(volume_level),.volume_changed(volume_changed),.volume_hint(volume_hint),.volume_revision(volume_revision),
        .keypad_valid(kp_valid),.keypad_data(kp_data),
        .contrast_level(contrast_level),.saturation_level(saturation_level),.brightness_level(brightness_level),.brightness_mode(brightness_mode),
        .transition_mode(transition_mode),
        .ui_page(ui_page),
        .clk(clk),
        .rst(rst),
        .link_up(link_up),
        .session_reset(session_reset),
        .tx_meta_valid(tx_meta_valid),
        .tx_meta_ready(tx_meta_ready),
        .tx_channel(tx_channel),
        .tx_opcode(tx_opcode),
        .tx_object(tx_object),
        .tx_offset(tx_offset),
        .tx_length(tx_length),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_data(tx_data),
        .tx_last(tx_last),
        .rx_meta_valid(rx_meta_valid),
        .rx_meta_ready(rx_meta_ready),
        .rx_required(rx_required),
        .rx_channel(rx_channel),
        .rx_opcode(rx_opcode),
        .rx_object(rx_object),
        .rx_offset(rx_offset),
        .rx_length(rx_length),
        .rx_valid(rx_valid),
        .rx_ready(rx_ready),
        .rx_data(rx_data),
        .rx_last(rx_last),
        .image_req(image_req),
        .image_ack(image_ack),
        .image_finish_toggle(image_finish_toggle),
        .image_word_valid(image_word_valid),
        .image_word(image_word),
        .image_source_ok(image_source_ok),
        .image_source_failed(image_source_failed),
        .image_burst_ready(image_burst_ready),.image_pixel_ready(image_pixel_ready),
        .overlay_begin_req(overlay_begin_req),.overlay_begin_ack(overlay_begin_ack),.overlay_begin_ready(overlay_begin_ready),
        .overlay_failed(overlay_failed),.overlay_begin_object(overlay_begin_object),.overlay_abort_req(overlay_abort_req),
        .overlay_word_valid(overlay_word_valid),.overlay_word(overlay_word),.overlay_word_ready(overlay_word_ready),.overlay_burst_ready(overlay_burst_ready),
        .overlay_source_ok(overlay_source_ok),.overlay_applied(overlay_applied),
        .pcm_push(pcm_push),
        .pcm(pcm),
        .pcm_clear(pcm_clear),
        .pcm_eof(pcm_eof),
        .pcm_burst_ready(pcm_burst_ready),
        .pcm_total(pcm_total),
        .pcm_base(pcm_base),
        .pcm_stream_toggle(pcm_stream_toggle),
        .paused(paused),
        .seek_request(seek_request),
        .seek_execute(seek_execute),
        .played_position(played_position),
        .resume_request(resume_request),
        .remote_playing(remote_playing),
        .ui_wr_en(ui_wr_en),
        .ui_wr_addr(ui_wr_addr),
        .ui_wr_data(ui_wr_data),
        .text_osd_page(text_osd_page),.ui_active(ui_active),
        .ui_cursor_en(ui_cursor_en),
        .ui_cursor_row(ui_cursor_row),
        .ui_commit_toggle(ui_commit_toggle),
        .diag(diag),
        .overflow()
    );
    assign LED1=~link_up;
`ifndef DB_BEHAVIORAL_RAM
    // Keep both independent 32-bit ports and all 2048 words. Only the native
    // RAM type changes; common link RTL and its CDC structure are identical.
    defparam u_link.u_packet_ram.u_ram.IMPLEMENT="32K";
`endif
endmodule
