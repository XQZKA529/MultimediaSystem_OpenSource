`include "../pkg/fat_dir_bus.vh"
// media owns both SD text sources. All storage requests are retained by the
// service; directory ownership is held through dir_done, including failures.
module sd_subtitle_controller #(parameter CLK_HZ=100000000)(
 input wire clk,rst,link_up,session_reset,input wire storage_idle,
 input wire display_toggle,auto_toggle,clear_manual,
 output reg match_done,output reg wav_match,output wire match_pending,output wire [31:0] wav_cluster,wav_size,
 output reg display_enable,auto_enable,output reg [3:0] status,
 input wire load_req,input wire [31:0] load_cluster,load_size,
 output reg load_ack,load_rejected,output wire busy,
 input wire image_presented,image_suppress_audio,input wire [31:0] image_cluster,image_size,image_id,
 output reg dir_req,input wire dir_gnt,output reg dir_start,input wire [`VDIR_DBUS_W-1:0] dir_dat,
 output reg file_start,output reg [31:0] file_cluster,file_size,
 input wire [7:0] file_data,input wire file_valid,file_done,file_ok,
 output wire message_valid,input wire message_ready,output reg [31:0] message_revision,
 output wire word_valid,input wire word_ready,output wire [31:0] word_data,
 input wire applied,input wire [31:0] applied_revision,input wire [1:0] applied_result);
 localparam IDLE=0,DIR1_REQ=1,DIR1=2,DIR2_REQ=3,DIR2=4,FILE_REQ=5,FILE_WAIT=6,
 PARSE_WAIT=7,COPY_R=8,COPY_W=9;
 localparam NAME=11'd0,CAND=11'd256,MANUAL=11'd512,AUTO=11'd768,SNAPSHOT=11'd1024;
 // status: 0 ready, 1 loading, 2 truncated, 3 first line, 4 not found,
 // 5 format, 6 read/timeout, 7 unsupported name, 8 ambiguous, 9 applying.
 reg [3:0] state;
 reg manual_pending,auto_pending,operation_auto,dirty,audio_lookup_pending;
 reg staged,promoting;reg [8:0] staged_len;reg staged_trunc,staged_line;
 reg await_live;
 reg defer_display,defer_auto,defer_clear;
 reg [31:0] manual_cluster_q,manual_size_q,current_cluster,current_size,current_id;
 reg [31:0] lookup_id,auto_id;
 wire [31:0] await_revision=message_revision;
 reg applied_match_q;
 reg [1:0] applied_result_q;
 always @(posedge clk or posedge rst) begin
  if(rst) begin applied_match_q<=0;applied_result_q<=0;end
  else begin
   applied_match_q<=!session_reset && link_up && applied && applied_revision==await_revision;
   applied_result_q<=applied_result;
  end
 end
 reg [8:0] manual_len,auto_len,copy_index,copy_len;
 reg manual_trunc,auto_trunc,manual_line,auto_line;
 reg [10:0] copy_source,copy_dest;
 reg copy_snapshot;
 reg [7:0] name_len,entry_len;
 reg target_entry,name_bad,entry_bad,entry_equal,entry_emergency,compare_pending;
 reg [7:0] compare_char,compare_index;
 reg [1:0] found,wav_found;
 reg [31:0] found_cluster,found_size;
 assign wav_cluster=found_cluster;assign wav_size=found_size;
 reg [7:0] suffix0,suffix1,suffix2,suffix3;
 // Directory/file work and a staged manual commit never overlap, so they
 // share one watchdog. The public revision also identifies the frozen bank.
 reg [$clog2(CLK_HZ*15+1)-1:0] age;reg age_expired;
 wire es=dir_dat[`VDIR_D_ESTART],nv=dir_dat[`VDIR_D_NVLD],ee=dir_dat[`VDIR_D_EEND];
 wire dd=dir_dat[`VDIR_D_DONE],dok=dir_dat[`VDIR_D_OK];
 wire [7:0] nc=dir_dat[`VDIR_D_CHAR],ni=dir_dat[`VDIR_D_INDEX];
 function [7:0] fold;input [7:0] c;begin
  fold=(c[7:6]==2'b01 && c[5] && c[4:0]!=0 && c[4:0]<=5'd26)?{c[7:6],1'b0,c[4:0]}:c;
 end endfunction
 wire parser_start=state==FILE_REQ;
 reg finish_pending,finish_ok;
 wire cv,pdone,pok,ptrunc,pline;wire [7:0] ci;wire [8:0] plen;wire [7:0] cd;
 txt_prefix_parser u_parser(.clk(clk),.rst(rst),.start(parser_start),
 .byte_valid(file_valid && state==FILE_WAIT),.byte_data(file_data),
 .finish(finish_pending),.read_ok(finish_ok),.file_size(file_size),
 .char_valid(cv),.char_index(ci),.char_data(cd),.done(pdone),.ok(pok),
 .length(plen),.truncated(ptrunc),.first_line(pline));
 reg ram_we;reg [10:0] ram_addr;reg [15:0] ram_d;
 wire [15:0] qa,qb;
 reg [7:0] tx_byte;reg [2:0] tx_state;reg tx_valid;
 reg [6:0] tx_word;reg [31:0] tx_data,snapshot_flags,snapshot_id;
 reg snapshot_ready;
 wire transmitting=tx_state!=0 || snapshot_ready;
 // Apply fresh/deferred settings before dispatching work or freezing flags.
 // Otherwise a same-edge dirty clear could drop the new configuration. A
 // presentation also settles first so a pending lookup uses the latest image.
 wire settings_change=!staged && (display_toggle || auto_toggle || clear_manual ||
     defer_display || defer_auto || defer_clear);
 assign message_valid=snapshot_ready;
 assign match_pending=auto_pending || state==DIR1_REQ || state==DIR1 || state==DIR2_REQ || state==DIR2;
 assign word_valid=tx_valid;assign word_data=tx_data;
 assign busy=state!=IDLE || manual_pending || auto_pending || staged;
 always @(*) begin
  ram_we=0;ram_addr=copy_source+{2'd0,copy_index};ram_d=0;
  if(state==DIR2 && nv) ram_addr=NAME+{3'd0,ni};
  if(state==DIR1 && nv && target_entry) begin ram_we=1;ram_addr=NAME+{3'd0,ni};ram_d={8'd0,nc};end
  if(cv) begin ram_we=1;ram_addr=CAND+{3'd0,ci};ram_d={8'd0,cd};end
  if(state==COPY_W && copy_index<256) begin ram_we=1;ram_addr=copy_dest+{3'd0,copy_index[7:0]};ram_d=copy_index<copy_len ? qa:16'd0;end
 end
 subtitle_ram u_ram(.clk(clk),.wr_en(ram_we),.addr_a(ram_addr),.data_a(ram_d),.q_a(qa),
 .rd_clk(clk),.addr_b(SNAPSHOT+{3'd0,tx_byte}),.q_b(qb));
 // Frozen snapshot stream. B-port prefetch separates synchronous RAM from
 // ready/valid and holds the completed word unchanged under network pressure.
 always @(posedge clk or posedge rst) begin
  if(rst) begin tx_state<=0;tx_valid<=0;tx_data<=0;tx_word<=0;tx_byte<=0;end
  else if(session_reset || !link_up) begin tx_state<=0;tx_valid<=0;end
  else begin
   if(snapshot_ready && message_ready) begin tx_state<=1;tx_word<=0;tx_valid<=1;tx_data<=snapshot_flags;end
   else if(tx_valid && word_ready) begin
    tx_valid<=0;tx_word<=tx_word+1'b1;
    if(tx_word==0) begin tx_valid<=1;tx_data<=snapshot_id;end
    else if(tx_word==65) tx_state<=0;
    else begin if(tx_word==1) tx_byte<=0;tx_state<=2;end
   end else if(tx_state==2) tx_state<=3;
   else if(tx_state==3) begin
    tx_data<={tx_data[23:0],qb[7:0]};tx_byte<=tx_byte+1'b1;
    if(tx_byte[1:0]==3) begin tx_data<={tx_data[23:0],qb[7:0]};tx_valid<=1;tx_state<=1;end
    else tx_state<=2;
   end
  end
 end
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   staged<=0;promoting<=0;staged_len<=0;staged_trunc<=0;staged_line<=0;await_live<=0;defer_display<=0;defer_auto<=0;defer_clear<=0;
   state<=IDLE;display_enable<=0;auto_enable<=0;status<=0;manual_pending<=0;auto_pending<=0;operation_auto<=0;dirty<=1;audio_lookup_pending<=0;
   manual_cluster_q<=0;manual_size_q<=0;current_cluster<=0;current_size<=0;current_id<=0;
   lookup_id<=0;auto_id<=0;
   manual_len<=0;auto_len<=0;copy_index<=0;copy_len<=0;copy_source<=0;copy_dest<=0;copy_snapshot<=0;
   manual_trunc<=0;auto_trunc<=0;manual_line<=0;auto_line<=0;
   name_len<=0;entry_len<=0;target_entry<=0;name_bad<=0;entry_bad<=0;entry_equal<=0;entry_emergency<=0;compare_pending<=0;compare_char<=0;compare_index<=0;
   found<=0;wav_found<=0;found_cluster<=0;found_size<=0;
   match_done<=0;wav_match<=0;suffix0<=0;suffix1<=0;suffix2<=0;suffix3<=0;
   age<=0;age_expired<=0;dir_req<=0;dir_start<=0;file_start<=0;file_cluster<=0;file_size<=0;finish_pending<=0;finish_ok<=0;
   load_ack<=0;load_rejected<=0;message_revision<=0;snapshot_ready<=0;snapshot_flags<=0;snapshot_id<=0;
  end else begin
   dir_start<=0;file_start<=0;load_ack<=0;load_rejected<=0;finish_pending<=0;match_done<=0;wav_match<=0;
   compare_pending<=state==DIR2 && nv;
   if(nv) begin compare_char<=nc;compare_index<=ni;end
   if(compare_pending) begin
    if(compare_index<name_len-3 && fold(compare_char)!=fold(qa[7:0])) entry_equal<=0;
   end
   if(load_req) begin manual_pending<=1;manual_cluster_q<=load_cluster;manual_size_q<=load_size;end
   if(image_presented) begin current_cluster<=image_cluster;current_size<=image_size;current_id<=image_id;
    auto_pending<=1;audio_lookup_pending<=!image_suppress_audio;
   end
   if(staged) begin
    if(display_toggle) defer_display<=~defer_display;
    if(auto_toggle) defer_auto<=~defer_auto;
    if(clear_manual) defer_clear<=1;
   end
   if(!staged && (display_toggle || defer_display)) begin defer_display<=0;
     if(display_toggle ^ defer_display) begin display_enable<=~display_enable;dirty<=1;
     if(!display_enable && auto_enable && current_cluster!=0 && state==IDLE && !auto_pending) auto_pending<=1;
    end
   end
   if(!staged && (auto_toggle || defer_auto)) begin defer_auto<=0;
    if(auto_toggle ^ defer_auto) begin auto_enable<=~auto_enable;dirty<=1;
     if(!auto_enable) begin display_enable<=1;auto_len<=0;auto_id<=current_id;if(current_cluster!=0 && state==IDLE && !auto_pending) auto_pending<=1;end
     else auto_pending<=0;
    end
   end
   if(!staged && (clear_manual || defer_clear)) begin defer_clear<=0; manual_len<=0;manual_trunc<=0;manual_line<=0;dirty<=1;end
   if(snapshot_ready && message_ready) snapshot_ready<=0;
   if(session_reset || !link_up) begin snapshot_ready<=0;dirty<=1;end
   if(state==IDLE && !staged) begin age<=0;age_expired<=0;end
   else if(age<CLK_HZ*15) begin
    age<=age+1'b1;age_expired<=age>=CLK_HZ*15-1;
   end else age_expired<=1;
   case(state)
    IDLE:if(!transmitting && !settings_change && !image_presented && !session_reset) begin
     if(manual_pending && storage_idle && !staged) begin
      manual_pending<=0;operation_auto<=0;file_cluster<=manual_cluster_q;file_size<=manual_size_q;status<=1;state<=FILE_REQ;
     end else if(auto_pending && storage_idle && !staged) begin
      auto_pending<=0;operation_auto<=1;file_cluster<=current_cluster;file_size<=current_size;lookup_id<=current_id;
      found<=0;wav_found<=0;name_bad<=0;if(auto_enable && display_enable) status<=1;dir_req<=1;state<=DIR1_REQ;
     end else if(dirty && link_up) begin
      dirty<=0;copy_snapshot<=1;copy_source<=staged ? CAND:auto_enable ? AUTO:MANUAL;copy_dest<=SNAPSHOT;
      copy_len<=staged ? staged_len:auto_enable ? auto_len:manual_len;copy_index<=0;state<=COPY_R;
      snapshot_flags<=staged ? {19'd0,staged_line,staged_trunc,1'b0,1'b1,staged_len}:{19'd0,(auto_enable ? auto_line:manual_line),(auto_enable ? auto_trunc:manual_trunc),auto_enable,display_enable,(auto_enable ? auto_len:manual_len)};
      snapshot_id<=!staged && auto_enable ? auto_id:32'd0;message_revision<=message_revision+1'b1;if(staged) await_live<=1;
     end
    end
    DIR1_REQ:if(dir_gnt) begin dir_start<=1;state<=DIR1;end
    DIR1,DIR2:begin
     if(es) begin
      target_entry<=!dir_dat[`VDIR_D_ISDIR] && dir_dat[`VDIR_D_FCLUST]==file_cluster && dir_dat[`VDIR_D_SIZE]==file_size;
      entry_bad<=dir_dat[`VDIR_D_ISDIR];entry_equal<=1;entry_len<=0;
      if(state==DIR2) entry_emergency<=1;
      else entry_emergency<=0;
      suffix0<=0;suffix1<=0;suffix2<=0;suffix3<=0;
     end
     if(nv) begin
      entry_len<=ni+1'b1;if(nc<32 || nc>126 || nc==8'd63 || ni==255) entry_bad<=1;
      if(state==DIR2 && ni<6 && fold(nc)!=
         (ni==0 ? 8'd69:ni==1 ? 8'd77:ni==2 ? 8'd69:ni==3 ? 8'd82:ni==4 ? 8'd71:8'd46)) entry_emergency<=0;
      suffix0<=suffix1;suffix1<=suffix2;suffix2<=suffix3;suffix3<=fold(nc);
     end
     if(ee) begin
      if(state==DIR1 && target_entry && suffix0==46 && suffix1==66 && suffix2==77 && suffix3==80) begin
       if(found<2) found<=found+1'b1;name_len<=entry_len;name_bad<=name_bad || entry_bad;
      end
      if(state==DIR2 && !entry_bad && entry_equal && entry_len==name_len &&
         suffix0==46 && suffix1==84 && suffix2==88 && suffix3==84) begin
       if(found<2) found<=found+1'b1;
       file_cluster<=dir_dat[`VDIR_D_FCLUST];file_size<=dir_dat[`VDIR_D_SIZE];
      end
      if(state==DIR2 && !entry_bad && entry_equal && entry_len==name_len &&
         !(entry_emergency && entry_len==9) &&
         suffix0==46 && suffix1==87 && suffix2==65 && suffix3==86) begin
       if(wav_found<2) wav_found<=wav_found+1'b1;
       found_cluster<=dir_dat[`VDIR_D_FCLUST];found_size<=dir_dat[`VDIR_D_SIZE];
      end
     end
     // Timeout marks the result failed, but never hands off a live directory.
     if(dd) begin
      dir_req<=0;
      if(!dok || age_expired || (state==DIR1 && (found!=1 || name_bad))) begin
       status<=(!dok || age_expired)?6:found>1?8:name_bad?7:4;
       if(audio_lookup_pending) begin match_done<=1;wav_match<=0;audio_lookup_pending<=0;end
       if(auto_enable && display_enable) begin auto_len<=0;auto_id<=lookup_id;auto_trunc<=0;auto_line<=0;dirty<=1;end
       state<=IDLE;
      end else if(state==DIR1) begin found<=0;wav_found<=0;dir_req<=1;state<=DIR2_REQ;age<=0;age_expired<=0;end
      else begin
       if(audio_lookup_pending) begin match_done<=1;wav_match<=wav_found==1;audio_lookup_pending<=0;end
       age<=0;age_expired<=0;
       if(auto_enable && display_enable && found==1) begin state<=FILE_REQ;end
       else begin
        if(auto_enable && display_enable) begin
         auto_len<=0;auto_id<=lookup_id;auto_trunc<=0;auto_line<=0;dirty<=1;
         if(found>1) status<=8;else if(found==0) status<=4;
        end
        state<=IDLE;
       end
      end
     end
    end
    DIR2_REQ:if(dir_gnt) begin dir_start<=1;state<=DIR2;end
    FILE_REQ:begin
     if(file_size==0) begin finish_pending<=1;finish_ok<=1;state<=PARSE_WAIT;end
     else begin file_start<=1;state<=FILE_WAIT;end
    end
    FILE_WAIT:if(file_done) begin finish_pending<=1;finish_ok<=file_ok;state<=PARSE_WAIT;end
    PARSE_WAIT:if(pdone) begin
     if(!pok) begin
      status<=finish_ok ? 5:6;
      if(operation_auto) begin auto_len<=0;auto_id<=lookup_id;dirty<=1;end else load_rejected<=1;
      state<=IDLE;
     end else if(!operation_auto) begin
      staged<=1;staged_len<=plen;staged_trunc<=ptrunc;staged_line<=pline;age<=0;age_expired<=0;await_live<=0;dirty<=1;state<=IDLE;status<=9;
     end else begin
      copy_snapshot<=0;copy_source<=CAND;copy_dest<=operation_auto ? AUTO:MANUAL;
      copy_len<=plen;copy_index<=0;state<=COPY_R;status<=ptrunc?2:pline?3:0;
     end
    end
    COPY_R:state<=COPY_W;
    COPY_W:if(copy_index==255) begin
     if(copy_snapshot) begin snapshot_ready<=1;state<=IDLE;end
     else if(promoting) begin
      promoting<=0;staged<=0;await_live<=0;manual_len<=copy_len;manual_trunc<=staged_trunc;manual_line<=staged_line;
      display_enable<=1;auto_enable<=0;auto_pending<=0;load_ack<=1;status<=staged_trunc?2:staged_line?3:0;state<=IDLE;
     end else begin
      dirty<=1;state<=IDLE;
      if(operation_auto) begin auto_len<=copy_len;auto_id<=lookup_id;auto_trunc<=ptrunc;auto_line<=pline;end
      else begin manual_len<=copy_len;manual_trunc<=ptrunc;manual_line<=pline;display_enable<=1;auto_enable<=0;auto_pending<=0;end
     end
    end else begin copy_index<=copy_index+1'b1;state<=COPY_R;end
    default:state<=IDLE;
   endcase
   // Manual success is a video commit, never just a network ACK.
   if(staged && await_live && applied_match_q) begin
    if(applied_result_q==0) begin
     promoting<=1;copy_snapshot<=0;copy_source<=CAND;copy_dest<=MANUAL;copy_len<=staged_len;copy_index<=0;state<=COPY_R;
    end else begin staged<=0;await_live<=0;load_rejected<=1;status<=6;dirty<=1;end
   end else if(staged && age_expired && state==IDLE && !transmitting) begin
    staged<=0;await_live<=0;load_rejected<=1;status<=6;dirty<=1;
   end
  end
 end
endmodule
