`timescale 1ns/1ps
`include "pkg/board_link.vh"
// Production WAV reader, both independent link implementations and render PCM
// sink. SD/FAT map and MAC byte transport are models; this does not simulate PHY
// electrical timing or HDMI serialization. PCM samples encode absolute frames.
// Scale sample/feedback and link timeouts to keep the test short, preserving
// 960 samples per POSITION interval, real FIFO sizes and the 240000-frame seek.
module tb_audio_system;
    parameter SCALE_BMP=0;
    parameter BMP_W=32,BMP_H=18;
    parameter SCENARIO=0;
    parameter MONO=0;
    reg hold_feedback=0;
    parameter FRAME_WORDS=128;
    reg clk=0,vc=0,t0=0,t1=0,rst=1,phy=1,vs=0;
    always #5 clk=~clk;always #6.667 vc=~vc;always #4 t0=~t0;always #4.01 t1=~t1;
    // Accelerated frame boundaries; full 720p timing is covered by tb_frame_read_dual.
    always begin #10000;vs=1;#100;vs=0;end
    wire up0,up1,s0,s1;
    wire [7:0] macd0,macd1,rd0,rd1;wire macv0,macv1,ma0,ma1,rv0,rv1,rg0,rg1;
    wire mt0,mr0,dt0,dr0,lt0,mt1,mr1,dt1,dr1,lt1;
    wire [7:0] ch0,op0,ch1,op1;wire [31:0] obj0,off0,d0,obj1,off1,d1;wire [15:0] len0,len1;
    wire rm0,rrm0,rvd0,rrd0,rl0,rq0,rm1,rrm1,rvd1,rrd1,rl1,rq1;
    wire [7:0] rch0,rop0,rch1,rop1;wire [31:0] robj0,roff0,rdata0,robj1,roff1,rdata1;wire [15:0] rlen0,rlen1;
    db_link #(.CLK_HZ(3000000)) a(.clk(clk),.rst(rst),.phy_ok(phy),.link_up(up0),.session_reset(s0),
        .tx_meta_valid(mt0),.tx_meta_ready(mr0),.tx_channel(ch0),.tx_opcode(op0),.tx_object(obj0),.tx_offset(off0),.tx_length(len0),
        .tx_valid(dt0),.tx_ready(dr0),.tx_data(d0),.tx_last(lt0),
        .rx_meta_valid(rm0),.rx_meta_ready(rrm0),.rx_required(rq0),.rx_channel(rch0),.rx_opcode(rop0),.rx_object(robj0),.rx_offset(roff0),.rx_length(rlen0),
        .rx_valid(rvd0),.rx_ready(rrd0),.rx_data(rdata0),.rx_last(rl0),
        .mac_tx_clk(t0),.mac_tx_data(macd0),.mac_tx_valid(macv0),.mac_tx_ack(ma0),
        .mac_rx_clk(t1),.mac_rx_data(rd0),.mac_rx_valid(rv0),.mac_rx_good(rg0),.mac_rx_bad(1'b0));
    db_link_render #(.CLK_HZ(3000000),.ROLE(2),.LOCAL_MAC(`DB_MAC_RENDER),.PEER_MAC(`DB_MAC_MEDIA)) b(
        .clk(clk),.rst(rst),.phy_ok(phy),.link_up(up1),.session_reset(s1),
        .tx_meta_valid(mt1 && !hold_feedback),.tx_meta_ready(mr1),.tx_channel(ch1),.tx_opcode(op1),.tx_object(obj1),.tx_offset(off1),.tx_length(len1),
        .tx_valid(dt1),.tx_ready(dr1),.tx_data(d1),.tx_last(lt1),
        .rx_meta_valid(rm1),.rx_meta_ready(rrm1),.rx_required(rq1),.rx_channel(rch1),.rx_opcode(rop1),.rx_object(robj1),.rx_offset(roff1),.rx_length(rlen1),
        .rx_valid(rvd1),.rx_ready(rrd1),.rx_data(rdata1),.rx_last(rl1),
        .mac_tx_clk(t1),.mac_tx_data(macd1),.mac_tx_valid(macv1),.mac_tx_ack(ma1),
        .mac_rx_clk(t0),.mac_rx_data(rd1),.mac_rx_valid(rv1),.mac_rx_good(rg1),.mac_rx_bad(1'b0));
    tb_mac_client_pipe p0(.clk(t0),.rst(rst),.din(macd0),.valid(macv0),.ack(ma0),.drop_next(1'b0),.corrupt_next(1'b0),.dout(rd1),.dv(rv1),.good(rg1));
    tb_mac_client_pipe p1(.clk(t1),.rst(rst),.din(macd1),.valid(macv1),.ack(ma1),.drop_next(1'b0),.corrupt_next(1'b0),.dout(rd0),.dv(rv0),.good(rg0));
    // 虚拟 WAV 文件
    //-------------------------------------------------------------------------
    localparam [31:0] PAYLOAD_BYTES = 480000*(MONO ? 2:4);
    localparam [31:0] FILE_BYTES    = 32'd44 + PAYLOAD_BYTES;
    localparam [31:0] BYTE_RATE=48000*(MONO ? 2:4);

    reg [7:0] hdr [0:43];
    initial begin
        hdr[ 0]="R"; hdr[ 1]="I"; hdr[ 2]="F"; hdr[ 3]="F";
        hdr[ 4]=(FILE_BYTES-8)%256;hdr[5]=((FILE_BYTES-8)>>8)%256;
        hdr[ 6]=((FILE_BYTES-8)>>16)%256;hdr[7]=((FILE_BYTES-8)>>24)%256;
        hdr[ 8]="W"; hdr[ 9]="A"; hdr[10]="V"; hdr[11]="E";
        hdr[12]="f"; hdr[13]="m"; hdr[14]="t"; hdr[15]=" ";
        hdr[16]=8'h10; hdr[17]=8'h00; hdr[18]=8'h00; hdr[19]=8'h00;
        hdr[20]=8'h01; hdr[21]=8'h00;
        hdr[22]=MONO ? 1:2; hdr[23]=8'h00;
        hdr[24]=8'h80; hdr[25]=8'hBB; hdr[26]=8'h00; hdr[27]=8'h00;
        hdr[28]=BYTE_RATE[7:0];hdr[29]=BYTE_RATE[15:8];hdr[30]=BYTE_RATE[23:16];hdr[31]=BYTE_RATE[31:24];
        hdr[32]=MONO ? 2:4; hdr[33]=8'h00;
        hdr[34]=8'h10; hdr[35]=8'h00;
        hdr[36]="d"; hdr[37]="a"; hdr[38]="t"; hdr[39]="a";
        hdr[40]=PAYLOAD_BYTES[7:0];hdr[41]=PAYLOAD_BYTES[15:8];hdr[42]=PAYLOAD_BYTES[23:16];hdr[43]=PAYLOAD_BYTES[31:24];
    end

    function [7:0] file_byte;
        input [31:0] off;
        begin
            if (off < 32'd44) file_byte = hdr[off[5:0]];
            else if(MONO) file_byte=(off-44)%2==0 ? ((off-44)/2)%256 : ((off-44)/2)/256;
            else case((off-44)%4)
                0:file_byte=((off-44)/4)%256;
                1:file_byte=((off-44)/4)/256;
                2:file_byte=~(((off-44)/4)%256);
                3:file_byte=~(((off-44)/4)/256);
            endcase
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
    wire        ext_seek_fwd;
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
    reg         bursting_delayed=0;
    always @(posedge clk) bursting_delayed<=!rst && bursting;
    wire        blk_data_valid = bursting_delayed;
    wire        blk_end        = burst_last;

    wire        ring_push, ring_clear, ring_flush;
    wire [31:0] ring_data;

    reg pause=0,seek_req=0,play_stop=0;
    wire pcm_credit,absolute_seek;
    wire [31:0] played_frames,stream_base;
    wire audio_ready,audio_begin,audio_stop,audio_eof,audio_pause,audio_freeze,audio_push,fb;
    wire [31:0] audio_epoch,audio_total,audio_base,audio_data,fb_epoch,fb_pos,pos,epoch;
    wire [2:0] fb_flags;
    wire [3:0] diag;
    wire playing,av;wire [23:0] left,right;
    // The overlap test needs idle slots in the audio-priority link scheduler.
    // Both modes remain accelerated; do not make virtual PCM saturate the MAC.
    db_audio_sink #(.PIX_HZ(SCALE_BMP ? 1920000:480000)) audio(
        .clk(clk),.rst(rst),.video_clk(vc),.video_rst(rst),.link_up(up1),
        .begin_stream(audio_begin),.stream_id(audio_epoch),.total_frames(audio_total),.base_frame(audio_base),
        .initial_pause(audio_pause),.stop(audio_stop),.paused(audio_pause),.frozen(audio_freeze),
        .eof(audio_eof),.push(audio_push),.pcm(audio_data),.packet_ready(audio_ready),
        .epoch_v(epoch),.position_v(pos),.playing_v(playing),.audio_valid(av),.audio_left(left),.audio_right(right),
        .feedback(fb),.feedback_epoch(fb_epoch),.feedback_position(fb_pos),.feedback_flags(fb_flags));
    integer heard=0,resets=0,seeks=0,begins=0;
    reg guard=0;
    reg [31:0] frozen_pos,target,old_epoch,saved;
    always @(posedge clk) if(!rst) begin
        if(guard && (s0 || s1)) begin
            resets=resets+1;
            $display("RESET t=%0t up=%b%b sent=%0d played=%0d ring=%0d rxop=%h ready=%b srcstate=%d",$time,up0,up1,source.audio_sent,played_frames,audio.buffered,rop1,rrm1,dut.state);
            $fatal(1,"audio control caused session reset");
        end
        if(ext_seek_fwd) begin seeks=seeks+1;frozen_pos=played_frames;end
        if(audio_begin) begins=begins+1;
        if(guard && source.had_audio && source.audio_sent>=played_frames && source.audio_sent-played_frames>1536)
            $fatal(1,"remote PCM reservation exceeded 1536-frame window");
    end
    // Match samples at the HDMI PCM output against the absolute played frame,
    // not merely the requested file offset or displayed progress.
    always @(posedge vc) if(!rst && audio.played) begin
        if(left!=={pos[15:0],8'd0} || right!==(MONO ? {pos[15:0],8'd0}:{~pos[15:0],8'd0}))
            $fatal(1,"wrong actual PCM at frame %0d: %h/%h",pos,left,right);
        heard=heard+1;
    end
    fat_wav_controller #(.EXTERNAL_POSITION(1)) dut (
        .clk(clk), .rst(rst),
        .ext_play_req(ext_play_req), .ext_play_cluster(ext_play_cluster),
        .ext_play_size(ext_play_size),
        .ext_play_ack(ext_play_ack), .ext_play_rejected(ext_play_rejected),
        .play_stop(play_stop), .play_busy(play_busy), .play_idle(play_idle),
        .play_status(play_status),
        .map_start(map_start), .map_first_cluster(map_first_cluster),
        .map_size(map_size), .map_abort(map_abort),
        .map_busy(map_busy), .map_done(map_done), .map_ok(map_ok),
        .str_start(str_start), .str_file_off(str_file_off), .str_len(str_len),
        .str_abort(str_abort), .str_ready(str_ready),
        .str_data(str_data), .str_data_valid(str_data_valid),
        .str_done(str_done), .str_ok(str_ok), .str_error(str_error),
        .str_busy(str_busy),
        .ring_push(ring_push), .ring_data(ring_data), .ring_ready(pcm_credit),
        .ring_clear(ring_clear), .ring_flush(ring_flush),
        .o_payload_frames(o_payload_frames),
        .o_stream_is_seek(o_stream_is_seek),
        .o_stream_toggle(o_stream_toggle),
        .ext_seek_fwd(ext_seek_fwd), .o_pos_frames(o_pos_frames),
        .i_played_frames(played_frames),.absolute_seek(absolute_seek),.absolute_target(played_frames),.o_stream_base(stream_base)
    );

    lba_stream #(.CHANNEL(1), .MAX_BURST(1)) u_str (
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
            blk_data   <= file_byte((cur_lba_r>=5000 ? 2000+cur_lba_r-5000 : cur_lba_r-1000)*512 + byte_off);

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

    reg req=0,iv=0,success=0,uw=0,uc=0;reg [31:0] word=0;reg [8:0] ua=0;reg [7:0] ud=0;
    wire ack,finish,credit,overflow;
    wire bmp_req,bmp_iv,bmp_success,bmp_failed,pixel_credit;wire [31:0] bmp_word;
    reg [31:0] bmp_expected[0:BMP_W*BMP_H*3/4-1];
    generate if(SCALE_BMP) begin: real_bmp
        tb_bmp_network_source #(.TARGET_W(BMP_W),.TARGET_H(BMP_H)) bmp(.clk(clk),.rst(rst),.launch(req),.ack(ack),.finish(finish),
            .pixel_ready(pixel_credit),.req(bmp_req),.word_valid(bmp_iv),
            .success(bmp_success),.failed(bmp_failed),.word(bmp_word));
        initial $readmemh("network_expected.hex",bmp_expected);
    end endgenerate
    seam_media #(.FRAME_WORDS(FRAME_WORDS)) source(.saturation_level(5'd10),.ui_page(4'd0),.transition_mode(2'd0),.subtitle_valid(1'b0),.volume_level(5'd20),.volume_changed(1'b0),.volume_hint(1'b0),.volume_revision(32'd0),.contrast_level(5'd10),
        .clk(clk),.rst(rst),.link_up(up0),.session_reset(s0),.image_req(SCALE_BMP ? bmp_req:req),.image_ack(ack),.image_finish_toggle(finish),
        .image_word_valid(SCALE_BMP ? bmp_iv:iv),.image_word(SCALE_BMP ? bmp_word:word),.image_source_ok(SCALE_BMP ? bmp_success:success),.image_source_failed(SCALE_BMP && bmp_failed),.image_burst_ready(credit),.image_pixel_ready(pixel_credit),
        .pcm_push(ring_push),.pcm(ring_data),.pcm_clear(ring_clear),.pcm_eof(ring_flush),
        .pcm_total(o_payload_frames),.pcm_base(stream_base),.pcm_stream_toggle(o_stream_toggle),
        .paused(pause),.seek_request(seek_req),.seek_execute(ext_seek_fwd),.played_position(played_frames),
        .resume_request(absolute_seek),.pcm_burst_ready(pcm_credit),
        .brightness_level(4'd10),.ui_wr_en(uw),.ui_wr_addr(ua),.ui_wr_data(ud),.text_osd_page(1'b0),.ui_active(1'b1),.ui_cursor_en(1'b1),.ui_cursor_row(4'd2),.ui_commit_toggle(uc),.diag(4'd15),
        .rx_meta_valid(rm0),.rx_meta_ready(rrm0),.rx_required(rq0),.rx_channel(rch0),.rx_opcode(rop0),.rx_object(robj0),.rx_offset(roff0),.rx_length(rlen0),
        .rx_valid(rvd0),.rx_ready(rrd0),.rx_data(rdata0),.rx_last(rl0),
        .tx_meta_valid(mt0),.tx_meta_ready(mr0),.tx_channel(ch0),.tx_opcode(op0),.tx_object(obj0),.tx_offset(off0),.tx_length(len0),
        .tx_valid(dt0),.tx_ready(dr0),.tx_data(d0),.tx_last(lt0),.overflow(overflow));
    wire wr,ab,we,valid,uiwe,uitoggle;wire [31:0] wd;wire [1:0] wi,di;wire [8:0] uiaddr;wire [7:0] uichar;
    reg wack=0,aack=0,wdone=0,uiack=0;
    wire rhandoff;wire [1:0] rselected;
    wire t_req,t_ack,t_done,t_fail;wire [1:0] t_new,t_cur;
    tb_transition_model transition(.clk(vc),.rst(rst),.vs(vs),.req(t_req),.new_idx(t_new),.cur_idx(t_cur),
        .ack(t_ack),.done(t_done),.failed(t_fail),.selected(rselected),.handoff(rhandoff));
    seam_render #(.FRAME_WORDS(FRAME_WORDS)) sink(.keypad_valid(1'b0),.keypad_data(6'd0),.brightness_mode(2'd0),
        .clk(clk),.rst(rst),.link_up(up1),.session_reset(s1),.video_clk(vc),.video_rst(rst),.vs(vs),
        .rx_meta_valid(rm1),.rx_meta_ready(rrm1),.rx_required(rq1),.rx_channel(rch1),.rx_opcode(rop1),.rx_object(robj1),.rx_offset(roff1),.rx_length(rlen1),
        .rx_valid(rvd1),.rx_ready(rrd1),.rx_data(rdata1),.rx_last(rl1),
        .tx_meta_valid(mt1),.tx_meta_ready(mr1 && !hold_feedback),.tx_channel(ch1),.tx_opcode(op1),.tx_object(obj1),.tx_offset(off1),.tx_length(len1),
        .tx_valid(dt1),.tx_ready(dr1),.tx_data(d1),.tx_last(lt1),
        .write_req(wr),.write_req_ack(wack),.write_abort(ab),.write_abort_ack(aack),.write_en(we),.write_data(wd),
        .write_full(1'b0),.write_sector_ready(1'b1),.write_finish_toggle(wdone),.read_selected_index(rselected),.read_handoff_toggle(rhandoff),
        .transition_req(t_req),.transition_new_index(t_new),.transition_cur_index(t_cur),
        .transition_ack(t_ack),.transition_done(t_done),.transition_failed(t_fail),
        .write_index(wi),.display_index(di),.display_valid(valid),.ui_wr_en(uiwe),.ui_wr_addr(uiaddr),.ui_wr_data(uichar),.ui_commit_toggle(uitoggle),.ui_commit_seen(uiack),
        .audio_packet_ready(audio_ready),.audio_feedback(fb),.feedback_epoch(fb_epoch),.feedback_position(fb_pos),.feedback_flags(fb_flags),
        .audio_begin(audio_begin),.audio_stop(audio_stop),.audio_eof(audio_eof),.audio_pause(audio_pause),.audio_freeze(audio_freeze),
        .audio_epoch(audio_epoch),.audio_total(audio_total),.audio_base(audio_base),.audio_push(audio_push),.audio_data(audio_data),.diag(diag));
    // SDRAM DMA timing model, not a physical SDRAM model. Delay the last-write
    // and old-read completion to exercise both business completion barriers.
    integer writes=0,uichars=0,done_delay=0,read_delay=0;
    always @(posedge clk) begin
        if(rst) begin wack<=0;aack<=0;end
        else begin
            wack<=wr;aack<=ab;
            if(overflow) $fatal(1,"image/PCM source FIFO overflow");
            if(we) begin
                if(wd!==(SCALE_BMP ? bmp_expected[writes]:writes)) $fatal(1,"network image loss/order");writes=writes+1;
                if(writes%131072==0) $display("image words %0d / %0d",writes,FRAME_WORDS);
                if(writes==FRAME_WORDS) done_delay=64;
            end
            if(done_delay>0) begin done_delay=done_delay-1;if(done_delay==0) wdone<=~wdone;end

            if(uiwe) begin
                if(uiaddr!=uichars || uichar!==(uichars%256)) $fatal(1,"network UI snapshot");uichars=uichars+1;
            end
            if(vs) uiack<=uitoggle;
            if(valid && (writes!=FRAME_WORDS || done_delay!=0)) $fatal(1,"early image display");
        end
    end
    integer i;
    reg [31:0] image_audio_start;
    integer heard_at_stop,begins_at_stop;
    task exit_audio;begin
        @(negedge clk);play_stop=1;
        @(negedge clk);play_stop=0;
        wait(audio_stop);wait(play_idle && !playing);
        repeat(40) @(posedge vc);
        heard_at_stop=heard;begins_at_stop=begins;
        repeat(150000) @(posedge clk);
        if(heard!=heard_at_stop || begins!=begins_at_stop || source.had_audio || source.remote_playing || source.seek_wait ||
           !valid || diag!=15 || resets!=0 || audio.buffered!=0)
            $fatal(1,"exit retained PCM, playing/seek state, or changed picture/session");
    end endtask
    initial begin
        ext_play_req=0;ext_play_cluster=0;ext_play_size=0;
        #100;rst=0;wait(up0 && up1);repeat(20) @(posedge clk);
        if(SCALE_BMP) begin
            guard=1;
            @(negedge clk);ext_play_req=1;ext_play_cluster=777;ext_play_size=FILE_BYTES;
            @(negedge clk);ext_play_req=0;wait(ext_play_ack);wait(pos>=3000);
            image_audio_start=pos;
        end
        for(i=0;i<288;i=i+1) begin @(negedge clk);uw=1;ua=i;ud=i;end
        @(negedge clk);uw=0;uc=~uc;req=1;wait(ack);@(negedge clk);req=0;repeat(10) @(posedge clk);
        if(!SCALE_BMP) begin
        for(i=0;i<FRAME_WORDS;i=i+1) begin
            if(i%512==0) begin @(negedge clk);iv=0;wait(credit);end
            @(negedge clk);iv=1;word=i;
        end
        @(negedge clk);iv=0;success=1;
        end
        wait(finish);
        if(writes!=FRAME_WORDS || uichars!=288 || !valid || di!=0 || rselected!=di) $fatal(1,"incomplete business completion");
        if(SCALE_BMP && pos<=image_audio_start) $fatal(1,"PCM did not advance during BMP scaling/transport");
        if(SCALE_BMP) $display("BMP overlap PCM advanced from %0d to %0d",image_audio_start,pos);

        guard=1;
        if(!SCALE_BMP) begin
        @(negedge clk);ext_play_req=1;ext_play_cluster=777;ext_play_size=FILE_BYTES;
        @(negedge clk);ext_play_req=0;wait(ext_play_ack);wait(pos>=3000);
        end
        if(SCENARIO==0) begin
            @(negedge clk);pause=1;wait(audio_pause);repeat(40) @(posedge vc);saved=pos;
            repeat(150000) @(posedge clk);
            if(pos!=saved || !playing || !valid || diag!=15 || sink.ui_commit_toggle!=uc)
                $fatal(1,"pause corrupted position, picture, UI or diagnostic");
            @(negedge clk);pause=0;wait(pos>=saved+2000);
            $display("pause/resume stable for > transport retry budget");
        end
        if(SCENARIO==2) begin
            @(negedge clk);hold_feedback=1;
            wait(mt1 && op1==`DB_PCM_POSITION);
        end
        @(negedge clk);seek_req=1;old_epoch=epoch;
        @(negedge clk);seek_req=0;
        if(SCENARIO==2) begin
            wait(audio_freeze);repeat(21000) @(posedge vc);
            @(negedge clk);hold_feedback=0;
        end
        wait(seeks==1);target=frozen_pos+240000;if(target>432000)target=432000;
        wait(epoch!=old_epoch && playing);wait(pos>=target+2000);
        if(stream_base!=target || seeks!=1 || resets!=0 || !valid || diag!=15)
            $fatal(1,"seek rebase base=%0d target=%0d frozen=%0d seeks=%0d resets=%0d valid=%b diag=%0d",stream_base,target,frozen_pos,seeks,resets,valid,diag);
        // Also seek while paused, then resume at the rebased sample.
        @(negedge clk);pause=1;wait(audio_pause);repeat(40) @(posedge vc);
        saved=pos;
        @(negedge clk);seek_req=1;old_epoch=epoch;
        @(negedge clk);seek_req=0;
        if(saved>=432000) begin
            // A full image can advance PCM enough that the first seek already
            // clamps to the tail guard. A further seek is explicitly rejected.
            wait(audio_freeze);wait(!source.seek_wait && !audio_freeze);
            repeat(150000) @(posedge clk);
            if(seeks!=1 || epoch!=old_epoch || pos!=saved || stream_base!=target ||
                !audio_pause || !valid || diag!=15)
                $fatal(1,"tail seek rejection changed paused stream or picture");
            @(negedge clk);pause=0;wait(pos>=saved+2000);
        end else begin
        wait(seeks==2);
        target=frozen_pos+240000;if(target>432000)target=432000;
        wait(epoch!=old_epoch && playing);repeat(150000) @(posedge clk);
        if(pos!=target || stream_base!=target || !audio_pause || !valid || diag!=15)
            $fatal(1,"paused seek lost pause or exact target");
        @(negedge clk);pause=0;wait(pos>=target+2000);
        end
        exit_audio;
        // Explicit selection after exit must start a fresh audible stream.
        @(negedge clk);ext_play_req=1;
        @(negedge clk);ext_play_req=0;
        wait(ext_play_ack);wait(playing && pos>=2000 && pos<10000);
        @(negedge clk);pause=1;wait(audio_pause);repeat(40) @(posedge vc);
        exit_audio;
        $display("*** PASS *** audio system scenario=%0d mono=%0d: SD/WAV -> both reliable links -> HDMI PCM; seek, paused tail clamp/resume, playing/paused exit and restart, stable picture/UI/session, bounded PCM window",SCENARIO,MONO);$finish;
    end
    initial begin #(SCALE_BMP && FRAME_WORDS>432 ? 500000000:10000000);
        $display("image request=%b bmp_request=%b ack=%b active=%b begin=%b ready=%b words=%0d pending_ui=%b",req,bmp_req,ack,source.image_active,source.begin_image_pending,source.image_ready,writes,source.ui_pending);
        $display("timeout seeks=%0d base=%0d position=%0d id=%0d source=%0d seekwait=%b freeze=%b ring=%0d",seeks,stream_base,pos,epoch,source.audio_id,source.seek_wait,audio_freeze,audio.buffered);
        $fatal(1,"audio system watchdog");end
endmodule
