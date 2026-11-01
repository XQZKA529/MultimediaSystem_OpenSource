`include "../pkg/board_link.vh"
`include "../pkg/video_bmp_params.vh"
module seam_media #(parameter FRAME_WORDS=`VBP_FRAME_WORDS)(
    input wire clk,rst,link_up,session_reset,
    output reg emergency_request_valid,output reg [1:0] emergency_request_mode,
    output reg [31:0] emergency_request_revision,output reg [127:0] emergency_request_snapshot,
    input wire emergency_reply_valid,output wire emergency_reply_ready,
    input wire [31:0] emergency_reply_revision,input wire [7:0] emergency_reply_status,
    output wire [31:0] audio_epoch,audio_file_epoch,audio_consumed_epoch,audio_dispatch_epoch,
    output reg audio_dispatch_valid,
    input wire subtitle_valid,output reg subtitle_ready,input wire [31:0] subtitle_revision,
    input wire subtitle_word_valid,output wire subtitle_word_ready,input wire [31:0] subtitle_word,
    output reg subtitle_applied,output reg [31:0] subtitle_applied_revision,output reg [1:0] subtitle_applied_result,
    output reg image_presented,output reg [31:0] presented_image_id,output wire image_transport_idle,
    input wire [4:0] volume_level,input wire volume_changed,volume_hint,input wire [31:0] volume_revision,
    input wire image_req,output reg image_ack,output reg image_finish_toggle,
    input wire image_word_valid,input wire [31:0] image_word,
    input wire image_source_ok,image_source_failed,output wire image_burst_ready,image_pixel_ready,
    input wire overlay_begin_req,output reg overlay_begin_ack,output reg overlay_begin_ready,output reg overlay_failed,
    input wire [31:0] overlay_begin_object,input wire overlay_abort_req,
    input wire overlay_word_valid,input wire [31:0] overlay_word,output wire overlay_word_ready,overlay_burst_ready,
    input wire overlay_source_ok,output reg overlay_applied,
    input wire pcm_push,input wire [31:0] pcm,input wire pcm_clear,pcm_eof,
    output wire pcm_burst_ready,input wire [31:0] pcm_total,pcm_base,
    input wire pcm_stream_toggle,paused,seek_request,
    output reg seek_execute,output reg [31:0] played_position,
    output reg resume_request,
    output reg remote_playing,
    output reg keypad_valid,output reg [5:0] keypad_data,
    input wire ui_wr_en,input wire [8:0] ui_wr_addr,input wire [7:0] ui_wr_data,
    input wire [4:0] contrast_level,input wire [4:0] saturation_level,input wire [3:0] brightness_level,output reg [1:0] brightness_mode,
    input wire [1:0] transition_mode,
    input wire text_osd_page,ui_active,ui_cursor_en,input wire [3:0] ui_cursor_row,input wire [3:0] ui_page,input wire ui_commit_toggle,
    input wire [3:0] diag,
    input wire rx_meta_valid,output wire rx_meta_ready,
    input wire rx_required,
    input wire [7:0] rx_channel,rx_opcode,input wire [31:0] rx_object,rx_offset,
    input wire [15:0] rx_length,input wire rx_valid,output wire rx_ready,
    input wire [31:0] rx_data,input wire rx_last,
    output wire tx_meta_valid,input wire tx_meta_ready,
    output wire [7:0] tx_channel,tx_opcode,output wire [31:0] tx_object,tx_offset,
    output wire [15:0] tx_length,output wire tx_valid,input wire tx_ready,
    output wire [31:0] tx_data,output wire tx_last,
    output wire overflow
);
    `include "../link/db_crc.vh"
    localparam IMAGE_BITS=$clog2(FRAME_WORDS+1);
    // IDs are opaque 32-bit wire fields. Local counters wrap at 24 bits;
    // sequence/session validation provides freshness, not the numeric ID alone.
    localparam ID_BITS=24;
    reg [ID_BITS-1:0] image_id;
    reg [31:0] image_crc;
    reg overlay_active,overlay_ready,overlay_req_seen,overlay_cancel;
    reg overlay_begin_pending,overlay_end_pending,overlay_end_queued,overlay_abort_pending;
    reg [31:0] overlay_id,overlay_abort_id,overlay_count,overlay_sent;
    reg crc_busy;
    reg [1:0] crc_phase;
    reg [31:0] crc_shift;
    reg [IMAGE_BITS-1:0] image_count,image_sent;
    reg image_active,image_ready,source_ok,begin_image_pending,end_image_pending,abort_image_pending;
    reg img_clear,img_cancel;
    reg image_req_seen,end_image_queued;
    // The SD reader may finish before the render transition and PRESENTED reply.
    assign image_transport_idle=!image_active && !overlay_active;
    reg [31:0] abort_image_id;
    wire [10:0] img_free,img_used;
    wire img_used_ge_256;
    wire img_valid,img_pop,img_over,overlay_pop;
    wire [31:0] img_data;
    wire image_push=image_word_valid && image_active;
    wire overlay_push=overlay_word_valid && overlay_active && overlay_ready && !overlay_cancel && img_used!=11'd1024;
    wire [31:0] stream_word=overlay_active ? overlay_word:image_word;
    db_stream_fifo #(.AW(10)) u_image(
        .clk(clk),.rst(rst),.clear(img_clear),.push(image_push || overlay_push),.din(stream_word),
        .free_words(img_free),.used_words(img_used),.used_ge_256(img_used_ge_256),
        .overflow(img_over),.valid(img_valid),.dout(img_data),.ready(img_pop || overlay_pop));
    // FAT samples this only BEFORE a non-preemptible <= 4-sector SD burst.
    assign image_burst_ready=link_up && image_ready && img_used<=11'd496;
    // Independent scaler/packer credit, including registered output in flight.
    assign image_pixel_ready=link_up && image_ready && img_used<=11'd1008;
    assign overlay_word_ready=link_up && overlay_active && overlay_ready && !overlay_cancel && img_used!=11'd1024;
    // FAT starts non-preemptible bursts of at most 4 * 512 source bytes.
    // Six BGR888 bytes produce one packed RGB565 word: ceil(2048/6)=342.
    // Include pending decoder words and control latency before reserving a burst.
    assign overlay_burst_ready=link_up && overlay_active && overlay_ready && !overlay_cancel && img_used<=11'd672;
    wire overlay_tx_ready=overlay_ready && img_valid && (img_used>=11'd256 || overlay_source_ok);
    reg [ID_BITS-1:0] audio_id;
    wire [ID_BITS-1:0] audio_next_id=audio_id+1'b1;
    reg [31:0] audio_sent,total_latched,base_latched;
    reg [31:0] audio_pending_id,audio_pending_total,audio_pending_base;
    reg audio_toggle_seen,pcm_cancel;
    wire audio_stream_changed=pcm_stream_toggle!=audio_toggle_seen;
    reg stop_pending,begin_audio_pending,end_audio_pending,pause_pending,freeze_pending;
    reg pause_seen,seek_wait,seek_issued,had_audio,reconnecting;
    reg audio_flush;
    // Link ACK confirms FIFO delivery, not playback. Count all queued, in-flight
    // and received PCM against the peer's actually played position. A 1536-frame
    // window stays below render's 1788-word admission limit, supports its 1024
    // prefill, and leaves 576 frames beyond each 20ms feedback interval (960).
    // Reserve a full 256-frame packet even when the available packet is short.
    // Two registered stages avoid adding subtract/compare to TX arbitration.
    // Leave two extra frames for audio_sent advancing during those two clocks.
    reg [31:0] pcm_ahead;
    reg pcm_window_open;
    // pcm_ahead 的减法曾直接进入 TX 仲裁链（pcm_ahead → seek_wait mux →
    // seek_execute → seek_issued），布线后 -0.094ns。把减法结果多寄存一拍
    // 再喂给仲裁：audio_sent/played_position 都是低频位置计数，1 拍延后
    // 对 1536 帧窗口的准入判断无影响。seek_wait 的清除条件同理延后一拍，
    // 但它只在 POSITION 反馈到达时置位，一拍差别仍在同一反馈周期内。
    reg [31:0] pcm_ahead_r;
    always @(posedge clk or posedge rst) begin
        if (rst) pcm_ahead_r <= 32'd0;
        else     pcm_ahead_r <= audio_sent - played_position;
    end
    wire [9:0] pcm_free,pcm_used;
    wire pcm_used_ge_256;
    wire pcm_valid,pcm_pop,pcm_over,pcm_empty;
    wire [31:0] pcm_data;
    db_stream_fifo #(.AW(9)) u_pcm(
        .clk(clk),.rst(rst),.clear(pcm_clear || audio_flush),.push(pcm_push),.din(pcm),
        .free_words(pcm_free),.used_words(pcm_used),.used_ge_256(pcm_used_ge_256),
        .overflow(pcm_over),.valid(pcm_valid),.dout(pcm_data),.ready(pcm_pop),.empty(pcm_empty));
    assign pcm_burst_ready=link_up && pcm_used<=10'd252 && !seek_wait;
    assign overflow=img_over || pcm_over;
    // Live browser page and a frozen outgoing snapshot are separate memories.
    reg [7:0] ui_live[0:511] /* fehdl force_ram=1, ram_style="bram" */;
    reg [31:0] ui_snapshot[0:127] /* fehdl force_ram=1, ram_style="bram" */;
    reg [7:0] ui_q;
    reg [31:0] ui_build,ui_flags;
    reg [ID_BITS-1:0] ui_revision;
    reg [8:0] copy_index;
    reg [2:0] copy_state;
    reg page_ready,ui_dirty,copy_dirty,ui_pending,ui_seen;
    reg [31:0] ui_controls_seen,ui_controls_frozen;
    reg [4:0] saturation_seen,saturation_frozen,saturation_snapshot,saturation_tx;
    wire [31:0] ui_controls={volume_level,1'b0,ui_page[3],1'b1,transition_mode,1'b1,contrast_level,ui_page[2:0],text_osd_page,brightness_level,ui_cursor_row,2'd0,ui_cursor_en,ui_active};
    reg [31:0] ui_send_q;
    reg [6:0] ui_read_word;
    always @(posedge clk) begin
        if(ui_wr_en) ui_live[ui_wr_addr]<=ui_wr_data;
        ui_q<=ui_live[copy_index];
        if(copy_state==2 && copy_index[1:0]==3)
            ui_snapshot[copy_index[8:2]]<={ui_build[23:0],ui_q};
        ui_send_q<=ui_snapshot[ui_read_word];
    end
    reg [3:0] tx_kind;
    reg tx_pcm_pause;
    reg [1:0] tx_state;
    reg [7:0] ch_r,op_r;
    reg [31:0] off_r,payload_r,ui_flags_r;
    wire [31:0] obj_r;
    reg [10:0] len_r;
    reg [8:0] tx_index,tx_words;
    reg [1:0] rx_kind;reg [1:0] emergency_rx_word;
    reg emergency_meta_checked,emergency_meta_admitted;
    wire emergency_metadata=rx_channel==0 && (rx_opcode==`DB_EMERGENCY_STATE ||
        rx_opcode==`DB_EMERGENCY_EPOCH || rx_opcode==`DB_EMERGENCY_POSITION || rx_opcode==`DB_EMERGENCY_COMMIT);
    // The producer holds a header until ready. Qualify the emergency revision
    // and format before enabling snapshot writes and cancellation fanout.
    always @(posedge clk or posedge rst) begin
        if(rst) begin emergency_meta_checked<=0;emergency_meta_admitted<=0;end
        else if(session_reset || !rx_meta_valid || rx_meta_ready) begin
            emergency_meta_checked<=0;emergency_meta_admitted<=0;
        end else if(emergency_metadata && rx_kind==0 && !emergency_meta_checked) begin
            emergency_meta_checked<=1;
            case(rx_opcode)
                `DB_EMERGENCY_STATE:emergency_meta_admitted<=rx_length==0;
                `DB_EMERGENCY_EPOCH:emergency_meta_admitted<=rx_length==0 && emergency_rx_word==1 && rx_object==emergency_request_revision;
                `DB_EMERGENCY_POSITION:emergency_meta_admitted<=rx_length==0 && emergency_rx_word==2 && rx_object==emergency_request_revision;
                default:emergency_meta_admitted<=rx_length==0 && emergency_rx_word==3 && rx_object==emergency_request_revision;
            endcase
        end
    end
    // The link retains the descriptor until ready. Classify its wide fields
    // before they enter the application update/priority trees.
    wire metadata_owner_change=(image_req===1'b1 && !image_req_seen) ||
        (overlay_begin_req===1'b1 && !overlay_req_seen && !image_active && !overlay_active);
    reg metadata_checked,meta_image_match,meta_overlay_match;
    reg meta_zero_length,meta_subtitle_ok,meta_keypad_ok;
    reg [7:0] meta_opcode;
    reg meta_control_channel;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            metadata_checked<=0;meta_image_match<=0;meta_overlay_match<=0;
            meta_zero_length<=0;meta_subtitle_ok<=0;meta_keypad_ok<=0;
            meta_opcode<=0;meta_control_channel<=0;
        end else if(session_reset || !rx_meta_valid || rx_meta_ready || metadata_owner_change) metadata_checked<=0;
        else if(rx_kind==0) begin
            metadata_checked<=1;
            meta_image_match<=rx_object==image_id;
            meta_overlay_match<=rx_object==overlay_id;
            meta_zero_length<=rx_length==0;
            meta_subtitle_ok<=rx_length==0 && rx_offset<=2;
            meta_keypad_ok<=rx_length==0 && rx_object==0 && rx_offset[31:6]==0;
            meta_opcode<=rx_opcode;meta_control_channel<=rx_channel==0;
        end
    end
    assign audio_epoch=audio_id;assign audio_file_epoch=audio_pending_id;
    reg [31:0] feedback_id,feedback_pos,feedback_confirmed_id;
    // Keep seek-wait updates out of the large media transaction state machine
    // below.  The old shared always block made this bit depend on a deep
    // priority mux spanning audio, emergency, RX and TX work.
    wire seek_request_accept=seek_request && had_audio && !seek_wait;
    // Compare feedback_pos+48000 against pcm_total without cascading a
    // 32-bit subtraction and comparator. The 34-bit signed difference covers
    // the entire unsigned input range; the original total guard is retained.
    wire [33:0] seek_tail_a={2'd0,feedback_pos};
    wire [33:0] seek_tail_b=~{2'd0,pcm_total};
    localparam [33:0] SEEK_TAIL_BIAS=34'd48001;
    wire [33:0] seek_tail_sum_bits=seek_tail_a ^ seek_tail_b ^ SEEK_TAIL_BIAS;
    wire [33:0] seek_tail_carry_bits=(seek_tail_a & seek_tail_b) |
        (seek_tail_a & SEEK_TAIL_BIAS) | (seek_tail_b & SEEK_TAIL_BIAS);
    wire [33:0] seek_tail_delta=
        seek_tail_sum_bits+{seek_tail_carry_bits[32:0],1'b0};
    wire seek_has_tail=pcm_total>=32'd96000 && seek_tail_delta[33];
    wire seek_feedback_reject=rx_valid && rx_last && rx_kind==1 &&
        feedback_id==audio_id && !pcm_clear && !audio_stream_changed &&
        seek_wait && !seek_issued && rx_data[2] &&
        !(seek_has_tail);
    wire seek_emergency_cancel=rx_meta_valid && rx_meta_ready && meta_control_channel &&
        meta_opcode==`DB_EMERGENCY_COMMIT && emergency_meta_admitted &&
        rx_offset[31:6]==0 && rx_offset[5:4]<=2;
    always @(posedge clk or posedge rst) begin
        if(rst) seek_wait<=0;
        else if(session_reset) seek_wait<=0;
        else if(pcm_clear || seek_feedback_reject || seek_emergency_cancel) seek_wait<=0;
        else if(seek_request_accept) seek_wait<=1;
        else if(audio_stream_changed) seek_wait<=0;
    end
    reg [3:0] diag_seen;
    reg status_pending;
    reg volume_pending,volume_pending_hint;
    // Periodic STATUS refresh.  The peer blanks its "remote status known" latch
    // on every session_reset, so a change-only trigger leaves it showing
    // WAIT DATA whenever a single STATUS fails to land (which is exactly what
    // happened: the boards flickered between LINK DOWN / WAIT DATA).  Re-sending
    // unconditionally about every 100 ms makes the peer's latch self-healing at
    // negligible cost (one 32-byte management frame per 100 ms).
    localparam STATUS_REFRESH_CYCLES = `VBP_SD_CLK_HZ/10;
    reg [$clog2(STATUS_REFRESH_CYCLES+1)-1:0] status_age;
    reg error_pending;
    reg [31:0] error_object,error_opcode;
    assign tx_meta_valid=tx_state==1;assign tx_channel=ch_r;assign tx_opcode=op_r;
    assign tx_object=obj_r;assign tx_offset=off_r;assign tx_length=len_r;
    wire tx_payload_phase=tx_state==2;
    assign tx_valid=tx_payload_phase &&
        ((tx_kind==1) ? ((img_valid || img_cancel) && !crc_busy) :
         (tx_kind==8) ? ((img_valid || overlay_cancel) && !crc_busy) :
         (tx_kind==2) ? (pcm_valid || pcm_cancel) : (tx_kind==6) ? subtitle_word_valid:1'b1);
    assign tx_data=tx_kind==1 ? (img_cancel ? 0:img_data):tx_kind==8 ? (overlay_cancel ? 0:img_data):tx_kind==2 ? (pcm_cancel ? 0:pcm_data):
        tx_kind==3 ? (tx_index==0 ? total_latched:{31'd0,tx_pcm_pause}):
        tx_kind==4 ? (tx_index==0 ? ui_flags_r:tx_index==1 ? {26'd0,1'b1,saturation_tx}:ui_send_q):tx_kind==6 ? subtitle_word:
        ((tx_kind==5 || tx_kind==9) ? ~image_crc:payload_r);
    assign subtitle_word_ready=tx_state==2 && tx_kind==6 && tx_ready;
    assign tx_last=(tx_index+1'b1==tx_words);
    assign img_pop=tx_valid && tx_ready && tx_kind==1 && !img_cancel;
    assign overlay_pop=tx_valid && tx_ready && tx_kind==8 && !overlay_cancel;
    assign pcm_pop=tx_valid && tx_ready && tx_kind==2 && !pcm_cancel;
    // Fold the exact ordered words accepted by the reliable packet framer.
    // Four cycles per word reuse one byte-CRC network instead of four cascades.
    // Local TX ready/valid provides backpressure; whole SD bursts still land
    // in the credited 4KB FIFO. END also waits for this final CRC to settle.
    always @(posedge clk or posedge rst) begin
        if(rst) begin image_crc<=32'hffffffff;crc_busy<=0;crc_phase<=0;crc_shift<=0;end
        else if(session_reset || (image_req && !image_req_seen) ||
                (overlay_begin_req && !overlay_req_seen && !image_active && !overlay_active)) begin
            image_crc<=32'hffffffff;crc_busy<=0;
        end else if(image_source_failed) crc_busy<=0;
        else if(overlay_abort_req) crc_busy<=0;
        else if(img_pop || overlay_pop) begin
            image_crc<=db_crc_byte(image_crc,img_data[31:24]);
            crc_shift<={img_data[23:0],8'd0};crc_busy<=1;crc_phase<=1;
        end else if(crc_busy) begin
            image_crc<=db_crc_byte(image_crc,crc_shift[31:24]);crc_shift<=crc_shift<<8;
            if(crc_phase==3) crc_busy<=0;else crc_phase<=crc_phase+1'b1;
        end
    end
    assign rx_meta_ready=metadata_checked && !metadata_owner_change && rx_kind==0 && (!emergency_metadata || emergency_meta_checked);assign rx_ready=1;
    // For UI synchronous RAM, each outgoing payload word gets a prefetch wait.
    reg [1:0] ui_wait;
    wire idle_can_send=tx_state==0 && link_up;
    // Mutually exclusive object sources share the existing packet priority.
    // Keep the wide object mux separate from the opcode/length priority chain.
    wire obj_emergency=emergency_reply_valid===1'b1;
    assign emergency_reply_ready=idle_can_send && obj_emergency && !session_reset;
    wire obj_volume=!obj_emergency && (volume_pending || volume_changed);
    wire obj_error=!obj_emergency && !obj_volume && error_pending;
    wire obj_audio_prefix=!obj_emergency && !obj_volume && !error_pending;
    wire obj_audio_begin=obj_audio_prefix && !stop_pending && !freeze_pending && begin_audio_pending;
    wire obj_audio_control=obj_audio_prefix &&
        (stop_pending || freeze_pending || (!begin_audio_pending && pause_pending));
    wire obj_control_tail=obj_audio_prefix && !stop_pending && !freeze_pending && !begin_audio_pending && !pause_pending && !status_pending;
    wire obj_subtitle=obj_control_tail && subtitle_valid;
    wire obj_ui=obj_control_tail && !subtitle_valid && ui_pending;
    wire obj_stream_tail=obj_control_tail && !subtitle_valid && !ui_pending;
    wire pcm_can_send=pcm_valid && had_audio && !begin_audio_pending && pcm_window_open && !seek_wait && !pcm_clear && !audio_stream_changed;
    wire pcm_can_end=end_audio_pending && pcm_empty;
    wire obj_audio_stream=obj_stream_tail && (pcm_can_send || pcm_can_end);
    wire obj_image_prefix=obj_stream_tail && !pcm_can_send && !pcm_can_end;
    wire obj_overlay=obj_image_prefix && (overlay_abort_pending || overlay_begin_pending ||
        overlay_tx_ready || overlay_end_pending);
    wire obj_image_abort=obj_image_prefix && !obj_overlay && abort_image_pending;
    wire obj_image=obj_image_prefix && !obj_overlay && !abort_image_pending &&
        (begin_image_pending || (image_ready && img_valid) || end_image_pending);
    // Keep the transmit offset mux separate from the opcode priority chain.
    // Commands without an explicit offset assignment use the per-packet zero.
    wire off_emergency=obj_emergency;
    wire off_volume=obj_volume;
    wire off_error=obj_error;
    wire off_audio_begin=obj_audio_begin;
    wire off_pause=obj_audio_control && !stop_pending && !freeze_pending &&
        !begin_audio_pending && pause_pending;
    wire off_status=!obj_emergency && !obj_volume && !error_pending &&
        !stop_pending && !freeze_pending && !begin_audio_pending &&
        !pause_pending && status_pending;
    wire off_pcm_data=obj_audio_stream && pcm_can_send;
    wire off_overlay_begin=obj_overlay && !overlay_abort_pending && overlay_begin_pending;
    wire off_overlay_data=obj_overlay && !overlay_abort_pending &&
        !overlay_begin_pending && overlay_tx_ready;
    wire off_overlay_end=obj_overlay && !overlay_abort_pending &&
        !overlay_begin_pending && !overlay_tx_ready && overlay_end_pending;
    wire off_image_begin=obj_image && begin_image_pending;
    wire off_image_data=obj_image && !begin_image_pending && image_ready && img_valid;
    wire [31:0] offset_next=
        ({32{off_emergency}} & {24'd0,emergency_reply_status}) |
        ({32{off_volume}} & {26'd0,(volume_changed ? volume_hint:volume_pending_hint),volume_level}) |
        ({32{off_error}} & error_opcode) |
        ({32{off_audio_begin}} & audio_pending_base) |
        ({32{off_pause}} & {31'd0,paused}) |
        ({32{off_status}} & {28'd0,diag}) |
        ({32{off_pcm_data}} & audio_sent) |
        ({32{off_overlay_begin}} & 32'd2048) |
        ({32{off_overlay_data}} & (overlay_sent*4)) |
        ({32{off_overlay_end}} & 32'd8192) |
        ({32{off_image_begin}} & FRAME_WORDS) |
        ({32{off_image_data}} & (image_sent*4));
    reg [31:0] selected_object,object_begin;
    // Publish the epoch only together with its accepted position, never on
    // receipt of the metadata word while the previous position is still live.
    assign audio_consumed_epoch=feedback_confirmed_id;assign audio_dispatch_epoch=object_begin;
    assign obj_r=selected_object;
    wire [31:0] next_object=
        ({32{obj_volume}} & volume_revision) |
        ({32{obj_error || obj_emergency}} & (obj_emergency ? emergency_reply_revision:error_object)) |
        ({32{obj_audio_begin}} & audio_pending_id) |
        ({32{obj_audio_control || obj_audio_stream}} & audio_id) |
        ({32{obj_subtitle}} & subtitle_revision) |
        ({32{obj_ui}} & ui_revision) |
        ({32{obj_overlay}} & (overlay_abort_pending ? overlay_abort_id:overlay_id)) |
        ({32{obj_image_abort}} & abort_image_id) |
        ({32{obj_image}} & image_id);
    always @(posedge clk or posedge rst) begin
        if(rst) begin selected_object<=0;object_begin<=0;end
        else if(idle_can_send) begin
            selected_object<=next_object;
            if(obj_audio_begin) object_begin<=audio_pending_id;
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) audio_dispatch_valid<=0;
        else if(session_reset) audio_dispatch_valid<=0;
        else if(idle_can_send && obj_audio_begin) audio_dispatch_valid<=1;
    end

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            emergency_request_valid<=0;emergency_request_mode<=0;emergency_request_revision<=0;
            emergency_request_snapshot<=0;emergency_rx_word<=0;
            subtitle_ready<=0;subtitle_applied<=0;subtitle_applied_revision<=0;subtitle_applied_result<=0;image_presented<=0;presented_image_id<=0;
            image_ack<=0;image_finish_toggle<=0;image_id<=0;image_count<=0;image_sent<=0;
            image_active<=0;image_ready<=0;source_ok<=0;begin_image_pending<=0;end_image_pending<=0;abort_image_pending<=0;
            overlay_active<=0;overlay_ready<=0;overlay_req_seen<=0;overlay_cancel<=0;
            overlay_begin_pending<=0;overlay_end_pending<=0;overlay_end_queued<=0;overlay_abort_pending<=0;
            overlay_id<=0;overlay_abort_id<=0;overlay_count<=0;overlay_sent<=0;
            overlay_begin_ack<=0;overlay_begin_ready<=0;overlay_applied<=0;overlay_failed<=0;
            img_clear<=0;img_cancel<=0;
            image_req_seen<=0;end_image_queued<=0;abort_image_id<=0;tx_pcm_pause<=0;
            audio_id<=0;audio_sent<=0;total_latched<=0;base_latched<=0;
            audio_pending_id<=0;audio_pending_total<=0;audio_pending_base<=0;
            audio_toggle_seen<=0;pcm_cancel<=0;stop_pending<=0;begin_audio_pending<=0;end_audio_pending<=0;
            pause_pending<=0;freeze_pending<=0;pause_seen<=0;seek_issued<=0;had_audio<=0;reconnecting<=0;audio_flush<=0;
            pcm_ahead<=0;pcm_window_open<=0;
            seek_execute<=0;played_position<=0;resume_request<=0;remote_playing<=0;keypad_valid<=0;keypad_data<=0;
            ui_build<=0;ui_flags<=0;ui_revision<=0;copy_index<=0;copy_state<=0;
            page_ready<=0;ui_dirty<=0;copy_dirty<=0;ui_pending<=0;ui_seen<=0;ui_controls_seen<=0;ui_controls_frozen<=0;saturation_seen<=10;saturation_frozen<=10;saturation_snapshot<=10;saturation_tx<=10;brightness_mode<=0;
            ui_read_word<=0;ui_flags_r<=0;ui_wait<=0;
            tx_kind<=0;tx_state<=0;ch_r<=0;op_r<=0;off_r<=0;payload_r<=0;
            len_r<=0;tx_index<=0;tx_words<=0;rx_kind<=0;feedback_id<=0;feedback_pos<=0;feedback_confirmed_id<=0;
            volume_pending<=1;volume_pending_hint<=0;diag_seen<=0;status_pending<=1;status_age<=0;
            error_pending<=0;error_object<=0;error_opcode<=0;
        end else begin
            if(tx_state==0 && idle_can_send) off_r<=offset_next;
            emergency_request_valid<=0;
            subtitle_ready<=0;subtitle_applied<=0;image_presented<=0;
            overlay_begin_ack<=0;overlay_begin_ready<=0;overlay_applied<=0;overlay_failed<=0;
            image_ack<=0;img_clear<=0;audio_flush<=0;seek_execute<=0;resume_request<=0;
            pcm_ahead<=pcm_ahead_r;
            pcm_window_open<=pcm_ahead_r<=32'd1278;
            if(volume_changed) begin volume_pending<=1;volume_pending_hint<=volume_hint;end
            if(!image_req) image_req_seen<=0;
            if(!overlay_begin_req) overlay_req_seen<=0;
            if(image_word_valid && image_active) begin
                image_count<=image_count+1'b1;
            end
            if(overlay_push) overlay_count<=overlay_count+1'b1;
            if(overlay_begin_req && !overlay_req_seen && !image_active && !overlay_active) begin
                overlay_req_seen<=1;overlay_begin_ack<=1;overlay_active<=1;overlay_ready<=0;
                overlay_id<=overlay_begin_object;overlay_count<=0;overlay_sent<=0;
                overlay_begin_pending<=1;overlay_end_pending<=0;overlay_end_queued<=0;overlay_abort_pending<=0;
                overlay_cancel<=0;img_clear<=1;
            end
            if(overlay_abort_req && overlay_active) begin
                overlay_abort_pending<=1;overlay_abort_id<=overlay_id;overlay_active<=0;
                overlay_ready<=0;overlay_cancel<=1;overlay_end_pending<=0;overlay_end_queued<=0;img_clear<=1;
            end
            if(overlay_source_ok && overlay_active && !overlay_end_queued && overlay_count==2048 && overlay_sent==2048 &&
               img_used==0 && !crc_busy) begin overlay_end_pending<=1;overlay_end_queued<=1;end
            if(image_source_ok && image_active) source_ok<=1;
            if(image_source_failed && image_active) begin
                abort_image_pending<=1;abort_image_id<=image_id;image_active<=0;image_ready<=0;img_cancel<=1;img_clear<=1;
            end
            if(image_req && !image_req_seen) begin
                image_req_seen<=1;end_image_queued<=0;
                // Retry requests arrive after the old request was lowered by the BMP core.
                if(image_active) begin abort_image_pending<=1;abort_image_id<=image_id;end
                image_id<=image_id+1'b1;image_count<=0;image_sent<=0;
                image_active<=1;image_ready<=0;source_ok<=0;begin_image_pending<=1;
                img_clear<=1;img_cancel<=tx_kind==1 && tx_state!=0;
            end
            if(source_ok && !crc_busy && !end_image_queued && image_count==FRAME_WORDS && image_sent==FRAME_WORDS && img_used==0) begin
                end_image_pending<=1;end_image_queued<=1;
            end
            if(pcm_clear) begin
                audio_id<=audio_id+1'b1;stop_pending<=1;pcm_cancel<=tx_kind==2 && tx_state!=0;
                begin_audio_pending<=0;end_audio_pending<=0;had_audio<=0;
                remote_playing<=0;freeze_pending<=0;
            end
            if(audio_stream_changed) begin
                audio_toggle_seen<=pcm_stream_toggle;begin_audio_pending<=1;had_audio<=1;
                audio_pending_id<=pcm_clear ? audio_next_id:audio_id;
                audio_pending_total<=pcm_total;audio_pending_base<=pcm_base;audio_sent<=pcm_base;
                played_position<=pcm_base;
                seek_issued<=0;
            end
            if(pcm_eof && !pcm_clear && !audio_stream_changed) end_audio_pending<=1;
            if(paused!=pause_seen) begin pause_seen<=paused;pause_pending<=1;end
            if(seek_request_accept) begin freeze_pending<=1;seek_issued<=0;end
            keypad_valid<=0;
            if(rx_meta_valid && rx_meta_ready) begin
                rx_kind<=meta_zero_length ? 0:2;
                if(meta_control_channel) case(meta_opcode)
                    `DB_IMG_READY:if(meta_image_match && image_active && !image_ready) begin image_ready<=1;image_ack<=1;img_cancel<=0;end
                    `DB_IMG_PRESENTED:if(meta_image_match && image_active) begin
                        image_presented<=1;presented_image_id<=rx_object;image_finish_toggle<=~image_finish_toggle;image_active<=0;image_ready<=0;source_ok<=0;end_image_pending<=0;
                    end
                    `DB_OVL_READY:if(meta_zero_length && meta_overlay_match && overlay_active) begin
                        overlay_ready<=1;overlay_begin_ready<=1;
                    end
                    `DB_OVL_APPLIED:if(meta_zero_length && meta_overlay_match && overlay_active) begin
                        overlay_applied<=1;overlay_active<=0;overlay_ready<=0;overlay_cancel<=0;overlay_end_queued<=0;
                    end
                    `DB_SD_SUBTITLE_APPLIED:if(meta_subtitle_ok) begin subtitle_applied<=1;subtitle_applied_revision<=rx_object;subtitle_applied_result<=rx_offset[1:0];end
                    `DB_KEYPAD_EVENT:if(meta_keypad_ok) begin keypad_valid<=1;keypad_data<=rx_offset[5:0];end
                    `DB_BRIGHTNESS_STATUS:if(meta_zero_length) brightness_mode<=rx_offset[1:0];
                    `DB_EMERGENCY_STATE:if(emergency_meta_admitted) begin
                        emergency_rx_word<=1;emergency_request_revision<=rx_object;
                        emergency_request_snapshot[127:96]<=rx_offset;
                    end
                    `DB_EMERGENCY_EPOCH:if(emergency_meta_admitted) begin
                        emergency_rx_word<=2;emergency_request_snapshot[95:64]<=rx_offset;
                    end
                    `DB_EMERGENCY_POSITION:if(emergency_meta_admitted) begin
                        emergency_rx_word<=3;emergency_request_snapshot[63:32]<=rx_offset;
                    end
                    `DB_EMERGENCY_COMMIT:if(emergency_meta_admitted) begin
                        emergency_rx_word<=0;
                        if(rx_offset[31:6]==0 && rx_offset[5:4]<=2) begin
                            emergency_request_mode<=rx_offset[5:4];emergency_request_snapshot[31:0]<={28'd0,rx_offset[3:0]};
                            emergency_request_valid<=1;seek_issued<=0;freeze_pending<=0;
                        end
                    end
                    `DB_PCM_POSITION:if(rx_length==4) begin feedback_id<=rx_object;feedback_pos<=rx_offset;rx_kind<=1;end
                    `DB_ERROR:if(meta_image_match && image_active) begin image_active<=0;image_ready<=0;source_ok<=0;end_image_pending<=0;end
                             else if(meta_overlay_match && overlay_active) begin
                                 overlay_active<=0;overlay_ready<=0;overlay_abort_pending<=1;overlay_abort_id<=overlay_id;
                                 overlay_failed<=1;overlay_end_pending<=0;overlay_end_queued<=0;
                             end
                    default:if(rx_required) begin error_pending<=1;error_object<=rx_object;error_opcode<={24'd0,rx_opcode};end
                endcase
                else if(rx_required) begin error_pending<=1;error_object<=rx_object;error_opcode<={24'd0,rx_opcode};end
            end
            if(rx_valid && rx_last) begin
                // An old POSITION arriving on the clear/rebase clock must not
                // overwrite the new stream's credit base with its old position.
                if(rx_kind==1 && feedback_id==audio_id && !pcm_clear && !audio_stream_changed) begin
                    played_position<=feedback_pos;
                    feedback_confirmed_id<=feedback_id;
                    remote_playing<=rx_data[0];
                    if(seek_wait && !seek_issued && rx_data[2]) begin
                        freeze_pending<=0;
                        if(seek_has_tail) begin seek_execute<=1;seek_issued<=1;end
                        else begin pause_pending<=1;end
                    end
                end
                rx_kind<=0;
            end
            if(ui_wr_en) begin page_ready<=0;copy_dirty<=1;end
            if(ui_commit_toggle!=ui_seen) begin ui_seen<=ui_commit_toggle;page_ready<=1;ui_dirty<=1;end
            if(ui_controls!=ui_controls_seen || saturation_level!=saturation_seen) begin ui_controls_seen<=ui_controls;saturation_seen<=saturation_level;ui_dirty<=1;copy_dirty<=1;end
            case(copy_state)
                0:if(ui_dirty && page_ready && !ui_pending && !(tx_kind==4 && tx_state!=0)) begin
                    copy_index<=0;copy_dirty<=0;copy_state<=1;ui_dirty<=0;ui_controls_frozen<=ui_controls;saturation_frozen<=saturation_level;
                end
                1:copy_state<=2;
                2:begin
                    ui_build<={ui_build[23:0],ui_q};
                    if(copy_index==287) begin
                        copy_state<=0;
                        if(!copy_dirty && !ui_wr_en && ui_controls==ui_controls_frozen && saturation_level==saturation_frozen) begin ui_pending<=1;ui_flags<=ui_controls_frozen;saturation_snapshot<=saturation_frozen;ui_revision<=ui_revision+1'b1;end
                        else ui_dirty<=1;
                    end else begin copy_index<=copy_index+1'b1;copy_state<=1;end
                end
                default:copy_state<=0;
            endcase
            if(diag!=diag_seen) begin diag_seen<=diag;status_pending<=1;end
            // Unconditional periodic refresh, independent of any change.  This
            // is what lets the peer recover from a dropped STATUS without the
            // user ever seeing a stale WAIT DATA.
            if(status_age>=STATUS_REFRESH_CYCLES) begin
                status_age<=0;status_pending<=1;
            end else status_age<=status_age+1'b1;
            if(tx_state==0) begin
                img_cancel<=0;pcm_cancel<=0;tx_index<=0;ui_wait<=0;
                if(idle_can_send) begin
                    ch_r<=0;len_r<=0;tx_kind<=0;tx_state<=1;
                    if(obj_emergency) begin
                        op_r<=`DB_EMERGENCY_STATUS;
                        len_r<=4;tx_words<=1;tx_kind<=7;payload_r<=audio_id;
                    end else if(volume_pending || volume_changed) begin
                        op_r<=`DB_VOLUME_SET;
                        volume_pending<=0;volume_pending_hint<=0;
                    end else if(error_pending) begin op_r<=`DB_ERROR;error_pending<=0;end
                    else if(stop_pending) begin op_r<=`DB_PCM_STOP;stop_pending<=0;end
                    else if(freeze_pending) begin op_r<=`DB_PCM_FREEZE;freeze_pending<=0;end
                    else if(begin_audio_pending) begin
                        op_r<=`DB_PCM_BEGIN;
                        total_latched<=audio_pending_total;base_latched<=audio_pending_base;
                        tx_pcm_pause<=paused;
                        len_r<=8;tx_words<=2;tx_kind<=3;begin_audio_pending<=0;
                    end else if(pause_pending) begin op_r<=`DB_PCM_PAUSE;pause_pending<=0;end
                    else if(status_pending) begin op_r<=`DB_STATUS;status_pending<=0;end
                    else if(subtitle_valid) begin
                        op_r<=`DB_SD_SUBTITLE_SET;len_r<=264;tx_words<=66;tx_kind<=6;subtitle_ready<=1;
                    end else if(ui_pending) begin
                        op_r<=`DB_UI_SNAPSHOT;len_r<=296;tx_words<=74;
                        ui_flags_r<=ui_flags;saturation_tx<=saturation_snapshot;tx_kind<=4;ui_read_word<=0;ui_pending<=0;
                    end else if(pcm_can_send) begin
                        ch_r<=1;op_r<=`DB_PCM_DATA;
                        len_r<=pcm_used_ge_256 ? 11'd1024 : {pcm_used[8:0],2'b00};
                        tx_words<=pcm_used_ge_256 ? 9'd256 : pcm_used[8:0];tx_kind<=2;
                    end else if(pcm_can_end) begin op_r<=`DB_PCM_END;end_audio_pending<=0;end
                    else if(overlay_abort_pending) begin ch_r<=2;op_r<=`DB_OVL_ABORT;overlay_abort_pending<=0;len_r<=0;tx_kind<=10;end
                    else if(overlay_begin_pending) begin ch_r<=2;op_r<=`DB_OVL_BEGIN;len_r<=0;overlay_begin_pending<=0;end
                    else if(overlay_tx_ready) begin
                        ch_r<=2;op_r<=`DB_OVL_DATA;
                        len_r<=img_used_ge_256 ? 11'd1024 : {img_used[8:0],2'b00};
                        tx_words<=img_used_ge_256 ? 9'd256 : img_used[8:0];tx_kind<=8;
                    end else if(overlay_end_pending) begin
                        ch_r<=2;op_r<=`DB_OVL_END;len_r<=4;tx_words<=1;tx_kind<=9;
                    end
                    else if(abort_image_pending) begin ch_r<=2;op_r<=`DB_IMG_ABORT;abort_image_pending<=0;end
                    else if(begin_image_pending) begin ch_r<=2;op_r<=`DB_IMG_BEGIN;begin_image_pending<=0;end
                    else if(image_ready && img_valid) begin
                        ch_r<=2;op_r<=`DB_IMG_DATA;
                        len_r<=img_used_ge_256 ? 11'd1024 : {img_used[8:0],2'b00};
                        tx_words<=img_used_ge_256 ? 9'd256 : img_used[8:0];tx_kind<=1;
                    end else if(end_image_pending) begin ch_r<=2;op_r<=`DB_IMG_END;len_r<=4;tx_words<=1;tx_kind<=5;end_image_pending<=0;end
                    else tx_state<=0;
                end
            end else if(tx_state==1 && tx_meta_ready) tx_state<=len_r==0 ? 0:2;
            else if(tx_state==2 && tx_valid && tx_ready) begin
                tx_index<=tx_index+1'b1;
                if(tx_kind==1 && !img_cancel) image_sent<=image_sent+1'b1;
                if(tx_kind==8 && !overlay_cancel) overlay_sent<=overlay_sent+1'b1;
                if(tx_kind==2 && !pcm_cancel && !pcm_clear && !audio_stream_changed) audio_sent<=audio_sent+1'b1;
                if(tx_kind==4 && tx_index>=2) begin
                    ui_read_word<=ui_read_word+1'b1;ui_wait<=2;tx_state<=3;
                end
                if(tx_last) begin
                    tx_state<=0;
                    if(tx_kind==5) source_ok<=0;
                    if(tx_kind==9) overlay_end_pending<=0;
                    if(tx_kind==10) begin overlay_abort_pending<=0;overlay_cancel<=0;end
                end
            end else if(tx_state==3) begin
                if(ui_wait==0) tx_state<=2;else ui_wait<=ui_wait-1'b1;
            end
            if(session_reset || !link_up) begin volume_pending<=1;volume_pending_hint<=0;end
            if(session_reset) begin
                emergency_rx_word<=0;
                keypad_valid<=0;
                tx_state<=0;rx_kind<=0;image_ready<=0;image_active<=0;
                begin_image_pending<=0;end_image_pending<=0;abort_image_pending<=0;img_clear<=1;
                overlay_req_seen<=0;overlay_active<=0;overlay_ready<=0;overlay_cancel<=0;
                overlay_begin_pending<=0;overlay_end_pending<=0;overlay_abort_pending<=0;overlay_count<=0;overlay_sent<=0;
                overlay_end_queued<=0;
                stop_pending<=0;begin_audio_pending<=0;seek_issued<=0;audio_flush<=1;remote_playing<=0;
                image_req_seen<=0;
                status_pending<=1;ui_dirty<=1;ui_pending<=0;brightness_mode<=0;
                error_pending<=0;
                if(had_audio) reconnecting<=1;
            end else if(reconnecting && link_up) begin
                resume_request<=1;reconnecting<=0;
            end
        end
    end
endmodule
