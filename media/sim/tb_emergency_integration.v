`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_emergency_integration;
 reg clk=0,video_clk=0,rst=1,link_up=1,session_reset=0,vs=0;
 always #5 clk=~clk;always #6.667 video_clk=~video_clk;
 always begin #10000;vs=1;#100;vs=0;end
 wire KEY2=1,KEY3=1,KEY4=1,SD_DAT0=1,SD_DAT1=1,SD_DAT2=1,SD_DAT3=1;
 wire SD_CLK,SD_CMD;
 wire DBG_SD_INIT_DONE,DBG_SD_INIT_ERROR,DBG_SD_HIGH_SPEED,DBG_SD_BUS4,DBG_SD_RD_ERROR,DBG_UI_ACTIVE;
 wire [3:0] DBG_SD_ERR_CODE,DBG_UI_STATE;wire [4:0] DBG_SD_STATE;wire [7:0] DBG_WAV_STATUS;
 wire tx_meta_valid,tx_meta_ready,tx_valid,tx_ready,tx_last;
 wire [7:0] tx_channel,tx_opcode;wire [31:0] tx_object,tx_offset,tx_data;wire [15:0] tx_length;
 wire rx_meta_valid,rx_meta_ready,rx_valid,rx_ready,rx_last;wire rx_required=1;
 wire [7:0] rx_channel,rx_opcode;wire [31:0] rx_object,rx_offset,rx_data;wire [15:0] rx_length;
 reg media_reset=0,render_reset=0;wire media_rst=rst || media_reset;wire render_rst=rst || render_reset;
 reg key_down=0;reg [3:0] key_id=0;
 wire [1:0] mode;wire block,hold_audio,em_send,em_send_ready,em_reply,allow_audio;
 wire [31:0] revision,reply_revision,reply_epoch,allowed_epoch;wire [127:0] snapshot;
 wire [7:0] reply_status,status;
 wire begin_audio,stop_audio,eof_audio,pause_audio,freeze_audio,push_audio,packet_ready;
 wire [31:0] audio_id,audio_total,audio_base,audio_word,epoch_v,pos_v,total_v;
 wire playing_v,paused_v,restart_v,valid_audio,ready_audio;
 wire [23:0] left_audio,right_audio;
 wire feedback;wire [31:0] fb_epoch,fb_position;wire [2:0] fb_flags;
 wire sink_ui_toggle;
    wire em_request_valid,em_reply_valid,em_reply_ready;wire [1:0] em_request_mode;
    wire [31:0] em_request_revision,em_reply_revision,em_audio_epoch,em_audio_file_epoch,em_audio_consumed_epoch,em_audio_dispatch_epoch;wire em_audio_dispatch_valid;wire [127:0] em_request_snapshot;
    wire [7:0] em_reply_status;
    wire subtitle_valid,subtitle_ready,subtitle_word_valid,subtitle_word_ready,subtitle_applied,image_presented;
    wire [31:0] subtitle_revision,subtitle_word,subtitle_applied_revision,presented_image_id;
    wire [1:0] subtitle_applied_result;
    wire image_req,image_ack,image_finish_toggle,image_burst_ready,image_pixel_ready,image_word_valid,image_source_ok,image_source_failed,display_valid;
    wire [31:0] image_word,pcm,pcm_total,pcm_base,played_position;
    wire pcm_push,pcm_clear,pcm_eof,pcm_burst_ready,pcm_stream_toggle,paused,seek_request,seek_execute,resume_request,remote_playing;
    wire [4:0] contrast_level;wire [3:0] brightness_level;wire [1:0] brightness_mode;
    wire ui_wr_en,ui_active,ui_cursor_en,ui_commit_toggle;wire [8:0] ui_wr_addr;wire [7:0] ui_wr_data;wire [3:0] ui_cursor_row,diag;
    wire image_replay=1'b0;
    wire text_osd_page;wire [3:0] ui_page;
    wire [4:0] volume_level;wire volume_changed,volume_hint;wire [31:0] volume_revision;
    wire kp_valid;wire [5:0] kp_data;
    media_core  core(
        .emergency_request_valid(em_request_valid),.emergency_request_mode(em_request_mode),.emergency_request_revision(em_request_revision),
        .emergency_request_snapshot(em_request_snapshot),.emergency_reply_valid(em_reply_valid),.emergency_reply_ready(em_reply_ready),
        .emergency_reply_revision(em_reply_revision),.emergency_reply_status(em_reply_status),.audio_epoch(em_audio_epoch),.audio_file_epoch(em_audio_file_epoch),.audio_consumed_epoch(em_audio_consumed_epoch),.audio_dispatch_epoch(em_audio_dispatch_epoch),.audio_dispatch_valid(em_audio_dispatch_valid),
        .subtitle_session_reset(session_reset),.render_image_transport_idle(1'b1),.overlay_burst_ready(1'b1),
        .image_presented(image_presented),.presented_image_id(presented_image_id),
        .subtitle_valid(subtitle_valid),.subtitle_ready(subtitle_ready),.subtitle_revision(subtitle_revision),
        .subtitle_word_valid(subtitle_word_valid),.subtitle_word_ready(subtitle_word_ready),.subtitle_word(subtitle_word),
        .subtitle_applied(subtitle_applied),.subtitle_applied_revision(subtitle_applied_revision),.subtitle_applied_result(subtitle_applied_result),
        .volume_level(volume_level),.volume_changed(volume_changed),.volume_hint(volume_hint),.volume_revision(volume_revision),
        .keypad_valid(kp_valid),.keypad_data(kp_data),.keypad_cancel(session_reset || !link_up),
        .contrast_level(contrast_level),.brightness_level(brightness_level),.brightness_mode(brightness_mode),
        .clk(clk),
        .rst(media_rst),
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
        .display_valid(display_valid),
        .DBG_SD_INIT_DONE(DBG_SD_INIT_DONE),
        .DBG_SD_INIT_ERROR(DBG_SD_INIT_ERROR),
        .DBG_SD_HIGH_SPEED(DBG_SD_HIGH_SPEED),
        .DBG_SD_BUS4(DBG_SD_BUS4),
        .DBG_SD_RD_ERROR(DBG_SD_RD_ERROR),
        .DBG_SD_ERR_CODE(DBG_SD_ERR_CODE),
        .DBG_SD_STATE(DBG_SD_STATE),
        .DBG_UI_ACTIVE(DBG_UI_ACTIVE),
        .DBG_UI_STATE(DBG_UI_STATE),
        .DBG_WAV_STATUS(DBG_WAV_STATUS)
    );
    seam_media  u_seam(.saturation_level(5'd10),
        .emergency_request_valid(em_request_valid),.emergency_request_mode(em_request_mode),.emergency_request_revision(em_request_revision),
        .emergency_request_snapshot(em_request_snapshot),.emergency_reply_valid(em_reply_valid),.emergency_reply_ready(em_reply_ready),
        .emergency_reply_revision(em_reply_revision),.emergency_reply_status(em_reply_status),.audio_epoch(em_audio_epoch),.audio_file_epoch(em_audio_file_epoch),.audio_consumed_epoch(em_audio_consumed_epoch),.audio_dispatch_epoch(em_audio_dispatch_epoch),.audio_dispatch_valid(em_audio_dispatch_valid),
        .image_presented(image_presented),.presented_image_id(presented_image_id),
        .subtitle_valid(subtitle_valid),.subtitle_ready(subtitle_ready),.subtitle_revision(subtitle_revision),
        .subtitle_word_valid(subtitle_word_valid),.subtitle_word_ready(subtitle_word_ready),.subtitle_word(subtitle_word),
        .subtitle_applied(subtitle_applied),.subtitle_applied_revision(subtitle_applied_revision),.subtitle_applied_result(subtitle_applied_result),
        .volume_level(volume_level),.volume_changed(volume_changed),.volume_hint(volume_hint),.volume_revision(volume_revision),
        .keypad_valid(kp_valid),.keypad_data(kp_data),
        .contrast_level(contrast_level),.brightness_level(brightness_level),.brightness_mode(brightness_mode),
        .ui_page(ui_page),
        .clk(clk),
        .rst(media_rst),
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

 seam_render sink(.clk(clk),.rst(render_rst),.link_up(link_up),.session_reset(session_reset),
  .emergency_block(block),.emergency_request_valid(em_send),.emergency_request_ready(em_send_ready),
  .emergency_mode(mode),.emergency_revision(revision),.emergency_snapshot(snapshot),
  .emergency_reply_valid(em_reply),.emergency_reply_revision(reply_revision),.emergency_reply_epoch(reply_epoch),.emergency_reply_status(reply_status),
  .video_clk(video_clk),.video_rst(render_rst),.vs(vs),
  .rx_meta_valid(tx_meta_valid),.rx_meta_ready(tx_meta_ready),.rx_required(1'b1),
  .rx_channel(tx_channel),.rx_opcode(tx_opcode),.rx_object(tx_object),.rx_offset(tx_offset),.rx_length(tx_length),
  .rx_valid(tx_valid),.rx_ready(tx_ready),.rx_data(tx_data),.rx_last(tx_last),
  .tx_meta_valid(rx_meta_valid),.tx_meta_ready(rx_meta_ready),.tx_channel(rx_channel),.tx_opcode(rx_opcode),
  .tx_object(rx_object),.tx_offset(rx_offset),.tx_length(rx_length),
  .tx_valid(rx_valid),.tx_ready(rx_ready),.tx_data(rx_data),.tx_last(rx_last),
  .keypad_valid(1'b0),.keypad_data(6'd0),.brightness_mode(2'd0),
  .write_req_ack(1'b0),.write_abort_ack(1'b0),.write_full(1'b0),.write_sector_ready(1'b1),.write_finish_toggle(1'b0),
  .read_selected_index(2'd0),.read_handoff_toggle(1'b0),.transition_ack(1'b0),.transition_done(1'b0),.transition_failed(1'b0),
  .ui_commit_toggle(sink_ui_toggle),.ui_commit_seen(sink_ui_toggle),.subtitle_start_ready(1'b1),.subtitle_data_ready(1'b1),.subtitle_applied(1'b0),
  .audio_begin(begin_audio),.audio_stop(stop_audio),.audio_eof(eof_audio),.audio_pause(pause_audio),.audio_freeze(freeze_audio),
  .audio_epoch(audio_id),.audio_total(audio_total),.audio_base(audio_base),.audio_push(push_audio),.audio_data(audio_word),
  .audio_packet_ready(packet_ready),.audio_feedback(feedback),.feedback_epoch(fb_epoch),.feedback_position(fb_position),.feedback_flags(fb_flags));
 db_audio_sink #(.PIX_HZ(75000),.PREFILL(800)) audio(.clk(clk),.rst(render_rst),.video_clk(video_clk),.video_rst(render_rst),.link_up(link_up),
  .begin_stream(begin_audio),.stream_id(audio_id),.total_frames(audio_total),.base_frame(audio_base),.initial_pause(pause_audio),
  .stop(stop_audio),.paused(pause_audio),.frozen(freeze_audio),.local_hold(hold_audio || (block && audio_id!=allowed_epoch)),
  .eof(eof_audio),.push(push_audio),.pcm(audio_word),.packet_ready(packet_ready),
  .epoch_v(epoch_v),.position_v(pos_v),.total_v(total_v),.playing_v(playing_v),.paused_v(paused_v),.restart_v(restart_v),
  .audio_valid(valid_audio),.audio_left(left_audio),.audio_right(right_audio),.ready_v(ready_audio),
  .feedback(feedback),.feedback_epoch(fb_epoch),.feedback_position(fb_position),.feedback_flags(fb_flags));
 reg gpio_b0=0,gpio_b1=0;
 wire alarm_active;wire [2:0] alarm_sources;wire [8:0] alarm_groups;
 emergency_inputs #(.FILTER_CYCLES(4)) alarm_inputs(.clk(clk),.rst(render_rst),.gpio_b0(gpio_b0),.gpio_b1(gpio_b1),.clock_live({7'd26,4'd10,5'd14,5'd12,6'd34,6'd56}),
  .key_down(key_down),.key_online(1'b1),.key_cancel(1'b0),.key_id(key_id),
  .active(alarm_active),.sources(alarm_sources),.groups(alarm_groups));
 emergency_controller local_control(.clk(clk),.rst(render_rst),.link_up(link_up),.session_reset(session_reset),
  .alarm_active(alarm_active),.video_clk(video_clk),.video_rst(render_rst),
  .display_id(32'd0),.display_index(2'd0),.display_valid(1'b0),
  .feedback(feedback),.feedback_epoch(fb_epoch),.feedback_position(fb_position),.feedback_flags(fb_flags),
  .reply_valid(em_reply),.reply_revision(reply_revision),.reply_epoch(reply_epoch),.reply_status(reply_status),
  .picture_restored(mode==2),.audio_ready(ready_audio && epoch_v==allowed_epoch),.frame_sync(vs),
  .mode(mode),.input_block(block),.local_hold(hold_audio),.request_valid(em_send),.request_ready(em_send_ready),
  .revision(revision),.request_snapshot(snapshot),.audio_allowed(allow_audio),.allowed_epoch(allowed_epoch),.status(status));
 wire [31:0] requested_cluster=core.em_play_prepared ? core.wav_prepared_cluster:core.wav_ext_play_cluster;
 integer gpio_revision,gpio_starts;
 integer mono,file_bytes,paused_case,switch_case,em_starts=0,normal_starts=0;reg [31:0] frozen_position;
 always @(posedge clk) if(core.wav_ext_play_req) begin
  $display("WAV request cluster=%d size=%d position=%d",core.wav_ext_play_cluster,core.wav_ext_play_size,core.em_play_position);
  if(requested_cluster==4 && core.em_block) em_starts=em_starts+1;
  if(requested_cluster==3) normal_starts=normal_starts+1;
 end
 task step;input integer n;begin repeat(n) @(negedge clk);end endtask
 task key;input [3:0] id;begin key_down=0;step(4);key_id=id;key_down=1;step(4);key_down=0;end endtask
 initial begin
  mono=$test$plusargs("EM_MONO");file_bytes=44+8000*(mono ? 2:4);
  paused_case=$test$plusargs("EM_PAUSED") || $test$plusargs("EM_PAUSED_SWITCH") || $test$plusargs("EM_SWITCH_MANY");
  switch_case=$test$plusargs("EM_SWITCH") || $test$plusargs("EM_PAUSED_SWITCH") || $test$plusargs("EM_SWITCH_MANY");
  step(10);rst=0;wait(core.em_catalog_done);$display("FAT catalog ready");
  if(core.em_found==$test$plusargs("EM_MISSING") || core.u_wav_playlist.wav_cnt!=($test$plusargs("EM_MISSING") ? 3:2))
   $fatal(1,"FAT reserved file / ordinary list");
  // PRESENTED can precede FAT's descriptor commit. Metadata consumers
  // must wait for the image reader/commit boundary, not capture the old file.
  @(negedge clk);
  force core.img_idle=1'b0;force core.presented_file_cluster=32'd0;force core.presented_file_size=32'd0;
  force image_presented=1'b1;force presented_image_id=32'd77;step(1);release image_presented;
  step(3);force core.presented_file_cluster=32'd9;force core.presented_file_size=32'd900;force core.img_idle=1'b1;
  wait(core.u_subtitle.current_id==77);
  if(core.u_subtitle.current_cluster!=9 || core.u_subtitle.current_size!=900) $fatal(1,"subtitle captured uncommitted descriptor");
  release core.img_idle;release core.presented_file_cluster;release core.presented_file_size;release presented_image_id;
  if(!$test$plusargs("EM_EMPTY")) begin
   @(negedge clk);force core.u_file_browser.ext_play_cluster=32'd3;force core.u_file_browser.ext_play_size=file_bytes;
   force core.br_ext_play_req=1'b1;step(1);release core.br_ext_play_req;release core.u_file_browser.ext_play_cluster;release core.u_file_browser.ext_play_size;
   if($test$plusargs("EM_CFG_RACE")) wait(begin_audio);
   else wait(pos_v>=50);
   $display("normal PCM running");
   if(paused_case) begin
    @(negedge clk);force core.kp_pause=1'b1;step(1);release core.kp_pause;
    wait(paused_v);step(10);
   end
   if(switch_case) begin
    // A replacement file has opened, but its STOP/BEGIN is backpressured.
    // Render still consumes the original epoch; restore must select that file.
    @(negedge clk);force tx_meta_ready=1'b0;
    force core.u_file_browser.ext_play_cluster=32'd5;force core.u_file_browser.ext_play_size=file_bytes;force core.br_ext_play_req=1'b1;
    step(1);release core.br_ext_play_req;release core.u_file_browser.ext_play_cluster;release core.u_file_browser.ext_play_size;
    wait(core.wav_ext_play_ack);step(5);
    if($test$plusargs("EM_SWITCH_MANY")) repeat(6) begin
     @(negedge clk);force core.br_ext_play_req=1'b1;step(1);release core.br_ext_play_req;
     wait(core.wav_ext_play_ack);step(5);
    end
   end
  end
  if($test$plusargs("EM_FORMAT")) core.u_sd_card_sdio.put32(321*512+24,44100);
  if($test$plusargs("EM_PENDING_BEGIN")) begin
   // Hold an already-dispatched BEGIN while another track request arrives.
   // The pending-file mailbox may change, but the open file stays intact
   // until the render endpoint confirms the dispatched epoch.
   @(negedge clk);force core.u_file_browser.ext_play_cluster=32'd5;force core.u_file_browser.ext_play_size=file_bytes;
   force core.br_ext_play_req=1'b1;step(1);release core.br_ext_play_req;
   release core.u_file_browser.ext_play_cluster;release core.u_file_browser.ext_play_size;
   wait(tx_meta_valid && tx_opcode==`DB_PCM_BEGIN && tx_object!=epoch_v);force tx_meta_ready=1'b0;
   @(negedge clk);force core.u_file_browser.ext_play_cluster=32'd3;force core.u_file_browser.ext_play_size=file_bytes;
   force core.br_ext_play_req=1'b1;step(1);release core.br_ext_play_req;
   release core.u_file_browser.ext_play_cluster;release core.u_file_browser.ext_play_size;
   step(2000);
   if(core.u_fat_wav_controller.cap_cluster!=5 || !core.em_audio_context_busy)
    $fatal(1,"open file changed before dispatched BEGIN confirmation");
   release tx_meta_ready;
   wait(core.wav_ext_play_ack && core.u_fat_wav_controller.cap_cluster==3);
   wait(pos_v>=50 && valid_audio && left_audio[23:8]>=1000 && left_audio[23:8]<2000);
  end
  if($test$plusargs("EM_GPIO")) begin gpio_b0=1;step(12);end else key(11);
  if($test$plusargs("EM_QUICK")) key(11);
  wait(local_control.snapshot_ready);frozen_position=snapshot[63:32];
  if(switch_case) begin wait(core.em_block);release tx_meta_ready;end
  if(!$test$plusargs("EM_QUICK")) begin
   if($test$plusargs("EM_MISSING")) wait(status==`DB_EM_MISSING);
   else if($test$plusargs("EM_FORMAT")) wait(status==`DB_EM_FORMAT_ERROR);
   else if($test$plusargs("EM_READ_ERROR")) wait(status==`DB_EM_READ_ERROR);
   else begin
    wait(status==`DB_EM_PLAYING);$display("emergency PCM configured");
    wait(left_audio[23:8]>=16000 && valid_audio);wait(em_starts>=2);
    if(!$test$plusargs("EM_EMPTY") && (core.u_fat_bmp_controller.catalog_mem[261][63:32]!=frozen_position || core.u_fat_bmp_controller.catalog_mem[260][63:32]!=3))
     $fatal(1,"normal audio snapshot");
    if($test$plusargs("EM_GPIO")) begin
     gpio_revision=revision;gpio_starts=em_starts;
     gpio_b1=1;step(12);key(11);step(4);
     if(alarm_sources!=7 || mode!=1 || revision!=gpio_revision || em_starts!=gpio_starts)
      $fatal(1,"adding GPIO/C restarted audio or business request");
     gpio_b0=0;step(12);key(11);step(4);
     if(alarm_sources!=2 || mode!=1 || revision!=gpio_revision || em_starts!=gpio_starts)
      $fatal(1,"partial clear restarted audio or recovered early");
    end else begin gpio_b0=1;step(10);end
    if($test$plusargs("EM_DISCONNECT")) begin
     link_up=0;session_reset=1;step(4);session_reset=0;step(100);link_up=1;
     wait(em_starts>=3);wait(status==`DB_EM_PLAYING);
    end
    if($test$plusargs("EM_RESET")) begin
     link_up=0;session_reset=1;media_reset=1;step(5);media_reset=0;session_reset=0;link_up=1;
     wait(core.em_catalog_done);wait(status==`DB_EM_PLAYING);step(10);
    end
    if($test$plusargs("EM_REENTRY")) begin
     gpio_b0=0;gpio_b1=0;step(10);key(11);wait(mode==2);key(11);wait(mode==1);wait(status==`DB_EM_PLAYING);step(100);
     if(core.u_fat_bmp_controller.catalog_mem[261][63:32]!=frozen_position) $fatal(1,"reentry lost original snapshot");
    end
   end
   if($test$plusargs("EM_RENDER_RESET")) begin
    gpio_b0=0;gpio_b1=0;step(12);
    link_up=0;session_reset=1;render_reset=1;step(5);render_reset=0;session_reset=0;link_up=1;
    wait(!core.em_block && normal_starts>=2);
    wait(valid_audio && left_audio!=0);#1;
    if(mode!=0 || left_audio!==((1000+frozen_position)<<8)) $fatal(1,"render reset stayed in emergency");
    $display("*** PASS *** render reset clears local mode and media unlocks original stream from frame=%0d",frozen_position);$finish;
   end
   if(switch_case && core.u_wav_playlist.cur_idx!=1) $fatal(1,"switch test did not establish replacement cursor");
   if($test$plusargs("EM_RESTORE_BODY_ERROR")) core.u_sd_card_sdio.bad_restore_body=1;
   gpio_b0=0;gpio_b1=0;step(10);if(!$test$plusargs("EM_GPIO")) key(11);
  end
  wait(mode==2);
  if($test$plusargs("EM_RESET")) wait(status==`DB_EM_LOST);
  else if($test$plusargs("EM_EMPTY")) wait(status==`DB_EM_EMPTY);
  else if($test$plusargs("EM_RESTORE_BODY_ERROR")) wait(status==`DB_EM_RESTORE_ERROR);
  else wait(status==`DB_EM_RESTORED);
  wait(mode==0);
  if($test$plusargs("EM_RESET") || $test$plusargs("EM_EMPTY") || $test$plusargs("EM_RESTORE_BODY_ERROR")) begin
   step(100);if(playing_v || left_audio!=0) begin $display("playing=%b left=%h epoch=%d id=%d",playing_v,left_audio,epoch_v,audio_id);$fatal(1,"unavailable normal stream falsely restored");end
  end else begin
   if(paused_case) begin
    step(100);if(pos_v!=frozen_position || !paused_v || left_audio!=0 || !core.u_audio_transport.o_pause) $fatal(1,"paused restoration consumed audio");
    @(negedge clk);force core.kp_pause=1'b1;step(1);release core.kp_pause;
   end
   wait(valid_audio && left_audio!=0);#1;
   if(left_audio!==((1000+frozen_position)<<8)) $fatal(1,"restored first sample got=%h saved=%d",left_audio,frozen_position);
   if(!mono && right_audio!==(-(1000+frozen_position)<<8 & 24'hffffff)) $fatal(1,"restored stereo alignment");
   wait(!core.em_block);if(paused || normal_starts<2) $fatal(1,"normal handoff");
   if(switch_case) begin
    if(core.u_wav_playlist.cur_idx!=0) $fatal(1,"playlist cursor did not restore original file");
    @(negedge clk);force core.kp_track=1'b1;step(1);release core.kp_track;
    wait(core.wav_ext_play_req);if(core.wav_ext_play_cluster!=5) $fatal(1,"next track skipped restored file cursor");
   end
  end
  $display("*** PASS *** integrated real FAT32+two-channel SD+media_core+WAV+protocol+GPIO/C+PCM: mono=%0d emergency loops=%0d exact saved frame=%0d",mono,em_starts,frozen_position);$finish;
 end
 initial begin #3000000;$display("mode=%d status=%d media=%d wav=%d pos=%d epoch=%d allow=%d",mode,status,core.u_emergency.state,core.u_fat_wav_controller.state,pos_v,epoch_v,allowed_epoch);$display("str=%d busy=%b off=%d len=%d hdr=%d hOff=%d sdBase=%d sdPos=%d sdBusy=%b mapcnt=%d",core.u_lba_stream1.state,core.wav_str_busy,core.wav_str_off,core.wav_str_len,core.u_fat_wav_controller.u_hdr.state,core.u_fat_wav_controller.u_hdr.file_off,core.u_sd_card_sdio.base,core.u_sd_card_sdio.pos,core.u_sd_card_sdio.busy,core.map_count1);$fatal(1,"integrated emergency timeout");end
endmodule
