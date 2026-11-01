`timescale 1ns/1ps
`include "pkg/board_link.vh"
// Diagnostic-only testbench: measures the media-side 720p BMP load with a
// cycle-accurate SD card model (command head + DAT byte rate + block tail).
// It is NOT part of the qualified evidence set; it exists to answer "where do
// the seconds in a board-measured image switch come from".
module tb_bmp_load_timing #(
    parameter integer FULL      = 1,
    parameter integer BYTE_CLKS = 4,    // 4-bit @25MHz on a 50MHz bus
    parameter integer HEAD_CLKS = 200,  // CMD17 + response + start token
    parameter integer LATENCY_CLKS = 0, // card read-access latency per burst
    parameter integer TAIL_CLKS = 36,   // CRC16 + end + inter-block gap
    parameter integer LINK_CLKS = 0,    // 0 = ideal link; N = 1 word / N clks
    parameter integer STOP_WORDS = 0,   // >0: stop after N words (rate probe)
    parameter integer WATCHDOG_NS = 0   // >0: override simulation watchdog
);
    reg clk=0,rst=1,link_up=0;
    always #10 clk=~clk;              // 50 MHz bus_clk (current build)

    wire req,ack,finish,credit,pixel_credit,iv,source_ok,source_failed;
    wire [31:0] iw;
    wire sdclk;wire sdcmd;
    wire [3:0] diag;
    wire mv,dv,last,seam_rx_meta_ready;wire [7:0] ch,op;wire [31:0] obj,off,data;wire [15:0] len;
    reg rmv=0;reg [31:0] reply_id=0;reg [7:0] reply_opcode=`DB_IMG_READY;
    wire init_done,init_error;

    // Link pacing: CRC path spends ~3 clk per byte => 12 clk per 32-bit word.
    reg [7:0] link_pace=0;
    always @(posedge clk) begin
        if(LINK_CLKS>1) begin
            if(link_pace==0) link_pace<=LINK_CLKS-1;
            else link_pace<=link_pace-1;
        end
    end
    wire seam_tx_ready=(LINK_CLKS>1) ? (link_pace==0) : 1'b1;

    media_core core(.keypad_valid(1'b0),.keypad_data(6'd0),.keypad_cancel(1'b0),.brightness_mode(2'd0),
        .clk(clk),.rst(rst),.link_up(link_up),.remote_playing(1'b0),
        .render_image_transport_idle(1'b1),.overlay_burst_ready(1'b1),
        .KEY2(1'b1),.KEY3(1'b1),.KEY4(1'b1),
        .SD_CLK(sdclk),.SD_CMD(sdcmd),.SD_DAT0(1'b1),.SD_DAT1(1'b1),.SD_DAT2(1'b1),.SD_DAT3(1'b1),
        .image_req(req),.image_ack(ack),.image_finish_toggle(finish),.image_burst_ready(credit),.image_pixel_ready(pixel_credit),
        .image_word_valid(iv),.image_word(iw),.image_source_ok(source_ok),.image_source_failed(source_failed),.image_replay(1'b0),
        .pcm_burst_ready(1'b0),.seek_execute(1'b0),.resume_request(1'b0),.played_position(32'd0),
        .diag(diag),.DBG_SD_INIT_DONE(init_done),.DBG_SD_INIT_ERROR(init_error));

    defparam core.u_sd_card_sdio.BYTE_CLKS = BYTE_CLKS;
    defparam core.u_sd_card_sdio.HEAD_CLKS = HEAD_CLKS;
    defparam core.u_sd_card_sdio.LATENCY_CLKS = LATENCY_CLKS;
    defparam core.u_sd_card_sdio.TAIL_CLKS = TAIL_CLKS;

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
        .tx_meta_valid(mv),.tx_meta_ready(seam_tx_ready),.tx_channel(ch),.tx_opcode(op),.tx_object(obj),.tx_offset(off),.tx_length(len),
        .tx_valid(dv),.tx_ready(seam_tx_ready),.tx_data(data),.tx_last(last));

    integer words=0,begins=0,ends=0;
    reg eof_seen=0,success_seen=0;
    time t_req=0,t_begin=0,t_ready=0,t_last=0,t_first_byte=0;
    reg ready_seen=0;
    reg [31:0] last_sector_count=0;
    localparam integer TARGET_WORDS = (STOP_WORDS>0) ? STOP_WORDS : (FULL ? 691200 : 512);

    always @(posedge clk) if(!rst) begin
        if(mv && op==`DB_IMG_BEGIN) begins=begins+1;
        if(mv && op==`DB_IMG_END) ends=ends+1;
        if(core.file_done && core.file_read_limit==0 && core.file_ok) eof_seen=1;
        if(source_ok) success_seen=1;
        if(ready_seen && core.file_data_valid && t_first_byte==0) t_first_byte=$time;
        if(iv) begin words=words+1;t_last=$time;end
    end

    initial begin
        #200;rst=0;
        wait(req);                    // header probe passed, BEGIN pending
        t_req=$time;
        repeat(100) @(negedge clk);
        link_up=1;
        wait(mv && op==`DB_IMG_BEGIN);
        reply_id=obj;t_begin=$time;
        repeat(50) @(negedge clk);
        // Render answers READY; the full-file read starts here.
        rmv=1;wait(seam_rx_meta_ready);@(posedge clk);@(negedge clk);rmv=0;
        t_ready=$time;ready_seen=1;
        wait(words>=TARGET_WORDS);
        if(FULL) wait(ends==1);
        repeat(20) @(negedge clk);
        $display("RESULT FULL=%0d BYTE_CLKS=%0d HEAD=%0d LAT=%0d TAIL=%0d LINK=%0d",FULL,BYTE_CLKS,HEAD_CLKS,LATENCY_CLKS,TAIL_CLKS,LINK_CLKS);
        $display("  words=%0d bytes_sd=%0d sectors=%0d",words,core.u_sd_card_sdio.bytes_served,core.u_sd_card_sdio.sectors_served);
        $display("  IMG_READY -> last word : %0d ns (%0d.%03d ms)", t_last-t_ready,(t_last-t_ready)/1000000,((t_last-t_ready)/1000)%1000);
        $display("  IMG_BEGIN -> last word : %0d ns", t_last-t_begin);
        $display("  request   -> last word : %0d ns", t_last-t_req);
        $display("  first byte after READY: %0d ns", (t_first_byte==0)?-1:(t_first_byte-t_ready));
        $display("  source_ok=%b eof=%b ends=%0d",source_ok,eof_seen,ends);
        if(FULL && !(success_seen && eof_seen && words==691200 && ends==1))
            $fatal(1,"incomplete 720p load");
        $display("*** PASS *** tb_bmp_load_timing");
        $finish;
    end

    initial begin
        #((WATCHDOG_NS>0) ? WATCHDOG_NS : (FULL ? 1_200_000_000 : 100_000_000));
        $display("TIMEOUT words=%0d state=%0d fat=%0d words_sd=%0d",words,core.state_code,core.dbg_fat_state,core.u_sd_card_sdio.bytes_served);
        $fatal(1,"load did not finish");
    end
endmodule
