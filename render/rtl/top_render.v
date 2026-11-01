`include "pkg/board_link.vh"
`include "pkg/text_osd_model.vh"
module top_render(
    input wire sys_clk,sys_rst_n,
    input wire GPIOB0,GPIOB1,
    inout wire KEYPAD_SCL,KEYPAD_SDA,
    output wire HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P,inout wire HDMI_DDC_SCL,HDMI_DDC_SDA,
    output wire VGA_HS,VGA_VS,output wire [7:0] VGA_R,VGA_G,VGA_B,
    output wire LED1,DBG_BMP_LOAD_DONE,output wire [1:0] DBG_EMERGENCY_MODE,output wire [7:0] DBG_EMERGENCY_STATUS,
    input wire rgmii_rxc,rgmii_rx_ctl,input wire [3:0] rgmii_rxd,
    output wire rgmii_txc,rgmii_tx_ctl,output wire [3:0] rgmii_txd,output wire mdc,inout wire mdio,
    output wire DBG_LINK_UP,output wire [2:0] DBG_LINK_EVENTS);

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
    wire video_clk,video_5x_clk,video_lock,video_rst,mem_rst;
    video_pll  u_video_pll(
        .refclk(sys_clk),
        .reset(1'b0),
        .extlock(video_lock),
        .clk0_out(video_clk),
        .clk1_out(video_5x_clk)
    );
    reset_sync  u_video_reset(
        .clk(video_clk),
        .rst_in(board_rst),
        .rst_out(video_rst)
    );
    reset_sync  u_mem_reset(
        .clk(mem_clk),
        .rst_in(board_rst),
        .rst_out(mem_rst)
    );
    board_reset  u_reset_hold(
        .clk(sys_clk),
        .rst_n(sys_rst_n),
        .locked(pll_lock && video_lock),
        .rst(board_rst)
    );
    reset_sync  u_bus_reset(
        .clk(clk),
        .rst_in(board_rst),
        .rst_out(rst)
    );
    db_ethernet #(.LOCAL_MAC(`DB_MAC_RENDER)) u_ethernet(
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
    db_link #(.ROLE(2),.LOCAL_MAC(`DB_MAC_RENDER),.PEER_MAC(`DB_MAC_MEDIA)) u_link(
        .retry_seen(DBG_LINK_EVENTS[0]),.error_seen(DBG_LINK_EVENTS[1]),.drop_seen(DBG_LINK_EVENTS[2]),
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
    assign DBG_LINK_UP=link_up;

    wire subtitle_start,subtitle_start_ready,subtitle_data_valid,subtitle_last,subtitle_data_ready,subtitle_applied,subtitle_applied_ready;
    wire [31:0] subtitle_revision,subtitle_data,subtitle_applied_revision,display_image_id;wire [1:0] subtitle_applied_result;
    wire overlay_write_en,overlay_prepare_toggle,overlay_commit_toggle,overlay_prepare_ack,overlay_commit_ack;
    wire [10:0] overlay_write_addr;wire [31:0] overlay_write_data;
    wire write_req,write_abort,write_en,write_req_ack,write_abort_ack,write_full,write_sector_ready,write_finish_toggle;
    wire [31:0] write_data;wire [1:0] write_index,display_index,read_selected_index;
    wire read_handoff_toggle,display_valid,vs;
    wire [4:0] contrast_level,saturation_level;wire [3:0] brightness_level;wire [1:0] brightness_mode;
    wire text_osd_page;wire [3:0] ui_page;
    wire volume_valid,volume_hint;wire [4:0] volume_level;
    wire ui_active,ui_cursor_en,ui_commit_toggle,ui_wr_en,ui_commit_seen;
    wire [3:0] ui_cursor_row,diag;wire [8:0] ui_wr_addr;wire [7:0] ui_wr_data;
    wire audio_begin,audio_stop,audio_eof,audio_pause,audio_freeze,audio_push,audio_packet_ready;
    wire [31:0] audio_epoch,audio_total,audio_base,audio_data,audio_position_v,audio_epoch_v,audio_total_v;
    wire audio_playing_v,audio_paused_v,audio_restart_v,audio_valid;
    wire [23:0] audio_left,audio_right;
    wire audio_feedback;wire [31:0] feedback_epoch,feedback_position;wire [2:0] feedback_flags;
    // ---- 交叉淡化事务邮箱（seam_render 网络域 → render_core 视频域）----
    wire transition_req,transition_ack,transition_done,transition_failed;
    wire [1:0] transition_new_index,transition_cur_index,transition_req_mode,transition_mode;
    wire [1:0] em_mode,em_restore_index;
    wire em_audio_ready_v,em_image_idle;
    wire em_block,em_hold,em_request_valid,em_request_ready,em_reply_valid,em_allow_audio,em_picture_restored,em_restore_valid;
    wire [31:0] em_revision,em_reply_revision,em_reply_epoch,em_allowed_epoch,em_restore_id;
    wire [127:0] em_snapshot;wire [7:0] em_reply_status,em_status;
    wire kp_down,kp_online,kp_valid,kp_ready,kp_cancel;
    wire routed_valid,routed_ready,osd_cancel,osd_edit,osd_up,osd_down,osd_left,osd_right,osd_confirm;
    wire [5:0] routed_data;
    wire [`TEXT_OSD_META_W-1:0] text_osd_metadata;
    wire [31:0] text_osd_revision;
    wire [7:0] text_osd_edit_addr;wire [7:0] text_osd_edit_data;
    wire [3:0] kp_id;wire [5:0] kp_data;
    wire clock_edit,clock_up,clock_down,clock_left,clock_right,clock_confirm,clock_editing;
    wire [32:0] clock_live,clock_draft;wire [2:0] clock_focus;
    wire clock_editor_ready;reg clock_ready_d;
    wire clock_ready_enter=clock_editor_ready && !clock_ready_d;
    always @(posedge clk or posedge rst) begin
        if(rst) clock_ready_d<=0;else clock_ready_d<=clock_editor_ready;
    end
    tm1650_keypad u_keypad(.clk(clk),.rst(rst),.scl(KEYPAD_SCL),.sda(KEYPAD_SDA),.down(kp_down),.key_id(kp_id),.online(kp_online),.cancel(kp_cancel));
    wire [2:0] em_sources,em_video_sources;wire [8:0] em_groups,em_video_groups;
    wire em_active,em_view_enable,em_view_vs;
    wire [98:0] em_timestamps;wire [143:0] em_video_timestamps;
    emergency_inputs u_emergency_inputs(.clk(clk),.rst(rst),.gpio_b0(GPIOB0),.gpio_b1(GPIOB1),
        .key_down(kp_down),.key_online(kp_online),.key_cancel(kp_cancel),.key_id(kp_id),
        .clock_live(clock_live),.timestamps(em_timestamps),.sources(em_sources),.groups(em_groups),.active(em_active));
    emergency_view_cdc u_emergency_view(.clk(clk),.rst(rst),.mode(em_mode),.sources(em_sources),.groups(em_groups),.timestamps(em_timestamps),
        .video_clk(video_clk),.video_rst(video_rst),.enable(em_view_enable),.video_sources(em_video_sources),.video_groups(em_video_groups),.video_timestamps(em_video_timestamps),.vs(em_view_vs));
    emergency_controller u_emergency(.clk(clk),.rst(rst),.link_up(link_up),.session_reset(session_reset),
        .alarm_active(em_active),
        .video_clk(video_clk),.video_rst(video_rst),.display_id(display_image_id),.display_index(display_index),.display_valid(display_valid),
        .feedback(audio_feedback),.feedback_epoch(feedback_epoch),.feedback_position(feedback_position),.feedback_flags(feedback_flags),
        .reply_valid(em_reply_valid),.reply_revision(em_reply_revision),.reply_epoch(em_reply_epoch),.reply_status(em_reply_status),
        .picture_restored(em_picture_restored),.frame_sync(vs),.audio_ready(em_audio_ready_v && audio_epoch_v==em_allowed_epoch),.mode(em_mode),.input_block(em_block),.local_hold(em_hold),
        .request_valid(em_request_valid),.request_ready(em_request_ready),.revision(em_revision),.request_snapshot(em_snapshot),
        .audio_allowed(em_allow_audio),.allowed_epoch(em_allowed_epoch),.restore_picture(),.restore_index(em_restore_index),
        .restore_valid(em_restore_valid),.restore_id(em_restore_id),.status(em_status));
    keypad_event_encoder u_keypad_events(.clk(clk),.rst(rst),.cancel(kp_cancel || osd_cancel || clock_ready_enter),.enabled(link_up && !session_reset && !em_block),.down(kp_down && kp_id!=7 && kp_id!=11),.online(kp_online),.key_id(kp_id),.valid(kp_valid),.ready(kp_ready),.data(kp_data));
    text_osd_event_router u_text_osd_events(
        .input_cancel(kp_cancel),
        .clk(clk),.rst(rst),.link_up(link_up),.session_reset(session_reset),
        .ui_active(ui_active),.text_osd_page(text_osd_page),.ui_page(ui_page),.ui_commit_toggle(ui_commit_toggle),.ui_commit_seen(ui_commit_seen),
        .event_valid(kp_valid),.event_data(kp_data),.event_ready(kp_ready),
        .remote_valid(routed_valid),.remote_data(routed_data),.remote_ready(routed_ready),
        .encoder_cancel(osd_cancel),.edit_enable(osd_edit),.up(osd_up),.down(osd_down),.left(osd_left),.right(osd_right),.confirm(osd_confirm),
        .clock_edit_enable(clock_edit),.clock_up(clock_up),.clock_down(clock_down),.clock_left(clock_left),.clock_right(clock_right),.clock_confirm(clock_confirm));
    calendar_clock u_clock(.clk(clk),.rst(rst),.edit_enable(clock_edit && !em_block),.cancel(kp_cancel || em_block),
        .up(clock_up && clock_editor_ready),.down(clock_down && clock_editor_ready),
        .left(clock_left && clock_editor_ready),.right(clock_right && clock_editor_ready),.confirm(clock_confirm && clock_editor_ready),
        .live(clock_live),.draft(clock_draft),.focus(clock_focus),.editing(clock_editing));
    text_osd_controller u_text_osd_controller(
        .clk(clk),.rst(rst),.edit_enable(osd_edit && !em_block),.up(osd_up),.down(osd_down),
        .left(osd_left),.right(osd_right),.confirm(osd_confirm),
        .metadata(text_osd_metadata),.revision(text_osd_revision),
        .read_addr(text_osd_edit_addr),.read_data(text_osd_edit_data),
        .osd_enable(),.text_len(),.focus_id(),.changed());
    seam_render  u_seam(
        .emergency_image_idle(em_image_idle),.emergency_block(em_block),.emergency_request_valid(em_request_valid),.emergency_request_ready(em_request_ready),
        .emergency_mode(em_mode),.emergency_revision(em_revision),.emergency_snapshot(em_snapshot),
        .emergency_reply_valid(em_reply_valid),.emergency_reply_revision(em_reply_revision),.emergency_reply_epoch(em_reply_epoch),.emergency_reply_status(em_reply_status),
        .emergency_picture_restored(em_picture_restored),.emergency_restore_valid(em_restore_valid),.emergency_restore_index(em_restore_index),.emergency_restore_id(em_restore_id),
        .display_image_id(display_image_id),.subtitle_start(subtitle_start),.subtitle_revision(subtitle_revision),.subtitle_start_ready(subtitle_start_ready),
        .subtitle_data_valid(subtitle_data_valid),.subtitle_data(subtitle_data),.subtitle_last(subtitle_last),.subtitle_data_ready(subtitle_data_ready),
        .subtitle_applied(subtitle_applied),.subtitle_applied_ready(subtitle_applied_ready),.subtitle_applied_revision(subtitle_applied_revision),.subtitle_applied_result(subtitle_applied_result),
        .overlay_prepare_ack(overlay_prepare_ack),.overlay_commit_ack(overlay_commit_ack),
        .volume_valid(volume_valid),.volume_level(volume_level),.volume_hint(volume_hint),
        .keypad_valid(routed_valid),.keypad_data(routed_data),.keypad_ready(routed_ready),
        .contrast_level(contrast_level),.saturation_level(saturation_level),.brightness_level(brightness_level),.brightness_mode(brightness_mode),
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
        .overlay_write_en(overlay_write_en),.overlay_write_addr(overlay_write_addr),.overlay_write_data(overlay_write_data),
        .overlay_prepare_toggle(overlay_prepare_toggle),.overlay_commit_toggle(overlay_commit_toggle),
        .video_clk(video_clk),
        .video_rst(video_rst),
        .vs(vs),
        .write_req(write_req),
        .write_req_ack(write_req_ack),
        .write_abort(write_abort),
        .write_abort_ack(write_abort_ack),
        .write_en(write_en),
        .write_data(write_data),
        .write_full(write_full),
        .write_sector_ready(write_sector_ready),
        .write_finish_toggle(write_finish_toggle),
        .read_selected_index(read_selected_index),
        .read_handoff_toggle(read_handoff_toggle),
        .write_index(write_index),
        .display_index(display_index),
        .display_valid(display_valid),
        .transition_req(transition_req),
        .transition_new_index(transition_new_index),
        .transition_cur_index(transition_cur_index),
        .transition_req_mode(transition_req_mode),
        .transition_mode(transition_mode),
        .transition_ack(transition_ack),
        .transition_done(transition_done),
        .transition_failed(transition_failed),
        .text_osd_page(text_osd_page),.ui_active(ui_active),
        .ui_page(ui_page),
        .ui_cursor_en(ui_cursor_en),
        .ui_commit_toggle(ui_commit_toggle),
        .ui_cursor_row(ui_cursor_row),
        .ui_wr_en(ui_wr_en),
        .ui_wr_addr(ui_wr_addr),
        .ui_wr_data(ui_wr_data),
        .ui_commit_seen(ui_commit_seen),
        .diag(diag),
        .audio_begin(audio_begin),
        .audio_stop(audio_stop),
        .audio_eof(audio_eof),
        .audio_pause(audio_pause),
        .audio_freeze(audio_freeze),
        .audio_epoch(audio_epoch),
        .audio_total(audio_total),
        .audio_base(audio_base),
        .audio_push(audio_push),
        .audio_data(audio_data),
        .audio_packet_ready(audio_packet_ready),
        .audio_feedback(audio_feedback),
        .feedback_epoch(feedback_epoch),
        .feedback_position(feedback_position),
        .feedback_flags(feedback_flags)
    );
    db_audio_sink  u_audio(
        .clk(clk),
        .rst(rst),
        .video_clk(video_clk),
        .video_rst(video_rst),
        .link_up(link_up),
        .begin_stream(audio_begin),
        .stream_id(audio_epoch),
        .total_frames(audio_total),
        .base_frame(audio_base),
        .initial_pause(audio_pause),
        .stop(audio_stop),
        .paused(audio_pause),
        .frozen(audio_freeze),.local_hold(em_hold || (em_block && audio_epoch!=em_allowed_epoch)),
        .eof(audio_eof),
        .push(audio_push),
        .pcm(audio_data),
        .packet_ready(audio_packet_ready),
        .epoch_v(audio_epoch_v),
        .position_v(audio_position_v),
        .total_v(audio_total_v),
        .playing_v(audio_playing_v),
        .paused_v(audio_paused_v),
        .restart_v(audio_restart_v),.ready_v(em_audio_ready_v),
        .audio_valid(audio_valid),
        .audio_left(audio_left),
        .audio_right(audio_right),
        .feedback(audio_feedback),
        .feedback_epoch(feedback_epoch),
        .feedback_position(feedback_position),
        .feedback_flags(feedback_flags)
    );
    render_core  u_render(
        .clock_live(clock_live),.clock_draft(clock_draft),.clock_focus(clock_focus),.clock_editing(clock_editing),.clock_editor_ready(clock_editor_ready),.emergency_view_vs(em_view_vs),
        .emergency_view_enable(em_view_enable),.emergency_sources(em_video_sources),.emergency_groups(em_video_groups),.emergency_timestamps(em_video_timestamps),
        .emergency_image_idle(em_image_idle),.emergency_mode(em_mode),.emergency_audio_allowed(em_allow_audio),.emergency_audio_epoch(em_allowed_epoch),.audio_epoch(audio_epoch_v),
        .emergency_restore_valid(em_restore_valid),.emergency_restore_index(em_restore_index),.emergency_picture_restored(em_picture_restored),
        .subtitle_session_reset(session_reset),
        .display_image_id(display_image_id),.subtitle_start(subtitle_start),.subtitle_revision(subtitle_revision),.subtitle_start_ready(subtitle_start_ready),
        .subtitle_data_valid(subtitle_data_valid),.subtitle_data(subtitle_data),.subtitle_last(subtitle_last),.subtitle_data_ready(subtitle_data_ready),
        .subtitle_applied(subtitle_applied),.subtitle_applied_ready(subtitle_applied_ready),.subtitle_applied_revision(subtitle_applied_revision),.subtitle_applied_result(subtitle_applied_result),
        .volume_valid(volume_valid),.volume_level(volume_level),.volume_hint(volume_hint),.volume_cancel(session_reset || !link_up),
        .text_osd_metadata(text_osd_metadata),.text_osd_revision(text_osd_revision),
        .text_osd_edit_addr(text_osd_edit_addr),.text_osd_edit_data(text_osd_edit_data),
        .contrast_level(contrast_level),.saturation_level(saturation_level),.brightness_level(brightness_level),.brightness_mode(brightness_mode),
        .clk(clk),
        .rst(rst),
        .mem_clk(mem_clk),
        .mem_clk_sft(mem_sft),
        .mem_rst(mem_rst),
        .video_clk(video_clk),
        .video_5x_clk(video_5x_clk),
        .video_rst(video_rst),
        .text_osd_page(text_osd_page),.ui_active(ui_active),
        .ui_page(ui_page),
        .ui_cursor_en(ui_cursor_en),
        .ui_commit_toggle(ui_commit_toggle),
        .ui_cursor_row(ui_cursor_row),
        .ui_wr_en(ui_wr_en),
        .ui_wr_addr(ui_wr_addr),
        .ui_wr_data(ui_wr_data),
        .ui_commit_seen(ui_commit_seen),
        .diag(diag),
        .overlay_write_en(overlay_write_en),.overlay_write_addr(overlay_write_addr),.overlay_write_data(overlay_write_data),
        .overlay_prepare_toggle(overlay_prepare_toggle),.overlay_commit_toggle(overlay_commit_toggle),
        .overlay_prepare_ack(overlay_prepare_ack),.overlay_commit_ack(overlay_commit_ack),
        .link_up(link_up),
        .audio_valid(audio_valid),
        .audio_left(audio_left),
        .audio_right(audio_right),
        .vs(vs),
        .HDMI_CLK_P(HDMI_CLK_P),
        .HDMI_D2_P(HDMI_D2_P),
        .HDMI_D1_P(HDMI_D1_P),
        .HDMI_D0_P(HDMI_D0_P),
        .HDMI_DDC_SCL(HDMI_DDC_SCL),
        .HDMI_DDC_SDA(HDMI_DDC_SDA),
        .VGA_HS(VGA_HS),
        .VGA_VS(VGA_VS),
        .VGA_R(VGA_R),
        .VGA_G(VGA_G),
        .VGA_B(VGA_B),
        .image_write_req(write_req),
        .image_write_abort(write_abort),
        .image_write_en(write_en),
        .image_write_data(write_data),
        .image_write_index(write_index),
        .image_display_index(display_index),
        .image_display_valid(display_valid),
        .transition_req(transition_req),
        .transition_new_index(transition_new_index),
        .transition_cur_index(transition_cur_index),
        .transition_req_mode(transition_req_mode),
        .transition_ack(transition_ack),
        .transition_done(transition_done),
        .transition_failed(transition_failed),
        .image_write_ack(write_req_ack),
        .image_abort_ack(write_abort_ack),
        .image_write_full(write_full),
        .image_write_ready(write_sector_ready),
        .image_write_finish_toggle(write_finish_toggle),
        .image_read_index(read_selected_index),
        .image_read_handoff_toggle(read_handoff_toggle),
        .audio_position(audio_position_v),
        .audio_total(audio_total_v),
        .audio_playing(audio_playing_v),
        .audio_paused(audio_paused_v),
        .audio_restart(audio_restart_v)
    );
    assign DBG_EMERGENCY_MODE=em_mode;assign DBG_EMERGENCY_STATUS=em_status;
    assign LED1=~display_valid;assign DBG_BMP_LOAD_DONE=display_valid;
endmodule
