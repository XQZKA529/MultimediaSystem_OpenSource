`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_media_sd_boot #(parameter COMPLETE=0,parameter WATCHDOG_NS=0,parameter MONITOR_NS=0);
    reg clk=0,rst=1,link_up=0;
    always #5 clk=~clk;
    wire req,ack,finish,credit,pixel_credit,iv,source_ok,source_failed;
    wire [31:0] iw;
    wire sdclk;wire sdcmd;
    wire [3:0] diag;
    wire mv,dv,last,seam_rx_meta_ready;wire [7:0] ch,op;wire [31:0] obj,off,data;wire [15:0] len;
    reg rmv=0;reg [31:0] reply_id=0;reg [7:0] reply_opcode=`DB_IMG_READY;
    wire init_done,init_error;
    media_core core(.keypad_valid(1'b0),.keypad_data(6'd0),.keypad_cancel(1'b0),.brightness_mode(2'd0),
        .clk(clk),.rst(rst),.link_up(link_up),.remote_playing(1'b0),
        .render_image_transport_idle(1'b1),.overlay_burst_ready(1'b1),
        .KEY2(1'b1),.KEY3(1'b1),.KEY4(1'b1),
        .SD_CLK(sdclk),.SD_CMD(sdcmd),.SD_DAT0(1'b1),.SD_DAT1(1'b1),.SD_DAT2(1'b1),.SD_DAT3(1'b1),
        .image_req(req),.image_ack(ack),.image_finish_toggle(finish),.image_burst_ready(credit),.image_pixel_ready(pixel_credit),
        .image_word_valid(iv),.image_word(iw),.image_source_ok(source_ok),.image_source_failed(source_failed),.image_replay(1'b0),
        .pcm_burst_ready(1'b0),.seek_execute(1'b0),.resume_request(1'b0),.played_position(32'd0),
        .diag(diag),.DBG_SD_INIT_DONE(init_done),.DBG_SD_INIT_ERROR(init_error));
    seam_media seam(.saturation_level(5'd10),.ui_page(4'd0),.transition_mode(2'd0),.volume_level(5'd20),.volume_changed(1'b0),.volume_hint(1'b0),.volume_revision(32'd0),.contrast_level(5'd10),.brightness_level(4'd10),
        .clk(clk),.rst(rst),.link_up(link_up),.session_reset(1'b0),
        .image_req(req),.image_ack(ack),.image_finish_toggle(finish),.image_burst_ready(credit),.image_pixel_ready(pixel_credit),
        .image_word_valid(iv),.image_word(iw),.image_source_ok(source_ok),.image_source_failed(source_failed),
        .pcm_push(1'b0),.pcm(32'd0),.pcm_clear(1'b0),.pcm_eof(1'b0),.pcm_total(32'd0),.pcm_base(32'd0),
        .pcm_stream_toggle(1'b0),.paused(1'b0),.seek_request(1'b0),
        .subtitle_valid(1'b0),.subtitle_revision(32'd0),.subtitle_word(32'd0),.subtitle_word_valid(1'b0),
        .ui_wr_en(1'b0),.ui_wr_addr(9'd0),.ui_wr_data(8'd0),.text_osd_page(1'b0),.ui_active(1'b0),.ui_cursor_en(1'b0),.ui_cursor_row(4'd0),.ui_commit_toggle(1'b0),.diag(diag),
        .rx_meta_valid(rmv),.rx_meta_ready(seam_rx_meta_ready),.rx_required(1'b1),.rx_channel(8'd0),.rx_opcode(reply_opcode),.rx_object(reply_id),.rx_offset(32'd0),.rx_length(16'd0),
        .rx_valid(1'b0),.rx_data(32'd0),.rx_last(1'b0),
        .tx_meta_valid(mv),.tx_meta_ready(1'b1),.tx_channel(ch),.tx_opcode(op),.tx_object(obj),.tx_offset(off),.tx_length(len),
        .tx_valid(dv),.tx_ready(1'b1),.tx_data(data),.tx_last(last));
    integer statuses=0,words=0,begins=0,ends=0;
    reg eof_seen=0,success_seen=0;
    function [7:0] expected_byte;
        input integer b;
        integer pixel,channel;
        begin
            pixel=b/3;channel=b%3;
            expected_byte=(54+pixel*3+2-channel)&255;
        end
    endfunction
    function [31:0] expected_word;
        input integer n;
        begin expected_word={expected_byte(n*4),expected_byte(n*4+1),expected_byte(n*4+2),expected_byte(n*4+3)};end
    endfunction
    reg test_sd_error=0;reg [3:0] last_status=0;
    always @(posedge clk) if(!rst) begin
        if(mv && op==`DB_STATUS) begin statuses=statuses+1;last_status=off[3:0];end
        if(mv && op==`DB_IMG_BEGIN) begins=begins+1;
        if(mv && op==`DB_IMG_END) ends=ends+1;
        if(core.file_done && core.file_read_limit==0 && core.file_ok) eof_seen=1;
        if(source_ok) begin
            if(!eof_seen || words!=691200) $fatal(1,"early source success words=%0d eof=%b",words,eof_seen);
            success_seen=1;
        end
        if(iv) begin
            if(COMPLETE && iw!==expected_word(words)) $fatal(1,"word %0d got=%h expected=%h",words,iw,expected_word(words));
            words=words+1;
        end
        if(!test_sd_error && (source_failed || init_error)) begin
            $display("FAIL bmp_state=%d fat_state=%d fat_error=%d pipe_failed=%b wp=%d rp=%d scaler=%d sy=%d oy=%d words=%d",
                core.state_code,core.dbg_fat_state,core.fat_error_code,
                core.u_fat_bmp_controller.pipe_failed,
                core.u_fat_bmp_controller.pipeline.wp,core.u_fat_bmp_controller.pipeline.rp,
                core.u_fat_bmp_controller.pipeline.scaler.state,
                core.u_fat_bmp_controller.pipeline.scaler.sy,core.u_fat_bmp_controller.pipeline.scaler.oy,words);
            $fatal(1,"source/SD failed");
        end
        if(!link_up && (words!=0 || credit)) $fatal(1,"pixel read without remote credit");
    end
    initial begin
        #100;rst=0;
        // Initialization, FAT mount, directory and bounded header probe must
        // complete even with no render board. Pixel reads must wait for READY.
        wait(req);
        if(!init_done || core.bmp_catalog_count!=1 || core.state_code!=5 || words!=0)
            $fatal(1,"boot did not reach header-validated WAIT_WR");
        repeat(100) @(negedge clk);
        if(core.u_sd_card_sdio.file_reads!=1 || words!=0) $fatal(1,"uncredited full-file read");
        link_up=1;
        wait(mv && op==`DB_IMG_BEGIN);reply_id=obj;
        repeat(50) @(negedge clk);
        if(words!=0 || credit) $fatal(1,"image read before IMG_READY");
        rmv=1;wait(seam_rx_meta_ready);@(posedge clk);@(negedge clk);rmv=0;
        wait(words>=512);
        if(COMPLETE) begin
            wait(ends==1);
            if(!success_seen || !eof_seen || words!=691200) $fatal(1,"incomplete 720p transaction");
            wait(!dv);repeat(20) @(negedge clk);
            reply_opcode=`DB_IMG_PRESENTED;rmv=1;@(negedge clk);rmv=0;
            wait(core.display_valid);
            if(core.state_code!=3 || begins!=1 || diag!=15) $fatal(1,"bad final commit");
            $display("*** PASS *** actual media_core FAT+BMP+scaler+packer+seam: 720p 691200 exact words, 42 cluster transitions, EOF/END/PRESENTED");
            $finish;
        end
        if(statuses==0 || begins!=1 || diag!=15) $fatal(1,"missing status or bad image startup");
        // A failed card must also produce a STATUS; WAIT DATA is not a card
        // read state. Keep the network available while injecting init failure.
        @(negedge clk);rst=1;test_sd_error=1;
        force core.u_sd_card_sdio.sd_init_done=1'b0;
        force core.u_sd_card_sdio.sd_init_error=1'b1;
        force core.u_sd_card_sdio.sd_init_err_code=8'd7;
        repeat(5) @(negedge clk);rst=0;
        wait(last_status==7);
        if(diag!=7) $fatal(1,"SD failure was not reported to the peer");
        $display("*** PASS *** media SD boot: offline mount/catalog/header, IMG_READY credit starts pixels, failed SD still sends STATUS");$finish;
    end
    initial begin #((WATCHDOG_NS>0) ? WATCHDOG_NS : (COMPLETE ? 500000000:500000));
        $display("SD boot state: bmp=%d fat=%d limit=%d credit=%b sub_busy=%b emergency=%b begin_pending=%b seam_tx=%d req=%b ack=%b begins=%0d img=%b/%b ready_meta=%b match=%b id=%d reply=%d status=%0d",core.state_code,core.dbg_fat_state,core.file_read_limit,credit,core.sub_busy,core.em_block,seam.begin_image_pending,seam.tx_state,req,ack,begins,seam.image_active,seam.image_ready,seam.rx_meta_ready,seam.meta_image_match,seam.image_id,reply_id,statuses);
        $fatal(1,"SD boot deadlock");
    end

    initial if(MONITOR_NS>0) begin
        forever begin
            #(MONITOR_NS);
            $display("MON t=%0t words=%0d state=%0d fat=%0d wp=%0d rp=%0d credit=%b eof=%b reads=%0d file_done=%b file_ok=%b",
                $time,words,core.state_code,core.dbg_fat_state,
                core.u_fat_bmp_controller.pipeline.wp,core.u_fat_bmp_controller.pipeline.rp,
                core.u_fat_bmp_controller.pipeline.credit,core.u_fat_bmp_controller.pipeline.eof,
                core.u_sd_card_sdio.file_reads,core.file_done,core.file_ok);
            $fflush();
        end
    end
endmodule
