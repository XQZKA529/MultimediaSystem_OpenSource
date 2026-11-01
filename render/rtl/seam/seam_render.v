`include "../pkg/board_link.vh"
`include "../pkg/video_bmp_params.vh"
module seam_render #(parameter FRAME_WORDS=`VBP_FRAME_WORDS,parameter CLK_HZ=100_000_000,
                     // Window for which a latched peer diagnostic is held across a
                     // re-handshake before falling back to WAIT DATA.  Parameter so a
                     // testbench can shrink it instead of simulating 500 ms of clock.
                     parameter DIAG_HOLD_CYCLES=CLK_HZ/2)(
    input wire clk,rst,link_up,session_reset,
    input wire emergency_block,emergency_request_valid,
    output wire emergency_request_ready,input wire [1:0] emergency_mode,
    input wire [31:0] emergency_revision,input wire [127:0] emergency_snapshot,
    output reg emergency_reply_valid,output reg [31:0] emergency_reply_revision,emergency_reply_epoch,
    output reg [7:0] emergency_reply_status,
    input wire emergency_picture_restored,emergency_restore_valid,
    input wire [1:0] emergency_restore_index,input wire [31:0] emergency_restore_id,
    output wire emergency_image_idle,
    output reg subtitle_start,output reg [31:0] subtitle_revision,input wire subtitle_start_ready,
    output wire subtitle_data_valid,output wire [31:0] subtitle_data,output wire subtitle_last,input wire subtitle_data_ready,
    input wire subtitle_applied,output wire subtitle_applied_ready,input wire [31:0] subtitle_applied_revision,input wire [1:0] subtitle_applied_result,
    output wire overlay_write_en,output wire [10:0] overlay_write_addr,output wire [31:0] overlay_write_data,
    output reg overlay_prepare_toggle,overlay_commit_toggle,input wire overlay_prepare_ack,overlay_commit_ack,
    output reg [31:0] display_image_id,
    input wire keypad_valid,input wire [5:0] keypad_data,output wire keypad_ready,
    input wire video_clk,video_rst,vs,
    input wire rx_meta_valid,output wire rx_meta_ready,
    input wire rx_required,
    input wire [7:0] rx_channel,rx_opcode,input wire [31:0] rx_object,rx_offset,
    input wire [15:0] rx_length,input wire rx_valid,output wire rx_ready,
    input wire [31:0] rx_data,input wire rx_last,
    output wire tx_meta_valid,input wire tx_meta_ready,
    output wire [7:0] tx_channel,tx_opcode,output wire [31:0] tx_object,tx_offset,
    output wire [15:0] tx_length,output wire tx_valid,input wire tx_ready,
    output wire [31:0] tx_data,output wire tx_last,
    output reg write_req,input wire write_req_ack,
    output reg write_abort,input wire write_abort_ack,
    output wire write_en,output wire [31:0] write_data,
    input wire write_full,write_sector_ready,write_finish_toggle,
    input wire [1:0] read_selected_index,input wire read_handoff_toggle,
    output reg [1:0] write_index,output reg [1:0] display_index,
    output reg display_valid,
    // ---- 交叉淡化事务邮箱（→ render_core 视频域事务控制器）----
    output reg transition_req,output reg [1:0] transition_new_index,transition_cur_index,transition_req_mode,
    output reg [1:0] transition_mode,
    input wire transition_ack,transition_done,transition_failed,
    output reg text_osd_page,ui_active,ui_cursor_en,ui_commit_toggle,
    output reg [3:0] ui_page,
    output reg [3:0] ui_cursor_row,output wire ui_wr_en,
    output wire [8:0] ui_wr_addr,output wire [7:0] ui_wr_data,
    output reg volume_valid,volume_hint,output reg [4:0] volume_level,
    output reg [4:0] contrast_level,output reg [4:0] saturation_level,input wire [1:0] brightness_mode,output reg [3:0] brightness_level,
    input wire ui_commit_seen,
    output wire [3:0] diag,
    output reg audio_begin,audio_stop,audio_eof,audio_pause,audio_freeze,
    output reg [31:0] audio_epoch,audio_total,audio_base,
    output wire audio_push,output wire [31:0] audio_data,input wire audio_packet_ready,
    input wire audio_feedback,input wire [31:0] feedback_epoch,feedback_position,
    input wire [2:0] feedback_flags
);
    `include "../link/db_crc.vh"
    // HELLO establishes the session before media sends its first STATUS.
    // Show a local waiting message instead of treating reset value 0 as an error.
    //
    // WAIT DATA (13) is a *power-on* message, not a per-session one.  A session
    // teardown is normally a transient (a single dropped frame at 1 Gbps is
    // enough to expire peer_age), and media re-sends STATUS on a 100ms refresh.
    // Latching the last known diag across a *brief* teardown keeps the on-screen
    // message truthful instead of flickering back to "WAIT DATA" every time the
    // link re-handshakes.  The latch is deliberately NOT permanent:
    //   * diag 13 (WAIT DATA) means "powered up, peer has never spoken to us".
    //     A new session must fall back to it, otherwise a stale 5 would sit on
    //     screen long after the peer went away.
    //   * a real link loss must surface as 14 (LINK DOWN), not as a frozen
    //     picture of the last error.
    // So: hold the latch only while the link is (re)establishing, and only if
    // the latched value is itself meaningful (not 13/14).
    reg [3:0] remote_diag;
    reg status_seen;
    reg diag_ever_seen;
    reg [$clog2(DIAG_HOLD_CYCLES+1)-1:0] diag_hold_age;
    reg status_refresh;
    wire diag_latched = diag_ever_seen && (remote_diag!=4'd13) && (remote_diag!=4'd14)
                        && (diag_hold_age<DIAG_HOLD_CYCLES);
    assign diag = status_seen ? remote_diag
                : diag_latched  ? remote_diag
                : diag_ever_seen ? (link_up ? 4'd13 : 4'd14)
                : 4'd13;
    function [31:0] crc_word;
        input [31:0] c,d;
        begin crc_word=db_crc_byte(db_crc_byte(db_crc_byte(db_crc_byte(c,d[31:24]),d[23:16]),d[15:8]),d[7:0]);end
    endfunction
    localparam I_IDLE=0,I_REQ=1,I_CLEAR=2,I_DATA=3,I_FINISH=4,I_PRESENT=5,I_ABORT=6,I_ABORT_CLEAR=7,I_VERIFY=8,I_TRANS=9;
    reg [3:0] image_state;
    assign emergency_image_idle=image_state==I_IDLE;
    reg [31:0] image_id,frame_crc;
    reg [$clog2(FRAME_WORDS+1)-1:0] word_count;
    reg verified,written,end_crc_ok;
    reg [$clog2(CLK_HZ+1)-1:0] idle_age;
    reg [$clog2(CLK_HZ*15+1)-1:0] total_age;
    reg [3:0] settle;
    (* async_reg="true" *) reg ack1,ack2,abort1,abort2,finish1,finish2,read1,read2;
    (* async_reg="true" *) reg [1:0] selected1,selected2;
    reg finish_seen,read_seen;
    reg commit_req;
    reg [1:0] commit_index;
    reg [31:0] commit_image_id;
    (* async_reg="true" *) reg [2:0] commit_sync;
    reg commit_seen,vs_d;
    (* async_reg="true" *) reg [2:0] commit_ack_sync;
    always @(posedge clk or posedge rst)
        if(rst) commit_ack_sync<=0;else commit_ack_sync<={commit_ack_sync[1:0],commit_seen};
    // ---- 切换事务（→ 视频域事务控制器）----
    // transition_req 保持到成功/失败，结果保持到请求撤销。
    (* async_reg="true" *) reg trans_ack1,trans_ack2;
    (* async_reg="true" *) reg trans_done1,trans_done2;
    (* async_reg="true" *) reg trans_fail1,trans_fail2;
    reg trans_ack_seen,trans_done_seen,trans_fail_seen;
    reg [1:0] trans_new_latch,trans_cur_latch;
    reg presented_pending,ready_pending,error_pending,feedback_pending;
    reg [31:0] presented_id,ready_id,error_id,error_code;
    reg [31:0] fb_id,fb_pos,fb_flags;
    reg [3:0] payload_kind;
    reg [31:0] packet_id;
    reg [1:0] em_tx_index,em_tx_mode;reg em_tx_pending;
    reg [127:0] em_tx_snapshot;
    reg [7:0] em_rx_status;
    reg [8:0] payload_words;
    reg [31:0] audio_first_word;
    reg [31:0] audio_receive_position;
    localparam O_IDLE=3'd0,O_HIDE=3'd1,O_DATA=3'd2,O_SHOW=3'd3,O_VERIFY=3'd4;
    reg [2:0] overlay_state;
    reg [31:0] overlay_id,overlay_crc;
    reg [11:0] overlay_count;
    reg overlay_end_ok;
    // Register accepted CRC words locally before the wide XOR network. The
    // feedback still consumes one word every clock; END waits for this stage.
    reg [31:0] crc_pipe_data;
    reg [3:0] crc_pipe_kind;
    reg [2:0] overlay_ack_sync,overlay_apply_sync;
    reg overlay_ready_pending,overlay_applied_pending;
    // Reuse an outstanding hide until video acknowledges it. Two bus-side
    // cancellations before VS must not toggle the request back and lose it.
    wire overlay_hide_request=(overlay_prepare_toggle==overlay_ack_sync[2]) ?
                              ~overlay_prepare_toggle:overlay_prepare_toggle;
    (* async_reg="true" *) reg [1:0] brightness_sync1,brightness_sync2;
    reg [1:0] brightness_seen;reg brightness_pending;
    reg ui_busy;
    reg [8:0] ui_address;
    reg [31:0] ui_word;
    reg [2:0] ui_bytes;
    reg ui_final;
    reg [31:0] ui_flags,ui_saturation;
    reg ui_emergency_closed,ui_emergency_seen;
    (* async_reg="true" *) reg ui_ack1,ui_ack2;
    reg meta_captured,meta_checked,image_data_ok,pcm_data_ok,checked_image_credit;
    reg image_begin_ok;
    reg [7:0] checked_opcode;
    reg [2:0] checked_channels;
    reg checked_img_begin,checked_ui,checked_sd_set,checked_overlay_begin,checked_overlay_data,checked_overlay_end,checked_overlay_abort;
    reg [15:0] checked_length;
    reg checked_required,checked_match,checked_volume,checked_subtitle;
    reg checked_ui_payload,checked_emergency_status;
    reg [31:0] checked_object,checked_offset;
    reg checked_overlay_match,checked_audio_match,checked_overlay_geometry;
    localparam IMAGE_END_W=($clog2(FRAME_WORDS+1)>14) ? $clog2(FRAME_WORDS+1)+1:15;
    reg [IMAGE_END_W-1:0] incoming_image_end;
    reg [31:0] incoming_pcm_end;
    reg [14:0] incoming_overlay_end;
    reg [18:0] checked_command;
    wire image_match=checked_object==image_id;
    wire overlay_match=checked_object==overlay_id;
    wire image_data_check=checked_channels[2] && checked_opcode==`DB_IMG_DATA && image_match &&
        image_state==I_DATA && checked_offset==word_count*4 && checked_length!=0 &&
        incoming_image_end<=FRAME_WORDS;
    wire pcm_data_check=checked_channels[1] && checked_opcode==`DB_PCM_DATA && checked_object==audio_epoch &&
        checked_offset==audio_receive_position && checked_length!=0 && incoming_pcm_end<=audio_total;
    wire overlay_data_check=checked_channels[2] && checked_opcode==`DB_OVL_DATA && overlay_match &&
        overlay_state==O_DATA && checked_offset==overlay_count*4 && checked_length!=0 &&
        incoming_overlay_end<=2048;
    // The link holds metadata until ready and serializes packets. Register
    // offset/range classification before it drives credits and application FSMs.
    always @(posedge clk or posedge rst) begin
        if(rst) begin checked_command<=0;incoming_image_end<=0;incoming_pcm_end<=0;incoming_overlay_end<=0;meta_captured<=0;meta_checked<=0;image_data_ok<=0;pcm_data_ok<=0;checked_image_credit<=0;image_begin_ok<=0;
            checked_opcode<=0;checked_channels<=0;checked_img_begin<=0;checked_ui<=0;checked_sd_set<=0;
            checked_overlay_begin<=0;checked_overlay_data<=0;checked_overlay_end<=0;checked_overlay_abort<=0;
            checked_length<=0;checked_required<=0;checked_match<=0;checked_volume<=0;checked_subtitle<=0;
            checked_ui_payload<=0;checked_emergency_status<=0;
            checked_object<=0;checked_offset<=0;checked_overlay_match<=0;checked_audio_match<=0;checked_overlay_geometry<=0;end
        else if(session_reset || !rx_meta_valid || (rx_meta_valid && rx_meta_ready)) begin meta_captured<=0;meta_checked<=0;end
        else if(payload_kind==0) begin
            // Stage 1: capture a stable header locally. Stage 2 performs range
            // arithmetic; stage 3 admits it. No payload is consumed early.
            meta_captured<=1;
            checked_opcode<=rx_opcode;checked_channels<={rx_channel==2,rx_channel==1,rx_channel==0};
            checked_length<=rx_length;checked_required<=rx_required;
            checked_object<=rx_object;checked_offset<=rx_offset;
            incoming_image_end<=word_count+(rx_length>>2);
            incoming_pcm_end<=audio_receive_position+(rx_length>>2);
            incoming_overlay_end<=overlay_count+(rx_length>>2);
            if(meta_captured) begin
                checked_command[0]<=checked_opcode==`DB_IMG_BEGIN;
                checked_command[1]<=checked_opcode==`DB_IMG_DATA;
                checked_command[2]<=checked_opcode==`DB_IMG_END;
                checked_command[3]<=checked_opcode==`DB_IMG_ABORT;
                checked_command[4]<=checked_opcode==`DB_OVL_BEGIN;
                checked_command[5]<=checked_opcode==`DB_OVL_DATA;
                checked_command[6]<=checked_opcode==`DB_OVL_END;
                checked_command[7]<=checked_opcode==`DB_OVL_ABORT;
                checked_command[8]<=checked_opcode==`DB_SD_SUBTITLE_SET;
                checked_command[9]<=checked_opcode==`DB_VOLUME_SET;
                checked_command[10]<=checked_opcode==`DB_EMERGENCY_STATUS;
                checked_command[11]<=checked_opcode==`DB_PCM_BEGIN;
                checked_command[12]<=checked_opcode==`DB_PCM_END;
                checked_command[13]<=checked_opcode==`DB_PCM_PAUSE;
                checked_command[14]<=checked_opcode==`DB_PCM_FREEZE;
                checked_command[15]<=checked_opcode==`DB_PCM_STOP;
                checked_command[16]<=checked_opcode==`DB_UI_SNAPSHOT;
                checked_command[17]<=checked_opcode==`DB_STATUS;
                checked_command[18]<=checked_opcode==`DB_ERROR;

            meta_checked<=1;image_data_ok<=image_data_check;pcm_data_ok<=pcm_data_check;
            // Only this serial receiver writes the image FIFO. During metadata
            // qualification no payload is being written; a one-cycle-old credit
            // can therefore account for at most the preceding packet's last word.
            // The existing 32-word admission headroom covers that word, while
            // write_full still gates every payload transfer independently.
            checked_image_credit<=write_sector_ready;
            image_begin_ok<=checked_length==0 && checked_offset==FRAME_WORDS && emergency_block!==1'b1;
            checked_img_begin<=checked_channels[2] && checked_opcode==`DB_IMG_BEGIN;
            checked_overlay_begin<=checked_channels[2] && checked_opcode==`DB_OVL_BEGIN;
            checked_overlay_data<=overlay_data_check;
            checked_overlay_end<=checked_channels[2] && checked_opcode==`DB_OVL_END && overlay_match && overlay_state==O_DATA && checked_length==4 && checked_offset==8192;
            checked_overlay_abort<=checked_channels[2] && checked_opcode==`DB_OVL_ABORT && overlay_match && checked_length==0;
            checked_ui<=checked_channels[0] && checked_opcode==`DB_UI_SNAPSHOT;
            checked_sd_set<=checked_channels[0] && checked_opcode==`DB_SD_SUBTITLE_SET;
            checked_match<=image_match;checked_volume<=checked_length==0 && checked_offset[31:6]==0 && checked_offset[4:0]<=20;
            checked_subtitle<=checked_length==264 && checked_offset==0;
            // Qualify offset/length before admission. Raw packet-header bits
            // must not traverse the payload-owner priority mux at acceptance.
            checked_ui_payload<=checked_length==296 && checked_offset==0;
            checked_emergency_status<=checked_length==4 && checked_offset[31:8]==0;
            checked_overlay_match<=overlay_match;checked_audio_match<=checked_object==audio_epoch;
            checked_overlay_geometry<=checked_length==0 && checked_offset==2048;
            end
        end
    end
    // One additional admission stage isolates wide error/control write enables
    // from payload ownership and the credit/UI/subtitle priority tree.
    reg meta_admitted;
    // Register acceptance before it drives wide application write enables.
    // Hold the first payload word for this one-cycle handoff; the link keeps
    // data stable under backpressure, including one-word/zero-length packets.
    reg meta_apply;
    always @(posedge clk or posedge rst)
        if(rst) meta_apply<=0;
        else if(session_reset) meta_apply<=0;
        else meta_apply<=rx_meta_valid && rx_meta_ready;

    always @(posedge clk or posedge rst) begin
        if(rst) begin overlay_ack_sync<=0;overlay_apply_sync<=0;end
        else begin overlay_ack_sync<={overlay_ack_sync[1:0],overlay_prepare_ack};overlay_apply_sync<={overlay_apply_sync[1:0],overlay_commit_ack};end
    end
    assign rx_meta_ready=meta_checked && meta_admitted &&
        !(pcm_data_ok && !audio_packet_ready) &&
        !(checked_sd_set && subtitle_start_ready===1'b0);
    wire admit_next=payload_kind==0 && image_state!=I_VERIFY && overlay_state!=O_VERIFY &&
        !(checked_img_begin && emergency_block!==1'b1 && (image_state!=I_IDLE || trans_ack2 || trans_done2 || trans_fail2)) &&
        !(checked_overlay_begin && (overlay_state!=O_IDLE || image_state!=I_IDLE || emergency_block===1'b1)) &&
        !(image_data_ok && !checked_image_credit) &&
        !(pcm_data_ok && !audio_packet_ready) &&
        !(checked_ui && ui_busy) &&
        !(checked_sd_set && subtitle_start_ready===1'b0);
    always @(posedge clk or posedge rst) begin
        if(rst) meta_admitted<=0;
        else if(session_reset || !rx_meta_valid || rx_meta_ready) meta_admitted<=0;
        else if(meta_checked) meta_admitted<=admit_next;
    end
    // Buffer the subtitle word and end marker together. The network's length
    // arithmetic must not feed the BRAM receiver's commit enables directly.
    reg subtitle_pending,subtitle_end;
    reg [31:0] subtitle_word;
    assign rx_ready=!meta_apply && ((payload_kind==1) ? !write_full : (payload_kind==4) ? ui_bytes==0 : (payload_kind==6) ? !subtitle_pending:1'b1);
    assign subtitle_data_valid=subtitle_pending;assign subtitle_data=subtitle_word;assign subtitle_last=subtitle_end;
    always @(posedge clk or posedge rst) begin
        if(rst) begin subtitle_pending<=0;subtitle_word<=0;subtitle_end<=0;end
        else if(session_reset) subtitle_pending<=0;
        else begin
            if(subtitle_pending && subtitle_data_ready) subtitle_pending<=0;
            if(rx_valid && rx_ready && payload_kind==6) begin
                subtitle_pending<=1;subtitle_word<=rx_data;subtitle_end<=rx_last;
            end
        end
    end
    assign write_en=rx_valid && rx_ready && payload_kind==1;
    assign write_data=rx_data;
    assign overlay_write_en=rx_valid && rx_ready && payload_kind==8 && overlay_state==O_DATA && link_up && !session_reset;
    assign overlay_write_addr={6'd63-overlay_count[10:5],overlay_count[4:0]};
    assign overlay_write_data=rx_data;
    assign audio_push=rx_valid && rx_ready && payload_kind==3;
    assign audio_data=rx_data;
    assign ui_wr_en=ui_bytes!=0;
    assign ui_wr_addr=ui_address;
    assign ui_wr_data=ui_word[31:24];
    // The video clock owns scanout selection. A held mailbox changes only at VS.
    always @(posedge video_clk or posedge video_rst) begin
        if(video_rst) begin commit_sync<=0;commit_seen<=0;vs_d<=0;display_index<=0;display_valid<=0;display_image_id<=0;end
        else begin
            commit_sync<={commit_sync[1:0],commit_req};vs_d<=vs;
            if(vs && !vs_d && commit_sync[2]!=commit_seen) begin
                display_index<=commit_index;display_valid<=1;display_image_id<=commit_image_id;commit_seen<=commit_sync[2];
            end
            // The mixer has already committed at VS and retired the reader.
            // Copy immediately, before the local controller releases the pin.
            if(emergency_picture_restored===1'b1) begin
                display_index<=emergency_restore_index;display_valid<=emergency_restore_valid;
                display_image_id<=emergency_restore_id;
            end
        end
    end
    reg [1:0] tx_state;
    assign keypad_ready=tx_state==0 && link_up && !session_reset && emergency_request_valid!==1'b1 && !em_tx_pending && !ready_pending && !presented_pending && !error_pending && subtitle_applied!==1'b1;
    assign subtitle_applied_ready=tx_state==0 && link_up && !session_reset && emergency_request_valid!==1'b1 && !em_tx_pending && !ready_pending && !presented_pending && !error_pending;
    reg [7:0] tx_op_r;
    reg [31:0] tx_obj_r,tx_off_r,tx_payload_r;
    reg [15:0] tx_len_r;
    assign tx_meta_valid=tx_state==1;assign tx_channel=0;assign tx_opcode=tx_op_r;
    assign tx_object=tx_obj_r;assign tx_offset=tx_off_r;assign tx_length=tx_len_r;
    assign tx_valid=tx_state==2;
    assign tx_data=tx_payload_r;
    assign tx_last=1;
    assign emergency_request_ready=tx_state==0 && link_up && !session_reset && !em_tx_pending;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            emergency_reply_valid<=0;emergency_reply_revision<=0;emergency_reply_epoch<=0;emergency_reply_status<=0;
            em_tx_index<=0;em_tx_mode<=0;em_tx_pending<=0;em_tx_snapshot<=0;em_rx_status<=0;
            subtitle_start<=0;subtitle_revision<=0;commit_image_id<=0;
            image_state<=I_IDLE;image_id<=0;word_count<=0;frame_crc<=32'hffffffff;
            verified<=0;written<=0;end_crc_ok<=0;idle_age<=0;total_age<=0;settle<=0;
            crc_pipe_kind<=0;crc_pipe_data<=0;
            write_req<=0;write_abort<=0;write_index<=0;
            ack1<=0;ack2<=0;abort1<=0;abort2<=0;finish1<=0;finish2<=0;
            finish_seen<=0;read1<=0;read2<=0;read_seen<=0;selected1<=0;selected2<=0;
            commit_req<=0;commit_index<=0;
            transition_req<=0;transition_new_index<=0;transition_cur_index<=0;transition_req_mode<=0;transition_mode<=0;
            trans_ack1<=0;trans_ack2<=0;trans_done1<=0;trans_done2<=0;
            trans_fail1<=0;trans_fail2<=0;
            trans_ack_seen<=0;trans_done_seen<=0;trans_fail_seen<=0;
            trans_new_latch<=0;trans_cur_latch<=0;
            presented_pending<=0;ready_pending<=0;error_pending<=0;feedback_pending<=0;
            presented_id<=0;ready_id<=0;error_id<=0;error_code<=0;
            fb_id<=0;fb_pos<=0;fb_flags<=0;payload_kind<=0;packet_id<=0;payload_words<=0;
            overlay_state<=O_IDLE;overlay_id<=0;overlay_crc<=32'hffffffff;overlay_count<=0;overlay_end_ok<=0;
            overlay_ready_pending<=0;overlay_applied_pending<=0;
            overlay_prepare_toggle<=0;overlay_commit_toggle<=0;
            volume_valid<=0;volume_hint<=0;volume_level<=20;contrast_level<=10;saturation_level<=10;brightness_level<=10;brightness_sync1<=0;brightness_sync2<=0;brightness_seen<=0;brightness_pending<=1;
            text_osd_page<=0;ui_active<=0;ui_cursor_en<=0;ui_cursor_row<=0;ui_page<=0;ui_commit_toggle<=0;
            ui_emergency_closed<=0;ui_emergency_seen<=0;
            ui_busy<=0;ui_address<=0;ui_word<=0;ui_bytes<=0;ui_final<=0;ui_flags<=0;ui_saturation<=0;ui_ack1<=0;ui_ack2<=0;
            remote_diag<=0;status_seen<=0;diag_ever_seen<=0;diag_hold_age<=0;status_refresh<=0;audio_begin<=0;audio_stop<=0;audio_eof<=0;audio_pause<=0;audio_freeze<=0;
            audio_epoch<=0;audio_total<=0;audio_base<=0;audio_first_word<=0;
            audio_receive_position<=0;
            tx_state<=0;tx_op_r<=0;tx_obj_r<=0;tx_off_r<=0;tx_len_r<=0;tx_payload_r<=0;
        end else begin
            emergency_reply_valid<=0;
            ack1<=write_req_ack;ack2<=ack1;abort1<=write_abort_ack;abort2<=abort1;
            finish1<=write_finish_toggle;finish2<=finish1;
            read1<=read_handoff_toggle;read2<=read1;selected1<=read_selected_index;selected2<=selected1;
            trans_ack1<=transition_ack;trans_ack2<=trans_ack1;
            trans_done1<=transition_done;trans_done2<=trans_done1;
            trans_fail1<=transition_failed;trans_fail2<=trans_fail1;
            brightness_sync1<=brightness_mode;brightness_sync2<=brightness_sync1;
            if(brightness_sync1==brightness_sync2 && brightness_sync2!=brightness_seen) begin
                brightness_seen<=brightness_sync2;brightness_pending<=1;
            end
            ui_ack1<=ui_commit_seen;ui_ack2<=ui_ack1;
            subtitle_start<=0;
            overlay_end_ok<=0;
            crc_pipe_kind<=0;
            if(rx_valid && rx_ready) begin
                crc_pipe_kind<=payload_kind;
                if(payload_kind==1 || payload_kind==2 || payload_kind==8 || payload_kind==9)
                    crc_pipe_data<=rx_data;
            end
            case(crc_pipe_kind)
                1:frame_crc<=crc_word(frame_crc,crc_pipe_data);
                2:end_crc_ok<=word_count==FRAME_WORDS && crc_pipe_data==~frame_crc;
                8:overlay_crc<=crc_word(overlay_crc,crc_pipe_data);
                9:overlay_end_ok<=overlay_count==2048 && crc_pipe_data==~overlay_crc;
                default:;
            endcase
            volume_valid<=0;
            audio_begin<=0;audio_stop<=0;audio_eof<=0;status_refresh<=0;
            if(image_state!=I_IDLE) begin
                if(idle_age<CLK_HZ) idle_age<=idle_age+1'b1;
                if(total_age<CLK_HZ*15) total_age<=total_age+1'b1;
            end
            else begin idle_age<=0;total_age<=0;end
            if(finish2!=finish_seen) begin
                finish_seen<=finish2;
                if(image_state==I_DATA || image_state==I_VERIFY || image_state==I_FINISH) written<=1;
            end
            if(read2!=read_seen) begin
                read_seen<=read2;
                // I_PRESENT 现在等待**新图**成为显示（事务控制器切换后 handoff
                // 会以新索引上报），旧图的 handoff 在动画期间不再触发 PRESENTED。

            end
            case(image_state)
                I_REQ:if(ack2) begin write_req<=0;image_state<=I_CLEAR;settle<=8;end
                I_CLEAR:if(!ack2) begin
                    if(settle!=0) settle<=settle-1'b1;
                    else begin image_state<=I_DATA;ready_pending<=1;ready_id<=image_id;idle_age<=0;end
                end
                I_VERIFY:if(crc_pipe_kind!=2) begin
                    if(end_crc_ok) begin verified<=1;image_state<=I_FINISH;end
                    else begin write_abort<=1;image_state<=I_ABORT;error_pending<=1;error_id<=image_id;error_code<=32'h1001;end
                end
                I_FINISH:if(verified && written) begin
                    // 发起交叉淡化事务：把新图缓存与当前显示缓存交给视频域控制器。
                    // display_index 由视频域在帧边界提交（见上方 video_clk 块）。
                    // 这里**不**直接写 display_index —— 那会造成双驱动
                    // （HDL-8007，seam_render 变黑盒、render 综合在 read_design 停住）。
                    commit_index<=write_index;commit_image_id<=image_id;
                    trans_new_latch<=write_index;
                    trans_cur_latch<=display_index;
                    transition_new_index<=write_index;
                    transition_cur_index<=display_index;
                    transition_req_mode<=transition_mode;
                    transition_req<=1;
                    image_state<=I_TRANS;
                end
                I_TRANS:begin
                    // Results are levels held until this request is withdrawn.
                    // done means the old reader has already retired safely.
                    if(trans_fail2) begin
                        transition_req<=0;
                        error_pending<=1;error_id<=image_id;error_code<=32'h1003;
                        image_state<=I_IDLE;
                    end else if(trans_done2) begin
                        transition_req<=0;commit_req<=~commit_req;
                        image_state<=I_PRESENT;
                    end
                end
                I_PRESENT:if(commit_ack_sync[2]==commit_req && selected2==commit_index) begin
                    presented_pending<=1;presented_id<=image_id;image_state<=I_IDLE;
                end
                I_ABORT:if(abort2) begin write_abort<=0;image_state<=I_ABORT_CLEAR;settle<=8;end
                I_ABORT_CLEAR:if(!abort2) begin
                    if(settle!=0) settle<=settle-1'b1;
                    else image_state<=I_IDLE;
                end
                default:;
            endcase
            if(overlay_state==O_HIDE && overlay_ack_sync[2]==overlay_prepare_toggle) begin
                overlay_state<=O_DATA;overlay_ready_pending<=1;
            end
            if(overlay_state==O_SHOW && overlay_apply_sync[2]==overlay_commit_toggle) begin
                overlay_state<=O_IDLE;overlay_applied_pending<=1;
            end
            if(overlay_state==O_VERIFY && crc_pipe_kind!=9) begin
                if(overlay_end_ok) begin
                    overlay_commit_toggle<=~overlay_commit_toggle;overlay_state<=O_SHOW;
                end else begin
                    overlay_prepare_toggle<=overlay_hide_request;overlay_state<=O_IDLE;
                    error_pending<=1;error_id<=overlay_id;error_code<=32'h1006;
                end
            end
            if(meta_apply && !session_reset) begin
                packet_id<=checked_object;payload_words<=0;payload_kind<=checked_length==0 ? 0:15;
                if(checked_channels[2]) begin
                    idle_age<=0;
                    case(1'b1)
                        checked_command[0]:if(image_begin_ok && emergency_block!==1'b1) begin
                            image_id<=checked_object;word_count<=0;frame_crc<=32'hffffffff;verified<=0;written<=0;
                            write_index<=display_valid ? (display_index==0 ? 1:0):0;
                            write_req<=1;image_state<=I_REQ;total_age<=0;
                        end else if(emergency_block===1'b1) begin
                            error_pending<=1;error_id<=checked_object;error_code<=32'h1004;
                        end
                        checked_command[1]:if(image_data_ok) payload_kind<=1;
                        checked_command[2]:if(checked_length==4 && checked_match && image_state==I_DATA) payload_kind<=2;
                        checked_command[3]:if(checked_match && image_state!=I_PRESENT) begin
                            write_req<=0;write_abort<=1;image_state<=I_ABORT;
                        end
                        checked_command[4]:if(checked_overlay_begin && checked_overlay_geometry && overlay_state==O_IDLE && image_state==I_IDLE && emergency_block!==1'b1) begin
                            overlay_id<=checked_object;overlay_count<=0;overlay_crc<=32'hffffffff;
                            overlay_ready_pending<=0;overlay_applied_pending<=0;
                            overlay_prepare_toggle<=overlay_hide_request;overlay_state<=O_HIDE;
                        end else begin error_pending<=1;error_id<=checked_object;error_code<=32'h1007;end
                        checked_command[5]:if(checked_overlay_data) payload_kind<=8;
                            else if(checked_overlay_match && overlay_state==O_DATA) begin
                                overlay_prepare_toggle<=overlay_hide_request;overlay_state<=O_IDLE;
                                error_pending<=1;error_id<=checked_object;error_code<=32'h1008;
                            end
                        checked_command[6]:if(checked_overlay_end) payload_kind<=9;
                            else if(checked_overlay_match && overlay_state==O_DATA) begin
                                overlay_prepare_toggle<=overlay_hide_request;overlay_state<=O_IDLE;
                                error_pending<=1;error_id<=checked_object;error_code<=32'h1008;
                            end
                        checked_command[7]:if(checked_overlay_abort) begin
                            overlay_prepare_toggle<=overlay_hide_request;overlay_state<=O_IDLE;overlay_count<=0;
                            overlay_ready_pending<=0;overlay_applied_pending<=0;
                        end
                        default:if(checked_required) begin error_pending<=1;error_id<=checked_object;error_code<=checked_opcode;end
                    endcase
                end else if(checked_channels[1] && pcm_data_ok) begin
                    if(checked_length!=0) payload_kind<=3;
                end else if(checked_channels[0]) begin
                    case(1'b1)
                        checked_command[8]:if(checked_subtitle) begin
                            subtitle_start<=1;subtitle_revision<=checked_object;payload_kind<=6;
                        end
                        checked_command[9]:if(checked_volume) begin
                            volume_valid<=1;volume_level<=checked_offset[4:0];volume_hint<=checked_offset[5];
                        end
                        checked_command[10]:if(checked_emergency_status) begin
                            payload_kind<=7;em_rx_status<=checked_offset[7:0];
                        end
                        checked_command[11]:if(checked_length==8) begin payload_kind<=5;audio_epoch<=checked_object;audio_base<=checked_offset;audio_receive_position<=checked_offset;end
                        checked_command[12]:if(checked_audio_match) audio_eof<=1;
                        checked_command[13]:if(checked_audio_match) begin audio_pause<=checked_offset[0];if(!checked_offset[1]) audio_freeze<=0;end
                        checked_command[14]:if(checked_audio_match) audio_freeze<=1;
                        checked_command[15]:begin audio_stop<=1;audio_epoch<=checked_object;audio_freeze<=0;end
                        checked_command[16]:if(checked_ui_payload) begin
                            payload_kind<=4;ui_busy<=1;ui_address<=0;
                        end
                        checked_command[17]:begin remote_diag<=checked_offset[3:0];status_seen<=1;diag_ever_seen<=1;status_refresh<=1;end
                        checked_command[18]:;
                        default:if(checked_required) begin error_pending<=1;error_id<=checked_object;error_code<=checked_opcode;end
                    endcase
                end else if(checked_required) begin error_pending<=1;error_id<=checked_object;error_code<=checked_opcode;end
            end
            if(rx_valid && rx_ready) begin
                payload_words<=payload_words+1'b1;
                case(payload_kind)
                    7:if(rx_last && payload_words==0) begin
                        emergency_reply_valid<=1;emergency_reply_revision<=packet_id;
                        emergency_reply_epoch<=rx_data;emergency_reply_status<=em_rx_status;
                    end
                    1:begin word_count<=word_count+1'b1;idle_age<=0;end
                    2:begin
                        // Register the received checksum comparison before
                        // it fans out to commit/abort/error transaction state.
                        image_state<=I_VERIFY;
                    end
                    3:audio_receive_position<=audio_receive_position+1'b1;
                    8:begin overlay_count<=overlay_count+1'b1;end
                    9:begin
                        // Match the main image's checksum/commit split. A RAM
                        // output comparison must not drive all error-ID bits.
                        overlay_state<=O_VERIFY;
                    end
                    4:if(payload_words==0) ui_flags<=rx_data;
                      else if(payload_words==1) ui_saturation<=rx_data;
                      else begin ui_word<=rx_data;ui_bytes<=4;ui_final<=rx_last;end
                    5:if(payload_words==0) audio_first_word<=rx_data;
                      else begin audio_total<=audio_first_word;audio_pause<=rx_data[0];audio_freeze<=0;audio_begin<=1;end
                    default:;
                endcase
                if(rx_last && payload_kind==4 && payload_words<2) ui_busy<=0;
                if(rx_last) payload_kind<=0;
            end
            if(ui_bytes!=0) begin
                ui_bytes<=ui_bytes-1'b1;ui_address<=ui_address+1'b1;ui_word<=ui_word<<8;
                if(ui_bytes==1 && ui_final && ui_address!=287) ui_busy<=0;
                if(ui_bytes==1 && ui_final && ui_address==287) begin
                    ui_commit_toggle<=~ui_commit_toggle;ui_active<=ui_flags[0] && !ui_emergency_closed;
                    text_osd_page<=ui_flags[0] && ui_flags[`DB_UI_LOCAL_PAGE] && !ui_emergency_closed;
                    if(!ui_flags[0]) ui_emergency_closed<=0;
                    ui_page<={ui_flags[`DB_UI_PAGE_EXT],ui_flags[`DB_UI_PAGE_MSB:`DB_UI_PAGE_LSB]};
                    transition_mode<=(ui_flags[24] && ui_flags[23:22]<=3) ? ui_flags[23:22]:2'd0;
                    contrast_level<=(ui_flags[21] && ui_flags[20:16]<=20) ? ui_flags[20:16]:5'd10;
                    saturation_level<=(ui_saturation[5] && ui_saturation[4:0]<=20) ? ui_saturation[4:0]:5'd10;
                    if (ui_flags[`DB_UI_VOLUME_MSB:`DB_UI_VOLUME_LSB] <= 5'd20)
                        volume_level<=ui_flags[`DB_UI_VOLUME_MSB:`DB_UI_VOLUME_LSB];
                    brightness_level<=(ui_flags[11:8]>=1 && ui_flags[11:8]<=10) ? ui_flags[11:8]:4'd10;
                    ui_cursor_en<=ui_flags[1];ui_cursor_row<=ui_flags[7:4];
                end
            end
            if(ui_busy && ui_bytes==0 && ui_address==288 && ui_ack2==ui_commit_toggle) ui_busy<=0;
            if(audio_feedback) begin
                fb_id<=feedback_epoch;fb_pos<=feedback_position;fb_flags<={29'd0,feedback_flags};feedback_pending<=1;
            end
            case(tx_state)
                0:if(link_up) begin
                    if(em_tx_pending) begin
                        case(em_tx_index)
                            1:tx_op_r<=`DB_EMERGENCY_EPOCH;
                            2:tx_op_r<=`DB_EMERGENCY_POSITION;
                            default:tx_op_r<=`DB_EMERGENCY_COMMIT;
                        endcase
                        tx_off_r<=em_tx_index==3 ? {26'd0,em_tx_mode,em_tx_snapshot[99:96]}:em_tx_snapshot[127:96];
                        tx_len_r<=0;tx_state<=1;
                    end else if(overlay_ready_pending) begin
                        tx_op_r<=`DB_OVL_READY;tx_obj_r<=overlay_id;tx_off_r<=0;tx_len_r<=0;tx_state<=1;overlay_ready_pending<=0;
                    end else if(overlay_applied_pending) begin
                        tx_op_r<=`DB_OVL_APPLIED;tx_obj_r<=overlay_id;tx_off_r<=0;tx_len_r<=0;tx_state<=1;overlay_applied_pending<=0;
                    end else if(emergency_request_valid===1'b1) begin
                        tx_op_r<=`DB_EMERGENCY_STATE;tx_obj_r<=emergency_revision;
                        tx_off_r<=emergency_snapshot[127:96];tx_len_r<=0;tx_state<=1;
                        em_tx_snapshot<=emergency_snapshot;em_tx_index<=0;em_tx_mode<=emergency_mode;em_tx_pending<=1;
                    end else if(ready_pending) begin tx_op_r<=`DB_IMG_READY;tx_obj_r<=ready_id;tx_off_r<=0;tx_len_r<=0;tx_state<=1;ready_pending<=0;end
                    else if(presented_pending) begin tx_op_r<=`DB_IMG_PRESENTED;tx_obj_r<=presented_id;tx_off_r<=0;tx_len_r<=0;tx_state<=1;presented_pending<=0;end
                    else if(error_pending) begin tx_op_r<=`DB_ERROR;tx_obj_r<=error_id;tx_off_r<=error_code;tx_len_r<=0;tx_state<=1;error_pending<=0;end
                    else if(subtitle_applied) begin tx_op_r<=`DB_SD_SUBTITLE_APPLIED;tx_obj_r<=subtitle_applied_revision;tx_off_r<={30'd0,subtitle_applied_result};tx_len_r<=0;tx_state<=1;end
                    else if(keypad_valid) begin tx_op_r<=`DB_KEYPAD_EVENT;tx_obj_r<=0;tx_off_r<={26'd0,keypad_data};tx_len_r<=0;tx_state<=1;end
                    else if(brightness_pending) begin tx_op_r<=`DB_BRIGHTNESS_STATUS;tx_obj_r<=0;tx_off_r<={30'd0,brightness_seen};tx_len_r<=0;tx_state<=1;brightness_pending<=0;end
                    else if(feedback_pending) begin
                        tx_op_r<=`DB_PCM_POSITION;tx_obj_r<=fb_id;tx_off_r<=fb_pos;tx_len_r<=4;
                        tx_payload_r<=fb_flags;tx_state<=1;feedback_pending<=0;
                    end
                end
                1:if(tx_meta_ready) begin
                    tx_state<=tx_len_r==0 ? 0:2;
                    if(em_tx_pending) begin
                        em_tx_snapshot<=em_tx_snapshot<<32;em_tx_index<=em_tx_index+1'b1;
                        if(em_tx_index==3) em_tx_pending<=0;
                    end
                end
                2:if(tx_ready) tx_state<=0;
                default:tx_state<=0;
            endcase
            if((idle_age>=CLK_HZ || total_age>=CLK_HZ*15) && image_state!=I_IDLE &&
                image_state!=I_ABORT && image_state!=I_ABORT_CLEAR && image_state!=I_PRESENT &&
                image_state!=I_TRANS) begin
                write_req<=0;write_abort<=1;image_state<=I_ABORT;
                error_pending<=1;error_id<=image_id;error_code<=32'h1002;
            end
            // Age the "last known status" latch.  Re-armed by every fresh
            // DB_STATUS (above), so it only expires when the peer really stops
            // talking.  While it is valid the screen keeps showing the peer's
            // last diagnostic instead of blinking back to WAIT DATA.
            if(status_refresh) diag_hold_age<=0;
            else if(diag_hold_age<DIAG_HOLD_CYCLES) diag_hold_age<=diag_hold_age+1'b1;
            // Close locally even without the peer. Ignore stale open snapshots
            // until media commits a closed menu; settings/text still commit.
            ui_emergency_seen<=emergency_block===1'b1;
            if(emergency_block===1'b1 && !ui_emergency_seen) ui_emergency_closed<=1;
            if(emergency_block===1'b1) begin ui_active<=0;text_osd_page<=0;ui_cursor_en<=0;end
            // Retire the partial overlay independently of preserved main-image
            // transitions. A new session must be able to BEGIN a fresh object.
            if(session_reset || !link_up) begin
                overlay_state<=O_IDLE;overlay_count<=0;overlay_end_ok<=0;
                overlay_ready_pending<=0;overlay_applied_pending<=0;
                if(session_reset || overlay_state!=O_IDLE)
                    overlay_prepare_toggle<=overlay_hide_request;
            end
            if(session_reset) begin
                em_tx_pending<=0;
                subtitle_start<=0;
                volume_valid<=0;volume_hint<=0;
                // Only re-arm the "waiting" state; the diag latch is bounded by
                // DIAG_HOLD_CYCLES, so a genuine link loss still falls through to
                // LINK DOWN while a quick re-handshake does not blank the screen.
                brightness_pending<=1;
                status_seen<=0;
                audio_stop<=1;audio_freeze<=0;tx_state<=0;payload_kind<=0;crc_pipe_kind<=0;
                ready_pending<=0;presented_pending<=0;error_pending<=0;feedback_pending<=0;
                // Keep committed UI/picture. Cancel partial objects without resetting scanout.
                ui_bytes<=0;ui_busy<=ui_commit_toggle!=ui_ack2;
                // ★ 已验证并开始的切换事务在断线时继续完成（不打断动画）：
                //   I_TRANS 保持；只有尚未进入动画的加载阶段才中止。
                if(image_state!=I_IDLE && image_state!=I_PRESENT && image_state!=I_TRANS) begin
                    write_req<=0;write_abort<=1;image_state<=I_ABORT;
                end
            end
        end
    end
endmodule
