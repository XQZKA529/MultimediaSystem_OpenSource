`include "../pkg/board_link.vh"
// Spare catalogue rows map consumed audio epochs to files, even while a
// replacement file is queued. No voice cache or extra BRAM is required.
module emergency_media_controller #(parameter CLK_HZ=100000000)(
 input wire clk,rst,link_up,session_reset,request_valid,input wire [1:0] request_mode,
 input wire [31:0] request_revision,input wire [127:0] request_snapshot,
 input wire emergency_found,catalog_done,input wire [31:0] emergency_cluster,emergency_size,
 input wire [31:0] track_cluster,track_size,audio_epoch,audio_file_epoch,total_frames,played_position,
 input wire [31:0] audio_consumed_epoch,audio_dispatch_epoch,input wire audio_dispatch_valid,
 input wire track_stream_toggle,track_ack,track_rejected,track_idle,input wire [3:0] track_status,input wire normal_pause,
 input wire image_presented,input wire [31:0] image_id,image_cluster,image_size,input wire image_idle,
 output reg block_normal,output wire history_hold,audio_context_busy,output reg force_close,restart_normal,
 output wire play_prepared,history_commit,restore_pause,play_req,output reg play_stop,
 output wire [31:0] play_cluster,play_size,play_position,
 output wire play_paused,restore_selection,output wire [31:0] restore_cluster,restore_size,
 output wire ctx_req,ctx_we,output reg [3:0] ctx_addr,ctx_read_addr,output reg [63:0] ctx_data,
 input wire ctx_ready,input wire [63:0] ctx_q,
 output wire prepare_restore,prepare_size,output wire [31:0] prepare_word,
 input wire [31:0] prepared_cluster,prepared_size,
 output reg reply_valid,input wire reply_ready,output reg [31:0] reply_revision,
 output wire [31:0] reply_epoch,output reg [7:0] reply_status
);
 localparam NORMAL=0,SAVE0=1,SAVE1=2,LOOK=3,LOOKQ=4,LOOKC=5,AFILE=6,AFILEQ=7,
 WAIT_ENTRY=8,START_EM=9,WAIT_EM=10,RUN_EM=11,ERROR_EM=12,
 RIMG=13,RIMGQ=14,RFILE=15,RFILEHI=16,RFILELO=17,RPOS=18,RPOSQ=19,WAIT_NORMAL=20,COMPLETE=21;
 reg [4:0] state;
 reg [1:0] desired,valid_banks,hstate,latest_audio,lookup_bank,saved_audio_bank;
 reg [3:0] audio_valid;
 reg [1:0] protected_audio_bank;
 reg protected_audio_valid,lookup_protect,dispatch_unconfirmed;
 reg latest_bank,saved_bank,history_pending,audio_history_pending,history_audio,audio_seen,lookup_audio;
 reg saved,context_saved,saved_audio,saved_pause,saved_image,lost,em_play_pulse;
 reg [$clog2(CLK_HZ*5+1)-1:0] age;
 reg age_expired,consumed_eof,context_tag_match,control_q_valid;
 reg [3:0] control_q_addr;
 reg restore_success;
 wire history_busy=history_pending || audio_history_pending || hstate!=0;
 wire control_grant=ctx_ready && !history_busy;
 wire q_current=control_q_valid && control_q_addr==ctx_read_addr;
 wire cancel_control=request_valid || session_reset;
 wire normal_launch=state==RPOSQ && control_grant && q_current && !cancel_control && link_up;
 assign history_hold=history_busy;
 assign audio_context_busy=audio_history_pending || (hstate!=0 && history_audio) || (!block_normal && dispatch_unconfirmed);
 assign play_prepared=normal_launch;
 assign history_commit=hstate==1 && ctx_ready && !history_audio;
 assign restore_pause=normal_launch || (state==RFILE && !saved_audio && !lost && !cancel_control);
 assign play_req=em_play_pulse || normal_launch;
 assign play_cluster=desired==1 ? emergency_cluster:prepared_cluster;
 assign play_size=desired==1 ? emergency_size:prepared_size;
 assign play_position=desired==1 ? 32'd0:ctx_q[63:32];
 assign play_paused=desired==1 ? 1'b0:saved_pause;
 assign reply_epoch=audio_epoch;
 assign restore_selection=state==RIMGQ && image_idle && control_grant && q_current && !cancel_control;
 assign restore_cluster=ctx_q[63:32];assign restore_size=ctx_q[31:0];
 assign prepare_restore=(state==RFILEHI || state==RFILELO) && control_grant && q_current && !cancel_control;
 assign prepare_size=state==RFILELO;
 assign prepare_word=state==RFILEHI ? ctx_q[63:32]:ctx_q[31:0];
 wire control_access=state==SAVE0 || state==SAVE1 || state==LOOK || state==LOOKQ ||
 state==AFILE || state==AFILEQ || state==RIMG || state==RIMGQ || state==RFILE ||
 state==RFILEHI || state==RFILELO || state==RPOS || state==RPOSQ;
 // A speculative control read is harmless while history is pending: the
 // control response remains invalid until control_grant. Suppress its writes
 // until history drains, and leave active history accesses unchanged.
 assign ctx_req=hstate!=0 || control_access;
 assign ctx_we=hstate!=0 || (!history_busy && (state==SAVE1 || (state==SAVE0 && q_current)));
 wire [1:0] candidate_audio_bank=latest_audio+1'b1;
 wire [1:0] next_audio_bank=protected_audio_valid && candidate_audio_bank==protected_audio_bank ? candidate_audio_bank+1'b1:candidate_audio_bank;
 wire save_file=hstate==0 && state==SAVE0;
 wire save_position=hstate==0 && state==SAVE1;
 wire audio_descriptor=hstate==1 && history_audio;
 wire image_descriptor=hstate==1 && !history_audio;
 wire audio_tag=hstate!=0 && hstate!=1 && history_audio;
 wire image_tag=hstate!=0 && hstate!=1 && !history_audio;
 always @(*) begin
  ctx_addr=4;
  // Only writes use this bus. Parallel selectors avoid a priority chain
  // through all 64 bits of the shared catalogue write port.
  ctx_data=({64{save_file}} & ctx_q) |
   ({64{save_position}} & {request_snapshot[63:32],32'd0}) |
   ({64{audio_descriptor}} & {track_cluster,track_size}) |
   ({64{image_descriptor}} & {image_cluster,image_size}) |
   ({64{audio_tag}} & {audio_file_epoch,32'd0}) |
   ({64{image_tag}} & {image_id,32'd0});
  case(state)
   SAVE1:ctx_addr=5;
   LOOK,LOOKQ:ctx_addr=lookup_audio ? {1'b1,lookup_bank,1'b1}:{2'b00,lookup_bank[0],1'b1};
   AFILE,AFILEQ:ctx_addr={1'b1,saved_audio_bank,1'b0};
   RIMG,RIMGQ:ctx_addr={2'b00,saved_bank,1'b0};
   RPOS,RPOSQ:ctx_addr=5;
   default:;
  endcase
  if(hstate!=0) begin
   ctx_addr=history_audio ? {1'b1,next_audio_bank,hstate==2}:{2'b00,!latest_bank,hstate==2};
  end
  ctx_read_addr=state==SAVE0 && hstate==0 ? {1'b1,saved_audio_bank,1'b0}:ctx_addr;
 end
 task report;input [7:0] code;begin reply_status<=code;reply_valid<=1;restore_success<=code==`DB_EM_RESTORED;end endtask
 task dispatch;begin state<=desired==1 ? WAIT_ENTRY:(saved_image ? RIMG:RFILE);end endtask
 task resume_context;begin lookup_audio<=1;lookup_bank<=0;state<=saved_audio ? LOOK:SAVE1;end endtask
 task return_normal;begin
  state<=NORMAL;block_normal<=0;saved<=0;context_saved<=0;restart_normal<=lost || !saved_image;
  if(saved_audio && !lost && restore_success) audio_history_pending<=1;
 end endtask
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   state<=NORMAL;block_normal<=0;desired<=0;valid_banks<=0;hstate<=0;latest_bank<=0;saved_bank<=0;history_pending<=0;
   audio_history_pending<=0;history_audio<=0;audio_seen<=0;audio_valid<=0;latest_audio<=0;
   lookup_bank<=0;lookup_audio<=0;saved_audio_bank<=0;control_q_valid<=0;control_q_addr<=0;context_tag_match<=0;
   protected_audio_bank<=0;protected_audio_valid<=0;lookup_protect<=0;dispatch_unconfirmed<=0;
   saved<=0;context_saved<=0;saved_audio<=0;saved_pause<=0;saved_image<=0;lost<=0;
   em_play_pulse<=0;play_stop<=0;force_close<=0;restart_normal<=0;age<=0;age_expired<=0;consumed_eof<=0;
   reply_valid<=0;reply_revision<=0;reply_status<=0;restore_success<=0;
  end else begin
   em_play_pulse<=0;play_stop<=0;force_close<=0;restart_normal<=0;
   consumed_eof<=total_frames!=0 && played_position>=total_frames;
   context_tag_match<=ctx_q[63:32]==(lookup_audio ? (lookup_protect ? audio_consumed_epoch:request_snapshot[95:64]):request_snapshot[127:96]);
   dispatch_unconfirmed<=audio_dispatch_valid===1'b1 && audio_dispatch_epoch!=audio_consumed_epoch;
   control_q_valid<=control_grant && ctx_req;
   if(control_grant && ctx_req) control_q_addr<=ctx_read_addr;
   audio_seen<=track_stream_toggle;
   if(!block_normal && track_stream_toggle!=audio_seen) audio_history_pending<=1;
   if(image_presented) history_pending<=1;
   if(hstate==0) begin
    if(audio_history_pending) begin hstate<=1;history_audio<=1;end
    else if(history_pending && image_idle) begin hstate<=1;history_audio<=0;end
   end
   if(hstate==1 && ctx_ready) hstate<=2;
   if(hstate==2 && ctx_ready) begin
    if(history_audio) begin
     audio_valid[next_audio_bank]<=1;latest_audio<=next_audio_bank;audio_history_pending<=0;
     if(!protected_audio_valid) begin protected_audio_bank<=next_audio_bank;protected_audio_valid<=1;end
    end
    else begin valid_banks[!latest_bank]<=1;latest_bank<=!latest_bank;history_pending<=0;end
    hstate<=0;
   end
   if(reply_valid && reply_ready) reply_valid<=0;
   if(!lookup_protect && state!=NORMAL && state!=RUN_EM && state!=ERROR_EM && state!=COMPLETE) begin
    if(!age_expired) begin age<=age+1'b1;age_expired<=age>=CLK_HZ*5-1;end
   end else begin age<=0;age_expired<=0;end
   case(state)
    NORMAL:if(!history_busy && audio_valid!=0) begin
     lookup_protect<=1;lookup_audio<=1;lookup_bank<=0;state<=LOOK;
    end
    SAVE0:if(control_grant && q_current) state<=SAVE1;
    SAVE1:if(control_grant) begin
     lookup_audio<=0;lookup_bank<=0;
     if(request_snapshot[3]) state<=LOOK;
     else begin context_saved<=1;dispatch;end
    end
    LOOK:if(control_grant) state<=LOOKQ;
    LOOKQ:if(control_grant && q_current) state<=LOOKC;
    LOOKC:begin
     if(lookup_protect) begin
      if(audio_valid[lookup_bank] && context_tag_match) begin
       protected_audio_bank<=lookup_bank;protected_audio_valid<=1;lookup_protect<=0;state<=NORMAL;
      end else if(lookup_bank==3) begin lookup_protect<=0;state<=NORMAL;end
      else begin lookup_bank<=lookup_bank+1'b1;state<=LOOK;end
     end else if((lookup_audio ? audio_valid[lookup_bank]:valid_banks[lookup_bank[0]]) && context_tag_match) begin
      if(lookup_audio) begin saved_audio_bank<=lookup_bank;state<=AFILE;end
      else begin saved_bank<=lookup_bank[0];saved_image<=1;context_saved<=1;state<=desired==1 ? WAIT_ENTRY:RIMG;end
     end else if(lookup_bank==(lookup_audio ? 2'd3:2'd1)) begin
      lost<=1;
      if(lookup_audio) state<=SAVE1;
      else begin saved_image<=0;context_saved<=1;state<=desired==1 ? WAIT_ENTRY:RFILE;end
     end else begin lookup_bank<=lookup_bank+1'b1;state<=LOOK;end
    end
    AFILE:if(control_grant) state<=AFILEQ;
    AFILEQ:if(control_grant && q_current) state<=SAVE0;
    WAIT_ENTRY:if(image_idle && catalog_done && !history_busy) state<=START_EM;
    START_EM:if(link_up) begin
     if(!emergency_found) begin report(`DB_EM_MISSING);state<=ERROR_EM;end
     else begin em_play_pulse<=1;state<=WAIT_EM;age<=0;age_expired<=0;end
    end
    WAIT_EM:if(track_ack) begin report(`DB_EM_PLAYING);state<=RUN_EM;end
     else if(track_rejected) begin play_stop<=1;report(track_status>=4 ? `DB_EM_FORMAT_ERROR:`DB_EM_READ_ERROR);state<=ERROR_EM;end
    RUN_EM:if(track_rejected) begin play_stop<=1;report(`DB_EM_READ_ERROR);state<=ERROR_EM;end
     else if(link_up && consumed_eof) state<=START_EM;
    RIMG:if(control_grant) state<=RIMGQ;
    RIMGQ:if(image_idle && control_grant && q_current) begin latest_bank<=saved_bank;state<=RFILE;end
    RFILE:if(!saved_audio || lost) begin report(lost ? `DB_EM_LOST:`DB_EM_EMPTY);state<=COMPLETE;end
     else if(control_grant && link_up) state<=RFILEHI;
    RFILEHI:if(control_grant && q_current) state<=RFILELO;
    RFILELO:if(control_grant && q_current) state<=RPOS;
    RPOS:if(control_grant) state<=RPOSQ;
    RPOSQ:if(normal_launch) begin state<=WAIT_NORMAL;age<=0;age_expired<=0;end
    WAIT_NORMAL:if(track_ack) begin report(`DB_EM_RESTORED);state<=COMPLETE;end
     else if(track_rejected) begin play_stop<=1;report(`DB_EM_RESTORE_ERROR);state<=COMPLETE;end
    COMPLETE:if(track_rejected && restore_success) begin play_stop<=1;report(`DB_EM_RESTORE_ERROR);end
     else if(desired==0 && !reply_valid) return_normal;
    default:;
   endcase
   if(age_expired && !lookup_protect && state!=NORMAL && state!=RUN_EM && state!=ERROR_EM && state!=COMPLETE) begin
    play_stop<=1;report(desired==1 ? `DB_EM_READ_ERROR:`DB_EM_RESTORE_ERROR);state<=desired==1 ? ERROR_EM:COMPLETE;
   end
   if(request_valid) begin
    reply_revision<=request_revision;reply_valid<=0;em_play_pulse<=0;play_stop<=1;age<=0;age_expired<=0;desired<=request_mode;
    lookup_protect<=0;
    if(request_mode==0 && !block_normal) begin play_stop<=0;state<=NORMAL;end
    else if(request_mode==0 && state==COMPLETE) begin return_normal;play_stop<=0;end
    else begin
     block_normal<=1;force_close<=1;
     if(!saved) begin
      saved<=1;context_saved<=0;saved_audio<=request_snapshot[0];saved_pause<=request_snapshot[1];saved_image<=0;lost<=0;
      lookup_audio<=1;lookup_bank<=0;state<=request_snapshot[0] ? LOOK:SAVE1;
     end else if(!context_saved) resume_context;
     else state<=request_mode==1 ? WAIT_ENTRY:(saved_image ? RIMG:RFILE);
     report(request_mode==1 ? `DB_EM_LOADING:`DB_EM_RECOVERING);
    end
   end
   if(session_reset && block_normal) begin
    lookup_protect<=0;
    desired<=0;play_stop<=1;em_play_pulse<=0;reply_valid<=0;
    if(!context_saved) resume_context;else state<=saved_image ? RIMG:RFILE;
   end
  end
 end
endmodule
