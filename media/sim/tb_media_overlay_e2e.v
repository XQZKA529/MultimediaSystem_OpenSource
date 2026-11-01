`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_media_overlay_e2e;
 reg clk=0,video_clk=0,rst=1,session_reset=0,media_reset=0,render_reset=0;
 wire link_up=1'b1;
 always #5 clk=~clk;
 always #6.667 video_clk=~video_clk;
 wire req,ack,finish,credit,pixel_credit,iv,source_ok,source_failed;
 wire [31:0] iw;wire sdclk,sdcmd;wire [3:0] diag;wire init_done,init_error;
 wire mv,dv,last,mready,rready,rmv,rmr,rdv,rlast;
 wire [7:0] ch,op,rchannel,reply_opcode;wire [31:0] obj,off,data,reply_id,roff,rdata;wire [15:0] len,rlen;
 wire obreq,oback,obready,ofailed,oabort,owvalid,owready,oburst,osok,oapplied,transport_idle;
 wire [31:0] oid,owdata;
 wire overlay_write_en,write_en;wire [10:0] overlay_write_addr;wire [31:0] overlay_write_data,write_data;
 wire prep_toggle,commit_toggle,prep_ack,commit_ack;wire [1:0] transition_mode;
 integer cycles=0,frame_tick=0,bytes=0,words=0,writes=0,aborts=0,applies=0,x,y,pixels=0;
 reg periodic_vs=0,scan=0,scan_vs=0,de=0;wire vs=scan ? scan_vs:periodic_vs;
 wire hs_o,vs_o,de_o;wire [23:0] rgb_o;
 wire flow=(cycles%20000)>=10000;
 always @(posedge clk) begin
   cycles<=cycles+1;
   if(!rst && core.overlay_busy && core.stored_file_data_valid) begin
     bytes=bytes+1;
     if(core.overlay_file_valid!==1'b1)
       $fatal(1,"SD returns byte %0d but overlay valid is not 1: disconnected media_core file return",bytes);
     if(!core.overlay_file_ready) $fatal(1,"non-preemptible SD burst dropped byte %0d under network backpressure",bytes);
   end
   if(!rst && owvalid && owready) words=words+1;
   if(!rst && overlay_write_en) writes=writes+1;
   if(!rst && oabort) aborts=aborts+1;
   if(!rst && oapplied) applies=applies+1;
   if(!rst && core.overlay_file_abort && !core.fat_file_abort)
     $fatal(1,"overlay canceled its SD read but shared storage did not receive file_abort");
 end
 always @(posedge video_clk) begin
   if(rst) begin frame_tick<=0;periodic_vs<=0;end
   else begin periodic_vs<=frame_tick==2047;frame_tick<=frame_tick==2047 ? 0:frame_tick+1;end
 end
    media_core core(.keypad_valid(1'b0),.keypad_data(6'd0),.keypad_cancel(1'b0),.brightness_mode(2'd0),
        .subtitle_session_reset(session_reset),
        .clk(clk),.rst(rst || media_reset),.link_up(link_up),.remote_playing(1'b0),
        .render_image_transport_idle(transport_idle),
        .KEY2(1'b1),.KEY3(1'b1),.KEY4(1'b1),
        .SD_CLK(sdclk),.SD_CMD(sdcmd),.SD_DAT0(1'b1),.SD_DAT1(1'b1),.SD_DAT2(1'b1),.SD_DAT3(1'b1),
        .image_req(req),.image_ack(ack),.image_finish_toggle(finish),.image_burst_ready(credit),.image_pixel_ready(pixel_credit),
        .overlay_begin_req(obreq),.overlay_begin_object(oid),.overlay_begin_ack(oback),.overlay_begin_ready(obready),.overlay_failed(ofailed),
        .overlay_abort_req(oabort),.overlay_word_valid(owvalid),.overlay_word(owdata),.overlay_word_ready(owready),.overlay_burst_ready(oburst),
        .overlay_source_ok(osok),.overlay_applied(oapplied),
        .image_word_valid(iv),.image_word(iw),.image_source_ok(source_ok),.image_source_failed(source_failed),.image_replay(1'b0),
        .pcm_burst_ready(1'b0),.seek_execute(1'b0),.resume_request(1'b0),.played_position(32'd0),
        .diag(diag),.DBG_SD_INIT_DONE(init_done),.DBG_SD_INIT_ERROR(init_error),
        // Explicit defaults for the unused main-image/audio/UI environment.
        .emergency_request_valid(1'd0),.emergency_request_mode(2'd0),.emergency_request_revision(32'd0),.emergency_request_snapshot(128'd0),
        .emergency_reply_valid(),.emergency_reply_ready(1'd0),.emergency_reply_revision(),.emergency_reply_status(),
        .audio_epoch(32'd0),.audio_file_epoch(32'd0),.audio_consumed_epoch(32'd0),.audio_dispatch_epoch(32'd0),
        .audio_dispatch_valid(1'd0),.image_presented(1'd0),.presented_image_id(32'd0),.subtitle_valid(),
        .subtitle_ready(1'd0),.subtitle_revision(),.subtitle_word_valid(),.subtitle_word_ready(1'd0),
        .subtitle_word(),.subtitle_applied(1'd0),.subtitle_applied_revision(32'd0),.subtitle_applied_result(2'd0),
        .overlay_source_failed(),.pcm_push(),.pcm(),.pcm_clear(),
        .pcm_eof(),.pcm_total(),.pcm_base(),.pcm_stream_toggle(),
        .paused(),.seek_request(),.ui_wr_en(),.ui_wr_addr(),
        .ui_wr_data(),.volume_level(),.volume_changed(),.volume_hint(),
        .volume_revision(),.contrast_level(),.brightness_level(),.transition_mode(),
        .text_osd_page(),.ui_page(),.ui_active(),.ui_cursor_en(),
        .ui_commit_toggle(),.ui_cursor_row(),.display_valid(),.DBG_SD_HIGH_SPEED(),
        .DBG_SD_BUS4(),.DBG_SD_RD_ERROR(),.DBG_SD_ERR_CODE(),.DBG_SD_STATE(),
        .DBG_UI_ACTIVE(),.DBG_UI_STATE(),.DBG_WAV_STATUS()
    );
    seam_media sender(.saturation_level(5'd10),.volume_level(5'd20),.volume_changed(1'b0),.volume_hint(1'b0),.volume_revision(32'd0),.contrast_level(5'd10),.brightness_level(4'd10),
        .clk(clk),.rst(rst || media_reset),.link_up(link_up),.session_reset(session_reset),
        .image_req(1'b0),.image_ack(ack),.image_finish_toggle(finish),.image_transport_idle(transport_idle),.image_burst_ready(credit),.image_pixel_ready(pixel_credit),
        .overlay_begin_req(obreq),.overlay_begin_object(oid),.overlay_begin_ack(oback),.overlay_begin_ready(obready),.overlay_failed(ofailed),
        .overlay_abort_req(oabort),.overlay_word_valid(owvalid),.overlay_word(owdata),.overlay_word_ready(owready),.overlay_burst_ready(oburst),
        .overlay_source_ok(osok),.overlay_applied(oapplied),
        .image_word_valid(iv),.image_word(iw),.image_source_ok(source_ok),.image_source_failed(source_failed),
        .pcm_push(1'b0),.pcm(32'd0),.pcm_clear(1'b0),.pcm_eof(1'b0),.pcm_total(32'd0),.pcm_base(32'd0),
        .pcm_stream_toggle(1'b0),.paused(1'b0),.seek_request(1'b0),
        .subtitle_valid(1'b0),.subtitle_revision(32'd0),.subtitle_word(32'd0),.subtitle_word_valid(1'b0),
        .ui_wr_en(1'b0),.ui_wr_addr(9'd0),.ui_wr_data(8'd0),.text_osd_page(1'b0),.ui_active(1'b0),.ui_cursor_en(1'b0),.ui_cursor_row(4'd0),.ui_commit_toggle(1'b0),.diag(diag),
        .rx_meta_valid(rmv),.rx_meta_ready(rmr),.rx_required(1'b1),.rx_channel(8'd0),.rx_opcode(reply_opcode),.rx_object(reply_id),.rx_offset(32'd0),.rx_length(16'd0),
        .rx_valid(1'b0),.rx_data(32'd0),.rx_last(1'b0),
        .tx_meta_valid(mv),.tx_meta_ready(mready),.tx_channel(ch),.tx_opcode(op),.tx_object(obj),.tx_offset(off),.tx_length(len),
        .tx_valid(dv),.tx_ready(rready && flow),.tx_data(data),.tx_last(last),
        // Explicit defaults for the unused main-image/audio/UI environment.
        .emergency_request_valid(),.emergency_request_mode(),.emergency_request_revision(),.emergency_request_snapshot(),
        .emergency_reply_valid(1'd0),.emergency_reply_ready(),.emergency_reply_revision(32'd0),.emergency_reply_status(8'd0),
        .audio_epoch(),.audio_file_epoch(),.audio_consumed_epoch(),.audio_dispatch_epoch(),
        .audio_dispatch_valid(),.subtitle_ready(),.subtitle_word_ready(),.subtitle_applied(),
        .subtitle_applied_revision(),.subtitle_applied_result(),.image_presented(),.presented_image_id(),
        .pcm_burst_ready(),.seek_execute(),.played_position(),.resume_request(),
        .remote_playing(),.keypad_valid(),.keypad_data(),.brightness_mode(),
        .transition_mode(2'd0),.ui_page(4'd0),.rx_ready(),.overflow()
    );
 seam_render #(.CLK_HZ(100000000)) receiver(
  .emergency_image_idle(),.emergency_block(1'b0),.emergency_request_valid(1'b0),.emergency_request_ready(),
  .emergency_mode(2'd0),.emergency_revision(32'd0),.emergency_snapshot(128'd0),
  .emergency_reply_valid(),.emergency_reply_revision(),.emergency_reply_epoch(),.emergency_reply_status(),
  .emergency_picture_restored(1'b0),.emergency_restore_valid(1'b0),.emergency_restore_index(2'd0),.emergency_restore_id(32'd0),
  .display_image_id(),.subtitle_start(),.subtitle_revision(),.subtitle_start_ready(1'b1),
  .subtitle_data_valid(),.subtitle_data(),.subtitle_last(),.subtitle_data_ready(1'b1),
  .subtitle_applied(1'b0),.subtitle_applied_ready(),.subtitle_applied_revision(32'd0),.subtitle_applied_result(2'd0),
  .overlay_write_en(overlay_write_en),.overlay_write_addr(overlay_write_addr),.overlay_write_data(overlay_write_data),
  .overlay_prepare_toggle(prep_toggle),.overlay_commit_toggle(commit_toggle),.overlay_prepare_ack(prep_ack),.overlay_commit_ack(commit_ack),
  .keypad_valid(1'b0),.keypad_data(6'd0),.keypad_ready(),.video_clk(video_clk),.video_rst(rst || render_reset),.vs(vs),
  .clk(clk),.rst(rst || render_reset),.link_up(link_up),.session_reset(session_reset),
  .rx_meta_valid(mv),.rx_meta_ready(mready),.rx_required(1'b1),.rx_channel(ch),.rx_opcode(op),
  .rx_object(obj),.rx_offset(off),.rx_length(len),.rx_valid(dv && flow),.rx_ready(rready),.rx_data(data),.rx_last(last),
  .tx_meta_valid(rmv),.tx_meta_ready(rmr),.tx_channel(rchannel),.tx_opcode(reply_opcode),.tx_object(reply_id),
  .tx_offset(roff),.tx_length(rlen),.tx_valid(rdv),.tx_ready(1'b1),.tx_data(rdata),.tx_last(rlast),
  .write_req(),.write_req_ack(1'b0),.write_abort(),.write_abort_ack(1'b0),.write_en(write_en),.write_data(write_data),
  .write_full(1'b0),.write_sector_ready(1'b1),.write_finish_toggle(1'b0),.read_selected_index(2'd0),.read_handoff_toggle(1'b0),
  .write_index(),.display_index(),.display_valid(),.transition_req(),.transition_new_index(),.transition_cur_index(),
  .transition_req_mode(),.transition_mode(transition_mode),.transition_ack(1'b0),.transition_done(1'b0),.transition_failed(1'b0),
  .ui_commit_seen(1'b0),.audio_packet_ready(1'b1),.audio_feedback(1'b0),.feedback_epoch(32'd0),.feedback_position(32'd0),.feedback_flags(3'd0),
        // Explicit defaults for the unused main-image/audio/UI environment.
        .text_osd_page(),.ui_active(),.ui_cursor_en(),.ui_commit_toggle(),
        .ui_page(),.ui_cursor_row(),.ui_wr_en(),.ui_wr_addr(),
        .ui_wr_data(),.volume_valid(),.volume_hint(),.volume_level(),
        .contrast_level(),.brightness_mode(2'd0),.brightness_level(),.diag(),
        .audio_begin(),.audio_stop(),.audio_eof(),.audio_pause(),
        .audio_freeze(),.audio_epoch(),.audio_total(),.audio_base(),
        .audio_push(),.audio_data()
    );

 defparam core.u_sd_card_sdio.OVERLAY_FIXTURE=1;
 image_overlay_64 sprite(.wr_clk(clk),.wr_en(overlay_write_en),.wr_addr(overlay_write_addr),.wr_data(overlay_write_data),
   .video_clk(video_clk),.video_rst(rst || render_reset),.hs_in(1'b0),.vs_in(vs),.de_in(de),.rgb_in(24'h123456),.enable_in(1'b1),
   .prepare_toggle(prep_toggle),.commit_toggle(commit_toggle),.prepare_ack(prep_ack),.commit_ack(commit_ack),
   .hs_out(hs_o),.vs_out(vs_o),.de_out(de_o),.rgb_out(rgb_o));
 function [23:0] expected;input integer px,py;reg [7:0] r,g,b;reg [15:0] p;begin
   r=px*4;g=(63-py)*4;b=(63-py)^px;p={r[7:3],g[7:2],b[7:3]};
   expected={p[15:11],p[15:13],p[10:5],p[10:9],p[4:0],p[4:2]};
 end endfunction
 task check_frame;input [511:0] path;integer picture;begin
   picture=$fopen(path,"w");if(!picture) $fatal(1,"cannot open frame capture");
   $fwrite(picture,"P3\n96 96\n255\n");
   @(negedge video_clk);scan=1;scan_vs=1;repeat(2) @(negedge video_clk);scan_vs=0;
   repeat(3) @(negedge video_clk);
   for(y=0;y<96;y=y+1) begin
     for(x=0;x<1280;x=x+1) begin
       @(negedge video_clk);de=1;@(posedge video_clk);#1;
       if(x>=1184) $fwrite(picture,"%0d %0d %0d\n",rgb_o[23:16],rgb_o[15:8],rgb_o[7:0]);
       if(de_o!==1 || hs_o!==0 || vs_o!==0) $fatal(1,"video sync at %0d,%0d",x,y);
       if(x>=1200 && x<1264 && y>=16 && y<80) begin
         if(rgb_o!==expected(x-1200,y-16)) $fatal(1,"overlay pixel %0d,%0d got %h expected %h",x,y,rgb_o,expected(x-1200,y-16));
         pixels=pixels+1;
       end else if(rgb_o!==24'h123456) $fatal(1,"base changed outside overlay at %0d,%0d",x,y);
     end
     @(negedge video_clk);de=0;repeat(2) @(negedge video_clk);
   end
   $fclose(picture);
 end endtask
 initial begin
   repeat(10) @(negedge clk);rst=0;
   wait(req); // Real FAT mount, catalog and primary BMP header probe complete.
   if(!core.overlay_found || core.overlay_cluster!=46 || core.overlay_size!=12342) $fatal(1,"reserved SD file not discovered");
   force core.img_idle=1'b1;force core.display_valid=1'b1;
   wait(oapplied);repeat(10) @(negedge clk);
   if(bytes!=12342 || words!=2048 || writes!=2048 || aborts || core.overlay_busy) $fatal(1,"transaction bytes=%0d words=%0d writes=%0d aborts=%0d",bytes,words,writes,aborts);
   check_frame("overlay_output_crop.ppm");
   if(pixels!=4096) $fatal(1,"pixel count %0d",pixels);
   // Reload after reconnect, then replace that session during an SD payload.
   scan=0;@(negedge clk);session_reset=1;repeat(4) @(negedge clk);session_reset=0;
   wait(writes>2050);@(negedge clk);session_reset=1;repeat(4) @(negedge clk);session_reset=0;
   wait(applies==2);repeat(10) @(negedge clk);
   if(core.overlay_busy) $fatal(1,"reconnected overlay failed to retire");
   check_frame("overlay_output_reconnected_crop.ppm");
   if(pixels!=8192) $fatal(1,"two image pixel count %0d",pixels);
   scan=0;@(negedge clk);render_reset=1;session_reset=1;
   repeat(5) @(negedge clk);render_reset=0;session_reset=0;
   wait(applies==3);repeat(10) @(negedge clk);check_frame("overlay_output_render_reset_crop.ppm");
   scan=0;release core.img_idle;release core.display_valid;
   @(negedge clk);media_reset=1;session_reset=1;repeat(5) @(negedge clk);media_reset=0;session_reset=0;
   wait(req);force core.img_idle=1'b1;force core.display_valid=1'b1;
   wait(applies==4);repeat(10) @(negedge clk);check_frame("overlay_output_media_reset_crop.ppm");
   if(pixels!=16384) $fatal(1,"four image pixel count %0d",pixels);
   $display("*** PASS *** real media_core FAT32 -> overlay RGB565 -> media seam -> render seam -> dual-clock sprite: 12342 bytes per image, 2048 words, 16384 checked pixels, backpressure, reconnect, mid-SD cancellation and independent board resets");$finish;
 end
 initial begin #10000000;$fatal(1,"end-to-end timeout bytes=%0d words=%0d writes=%0d",bytes,words,writes);end
endmodule
