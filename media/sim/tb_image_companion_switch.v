`timescale 1ns/1ps
// Production media_core: first image -> companion lookup -> next/browser image.
module tb_image_companion_switch #(parameter COMPANIONS=1,REAL_CARD=0,CARD_TARGET_CLUSTER=0);
    reg clk=0,rst=1,present=0,finish=0,ack=0;
    reg keypad_valid=0;reg [5:0] keypad_data=0;
    always #5 clk=~clk;
    wire req,source_ok,source_failed,valid,sub_valid,sub_word_valid;
    wire [3:0] diag;
    wire [31:0] image_word,sub_word;
    wire sd_clk,sd_cmd;
    media_core core(
        .clk(clk),.rst(rst),.link_up(1'b1),.subtitle_session_reset(1'b0),
        .emergency_request_valid(1'b0),.emergency_request_mode(2'd0),.emergency_request_revision(32'd0),.emergency_request_snapshot(128'd0),
        .emergency_reply_ready(1'b1),.audio_epoch(32'd0),.audio_file_epoch(32'd0),.audio_consumed_epoch(32'd0),.audio_dispatch_epoch(32'd0),.audio_dispatch_valid(1'b0),
        .image_presented(present),.presented_image_id(32'd1),.render_image_transport_idle(1'b1),
        .subtitle_valid(sub_valid),.subtitle_ready(1'b1),.subtitle_word_valid(sub_word_valid),.subtitle_word_ready(1'b1),.subtitle_word(sub_word),
        .subtitle_applied(1'b0),.subtitle_applied_revision(32'd0),.subtitle_applied_result(2'd0),
        .keypad_valid(keypad_valid),.keypad_data(keypad_data),.keypad_cancel(1'b0),.brightness_mode(2'd0),
        .KEY2(1'b1),.KEY3(1'b1),.KEY4(1'b1),.remote_playing(1'b0),
        .SD_CLK(sd_clk),.SD_CMD(sd_cmd),.SD_DAT0(1'b1),.SD_DAT1(1'b1),.SD_DAT2(1'b1),.SD_DAT3(1'b1),
        .image_req(req),.image_ack(ack),.image_finish_toggle(finish),.image_burst_ready(1'b1),.image_pixel_ready(1'b1),
        .image_word_valid(valid),.image_word(image_word),.image_source_ok(source_ok),.image_source_failed(source_failed),.image_replay(1'b0),
        .overlay_burst_ready(1'b1),.pcm_burst_ready(1'b1),.seek_execute(1'b0),.resume_request(1'b0),.played_position(32'd0),.diag(diag));
    defparam core.u_sd_card_sdio.IMAGE_SWITCH_FIXTURE=COMPANIONS ? 2:1;
    defparam core.u_fat_bmp_controller.DST_W=8,core.u_fat_bmp_controller.DST_H=4;
    defparam core.u_rgb888_word_packer.FRAME_PIXELS=32;
    integer words=0,frames=0,matches=0,wav_matches=0,pcm_frames=0,companion_stops=0;
    reg arbitration_test=0;
    reg expect_companion_clear=0;
    always @(posedge clk) if(!rst) begin
        if(valid) words=words+1;
        if(core.sub_match_done) matches=matches+1;
        if(core.sub_wav_match) wav_matches=wav_matches+1;
        if(core.pcm_push) pcm_frames=pcm_frames+1;
        if(expect_companion_clear) begin
            if(!core.wav_ring_clear) $fatal(1,"outgoing companion did not clear audio");
            companion_stops=companion_stops+1;
        end
        expect_companion_clear=present && core.paired_track_active && !core.em_block;
        if(!arbitration_test && (source_failed || core.ctl_ext_load_rejected || diag!=15))
            $fatal(1,"image switch failed");
    end
    task frame;input integer cluster;begin
        wait(req);if(core.bmp_file_first_cluster!=cluster)$fatal(1,"wrong BMP cluster");
        @(negedge clk);words=0;ack=1;@(negedge clk);ack=0;
        wait(source_ok);if(words!=24)$fatal(1,"incomplete image words=%0d",words);
        wait(core.state_code==7);@(negedge clk);finish=~finish;
        wait(core.display_valid && core.img_idle);frames=frames+1;
        @(negedge clk);present=1;@(negedge clk);present=0;
        wait(core.sub_match_pending);wait(!core.sub_busy && !core.em_history_hold);
        repeat(5)@(negedge clk);
    end endtask
    initial begin
        force core.u_fat_bmp_controller.bmp_width=16'd8;
        force core.u_fat_bmp_controller.bmp_height=16'd4;
        repeat(5)@(negedge clk);rst=0;
        // Enable TXT matching too, so the second pass must retain both
        // descriptors while WAV map/header requests share the FAT walker.
        @(negedge clk);force core.sub_auto_toggle=1;
        @(negedge clk);release core.sub_auto_toggle;
        if(REAL_CARD) begin
            force core.overlay_failed=1'b1;
            frame(6);
            wait(!core.sub_busy && !core.em_history_hold && !core.u_subtitle.dirty);
            @(negedge clk);
            if(CARD_TARGET_CLUSTER==0) force core.kp_next=1;
            else begin
                force core.br_ext_cluster=CARD_TARGET_CLUSTER;
                force core.br_ext_size=32'd2764854;
                force core.br_ext_load_req=1;
            end
            @(negedge clk);release core.kp_next;release core.br_ext_load_req;
            wait(req);
            if(CARD_TARGET_CLUSTER==0) begin
                if(core.bmp_file_first_cluster!=7 || core.bmp_file_size!=12288054) $fatal(1,"actual card next-image descriptor");
            end else if(core.bmp_file_first_cluster!=CARD_TARGET_CLUSTER || core.bmp_file_size!=2764854) $fatal(1,"actual card browser descriptor");
            $display("*** PASS *** actual F: FAT32 capture: TEST.BMP presented, TXT matched, target BMP header and geometry accepted: cluster=%0d",core.bmp_file_first_cluster);$finish;
        end
        frame(3);
        @(negedge clk);force core.kp_next=1;@(negedge clk);release core.kp_next;
        frame(4);
        // A browser request uses img_idle after its own directory scan. The
        // test drives that interface directly, so wait for the subtitle
        // snapshot copy as well as the completed directory/file operation.
        wait(!core.sub_busy && !core.em_history_hold && !core.u_subtitle.dirty);
        @(negedge clk);force core.br_ext_cluster=32'd3;force core.br_ext_size=32'd150;force core.br_ext_load_req=1;
        @(negedge clk);release core.br_ext_load_req;
        frame(3);
        release core.br_ext_cluster;release core.br_ext_size;
        if(matches!=3)$fatal(1,"companion scans not completed");
        if(COMPANIONS && (wav_matches!=3 || pcm_frames==0))$fatal(1,"paired WAV path not exercised");
        if(COMPANIONS && companion_stops!=2)$fatal(1,"outgoing companion was not stopped on each switch");
        if(COMPANIONS) begin
            wait(core.paired_track_active && core.wav_ring_push);
            @(negedge clk);keypad_valid=1;keypad_data=6'd10;
            #1;if(!core.kp_stop) $fatal(1,"physical 9 not routed to stop");
            @(negedge clk);keypad_valid=0;
            if(!core.pcm_clear || core.wav_ext_play_req || core.paired_track_active || core.background_valid)
                $fatal(1,"exit did not clear PCM/companion/background");
            wait(core.wav_play_idle);repeat(8) @(negedge clk);
            if(core.wav_ring_push || core.pair_repeat_req || core.audio_next_pending || core.wav_pause_sd)
                $fatal(1,"exit left active audio controls");
            // A late lookup for the exited picture must not restart audio.
            force core.sub_match_done=1;force core.sub_wav_match=1;
            @(negedge clk);release core.sub_match_done;release core.sub_wav_match;
            repeat(8) @(negedge clk);
            if(core.pair_pending || core.wav_ext_play_req || !core.wav_play_idle)
                $fatal(1,"late companion lookup restarted exited audio");
            // A new picture enables its companion again.
            present=1;@(negedge clk);present=0;
            force core.sub_match_done=1;force core.sub_wav_match=1;
            @(negedge clk);release core.sub_match_done;release core.sub_wav_match;
            wait(core.paired_track_active && core.wav_ring_push);
            // Exit also clears a paused transport; a later 5 cannot resume it.
            @(negedge clk);force core.kp_pause=1;
            @(negedge clk);release core.kp_pause;
            if(!core.wav_pause_sd) $fatal(1,"pause setup failed");
            @(negedge clk);keypad_valid=1;keypad_data=6'd10;
            #1;if(!core.kp_stop) $fatal(1,"paused exit ignored");
            @(negedge clk);keypad_valid=0;
            wait(core.wav_play_idle);repeat(8) @(negedge clk);
            if(core.wav_pause_sd || core.paired_track_active) $fatal(1,"paused exit retained state");
            $display("physical 9 exits playing/paused companions; late lookup blocked; new picture can play");
        end
        // Exercise the arbitration with a live background track and delayed
        // feedback from a previous epoch. No old position may be captured.
        @(negedge clk);arbitration_test=1;rst=1;repeat(3) @(negedge clk);rst=0;
        force core.em_block=0;force core.em_audio_context_busy=0;
        force core.br_ext_play_req=0;force core.wpl_ext_play_req=0;force core.wav_next_req=0;
        force core.wav_ext_play_rejected=0;force core.wav_play_idle=0;
        force core.wav_payload_frames=32'd10000;force core.played_position=32'd1234;
        force core.wav_current_cluster=32'd50;force core.wav_current_size=32'd8000;
        force core.audio_epoch=32'd7;force core.audio_file_epoch=32'd7;
        force core.audio_dispatch_epoch=32'd7;force core.audio_dispatch_valid=1;
        force core.audio_consumed_epoch=32'd6;force core.wav_pause_sd=1;
        force core.sub_wav_cluster=32'd60;force core.sub_wav_size=32'd4000;
        force core.sub_match_done=1;force core.sub_wav_match=1;
        @(negedge clk);force core.sub_match_done=0;force core.sub_wav_match=0;
        repeat(4) @(negedge clk);
        if(!core.pair_pending || core.background_valid) $fatal(1,"accepted stale background epoch");
        force core.audio_consumed_epoch=32'd7;
        @(negedge clk);
        if(!core.background_valid || core.background_cluster!=50 || core.background_position!=1234 || !core.background_pause || !core.paired_track_active)
            $fatal(1,"background context was not saved");
        present=1;#1;
        if(!core.background_restore || !core.wav_ext_play_req || core.wav_ext_play_cluster!=50 || core.wav_ext_play_size!=8000 || !core.u_audio_transport.i_restore_value)
            $fatal(1,"background restore request missing");
        @(negedge clk);present=0;
        if(core.u_fat_wav_controller.seek_target!=1234 || !core.u_fat_wav_controller.seek_target_valid)
            $fatal(1,"background position was not passed to WAV controller");
        // A second companion retains the file but snapshots its newer position.
        force core.played_position=32'd1600;
        force core.sub_wav_cluster=32'd61;force core.sub_match_done=1;force core.sub_wav_match=1;
        @(negedge clk);force core.sub_match_done=0;force core.sub_wav_match=0;
        repeat(2) @(negedge clk);
        if(!core.paired_track_active || core.background_cluster!=50 || core.background_position!=1600)
            $fatal(1,"consecutive companion replaced background context");
        present=1;#1;if(!core.background_restore || core.wav_ext_play_cluster!=50) $fatal(1,"second restore missing");
        @(negedge clk);present=0;
        force core.sub_match_done=1;force core.sub_wav_match=0;
        @(negedge clk);force core.sub_match_done=0;
        if(core.background_valid) $fatal(1,"background context not retired after unpaired picture");
        // With no background, the outgoing companion must never become the
        // background merely because its final feedback is still in flight.
        force core.wav_play_idle=1;force core.wav_payload_frames=0;
        force core.sub_match_done=1;force core.sub_wav_match=1;
        @(negedge clk);force core.sub_match_done=0;force core.sub_wav_match=0;
        repeat(2) @(negedge clk);
        if(!core.paired_track_active || core.background_valid) $fatal(1,"unexpected initial background");
        present=1;@(negedge clk);present=0;
        force core.wav_play_idle=0;force core.wav_payload_frames=32'd10000;
        force core.sub_match_done=1;force core.sub_wav_match=1;
        @(negedge clk);force core.sub_match_done=0;force core.sub_wav_match=0;
        repeat(2) @(negedge clk);
        if(!core.paired_track_active || core.background_valid) $fatal(1,"outgoing companion captured as background");
        $display("*** PASS *** production media_core: first image, next key and browser request after companion scans: %0d frames, %0d WAV matches, %0d PCM frames",frames,wav_matches,pcm_frames);$finish;
    end
    initial begin #5000000;
        $display("watchdog frame=%0d bmp=%0d sub=%0d hold=%b req=%b",frames,core.state_code,core.u_subtitle.state,core.u_fat_bmp_controller.storage_hold,req);
        $fatal(1,"image switch watchdog");end
endmodule
