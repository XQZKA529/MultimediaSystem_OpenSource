`include "../pkg/video_bmp_params.vh"
module db_audio_sink #(parameter PIX_HZ=`VBP_PIX_CLK_HZ,parameter PREFILL=1024)(
    input wire clk,rst,input wire video_clk,video_rst,input wire link_up,
    input wire begin_stream,input wire [31:0] stream_id,total_frames,base_frame,
    input wire initial_pause,input wire stop,input wire paused,input wire frozen,
    input wire local_hold,
    input wire eof,input wire push,input wire [31:0] pcm,output wire packet_ready,
    output wire [31:0] epoch_v,position_v,total_v,output wire playing_v,paused_v,
    output wire restart_v,output wire audio_valid,output wire [23:0] audio_left,audio_right,
    output wire ready_v,
    output reg feedback,output reg [31:0] feedback_epoch,feedback_position,
    output reg [2:0] feedback_flags
);
    reg cfg_toggle,eof_toggle;
    reg [31:0] cfg_id,cfg_total,cfg_base;
    reg cfg_pause,stopped;
    reg [1:0] cfg_state_bus;
    wire glue_ready,clear_busy,clear_video,out_valid;
    wire [23:0] out_left,out_right;
    wire [11:0] buffered;
    wire pcm_ready,played;
    reg [31:0] epoch,total,position,last_position;
    reg has_remaining; // Updated on actual sample consumption, no wide compare in PCM ready path.
    reg configured,prefilled;
    reg [1:0] cfg_state;
    (* async_reg="true" *) reg [2:0] cfg_sync,eof_sync;
    (* async_reg="true" *) reg pause1,pause2,live1,live2,freeze1,freeze2;
    (* async_reg="true" *) reg stop1,stop2;
    reg cfg_seen,eof_seen,short_eof;
    reg freeze_d;
    assign epoch_v=epoch;assign position_v=position;assign total_v=total;
    assign playing_v=configured && !stop2 && live2 && has_remaining;
    assign paused_v=pause2;
    assign ready_v=configured && prefilled;
    assign packet_ready=glue_ready && !clear_busy && cfg_state_bus==0;
    (* async_reg="true" *) reg cfg_ack1,cfg_ack2;
    wire run=configured && prefilled && live2 && !stop2 && !pause2 && !freeze2 && has_remaining && !clear_video;
    wire configuration_settled=cfg_state==0 && cfg_sync[2]==cfg_seen && !clear_video;
    assign restart_v=(cfg_sync[2]!=cfg_seen);
    wav_play_glue u_ring(.wr_clk(clk),.wr_rst_n(~rst),.wr_push(push),.wr_data(pcm),
        .wr_ready(glue_ready),.wr_clear(begin_stream || stop),.wr_almost_empty(),
        .rd_clk(video_clk),.rd_rst_n(~video_rst),.out_valid(out_valid),
        .out_left(out_left),.out_right(out_right),.out_ready(pcm_ready),.play_run(),
        .buffered_words(buffered),.clear_busy(clear_busy),.clear_video(clear_video));
    audio_wav_pcm #(.CLK_FREQ_HZ(PIX_HZ)) u_pcm(
        .I_clk(video_clk),.I_rst_n(~video_rst),.I_run(run),.I_valid_en(1'b1),
        .stream_clear(clear_video || !live2),.sample_played(played),
        .in_valid(out_valid),.in_left(out_left),.in_right(out_right),.in_ready(pcm_ready),
        .O_audio_valid(audio_valid),.O_audio_left_data(audio_left),.O_audio_right_data(audio_right));
    // Held snapshot mailbox: video producer owns it until bus acknowledges.
    reg [66:0] snapshot;
    reg snap_toggle,snap_ack;
    (* async_reg="true" *) reg ack1,ack2,snap1,snap2;
    reg [31:0] feedback_timer;
    reg [2:0] freeze_settle;
    reg freeze_pending;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            cfg_toggle<=0;eof_toggle<=0;cfg_id<=0;cfg_total<=0;cfg_base<=0;cfg_pause<=0;stopped<=1;
            cfg_ack1<=0;cfg_ack2<=0;cfg_state_bus<=0;
            snap1<=0;snap2<=0;snap_ack<=0;feedback<=0;
            feedback_epoch<=0;feedback_position<=0;feedback_flags<=0;
        end else begin
            cfg_ack1<=cfg_seen;cfg_ack2<=cfg_ack1;
            snap1<=snap_toggle;snap2<=snap1;feedback<=0;
            if(begin_stream) begin
                stopped<=0;
                cfg_id<=stream_id;cfg_total<=total_frames;cfg_base<=base_frame;cfg_pause<=initial_pause;
                cfg_toggle<=~cfg_toggle;cfg_state_bus<=1;
            end else if(cfg_state_bus==1 && cfg_ack2==cfg_toggle && !clear_busy) cfg_state_bus<=0;
            if(stop) stopped<=1;
            if(eof) eof_toggle<=~eof_toggle;
            if(snap2!=snap_ack) begin
                feedback<=1;feedback_epoch<=snapshot[66:35];
                feedback_position<=snapshot[34:3];feedback_flags<=snapshot[2:0];snap_ack<=snap2;
            end
        end
    end
    always @(posedge video_clk or posedge video_rst) begin
        if(video_rst) begin
            cfg_sync<=0;eof_sync<=0;cfg_seen<=0;eof_seen<=0;short_eof<=0;
            pause1<=0;pause2<=0;live1<=0;live2<=0;freeze1<=0;freeze2<=0;freeze_d<=0;
            stop1<=1;stop2<=1;
            epoch<=0;total<=0;position<=0;last_position<=0;has_remaining<=0;configured<=0;prefilled<=0;cfg_state<=0;
            snapshot<=0;snap_toggle<=0;ack1<=0;ack2<=0;feedback_timer<=0;
            freeze_settle<=0;freeze_pending<=0;
        end else begin
            cfg_sync<={cfg_sync[1:0],cfg_toggle};eof_sync<={eof_sync[1:0],eof_toggle};
            pause1<=paused;pause2<=pause1;live1<=link_up;live2<=live1;
            stop1<=stopped;stop2<=stop1;
            freeze1<=frozen || local_hold===1'b1;freeze2<=freeze1;freeze_d<=freeze2;
            ack1<=snap_ack;ack2<=ack1;
            if(!live2) begin configured<=0;prefilled<=0;end
            if(cfg_sync[2]!=cfg_seen && cfg_state==0) begin
                configured<=0;prefilled<=0;short_eof<=0;
                epoch<=cfg_id;total<=cfg_total;position<=cfg_base;cfg_state<=1;
                last_position<=cfg_total-1'b1;has_remaining<=cfg_base<cfg_total;
            end
            if(cfg_state==1 && clear_video) cfg_state<=2;
            if(cfg_state==2 && !clear_video) begin configured<=1;cfg_state<=0;cfg_seen<=cfg_sync[2];end
            if(eof_sync[2]!=eof_seen) begin eof_seen<=eof_sync[2];short_eof<=1;end
            // The old configured/EOF values must not override the reset of
            // prefilled on the very clock that a replacement epoch arrives.
            if(configured && cfg_state==0 && cfg_sync[2]==cfg_seen && !clear_video &&
               (buffered>=PREFILL || short_eof)) prefilled<=1;
            if(played && configured && cfg_state==0 && cfg_sync[2]==cfg_seen && has_remaining) begin
                position<=position+1'b1;
                if(position==last_position) has_remaining<=0;
            end
            if(feedback_timer<PIX_HZ/50) feedback_timer<=feedback_timer+1'b1;
            if(freeze2 && !freeze_d) begin freeze_pending<=1;freeze_settle<=4;end
            if(freeze_settle!=0) freeze_settle<=freeze_settle-1'b1;
            if(snap_toggle==ack2 && ((freeze_pending && freeze_settle==0 && configuration_settled) || feedback_timer>=PIX_HZ/50)) begin
                // Frozen is persistent state, not a one-shot acknowledgement.
                // seam_render may coalesce feedback while its control TX waits;
                // every later snapshot must still confirm the settled position.
                snapshot<={epoch,position,(freeze2 && freeze_d && freeze_settle==0 && configuration_settled),pause2,playing_v};
                snap_toggle<=~snap_toggle;feedback_timer<=0;
                if(configuration_settled) freeze_pending<=0;
            end
        end
    end
endmodule
