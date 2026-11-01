`include "../pkg/board_link.vh"
// Local authority survives link/session loss. Mailboxes remain stable until ack.
module emergency_controller(
    input wire clk,rst,link_up,session_reset,
    input wire alarm_active,
    input wire video_clk,video_rst,
    input wire [31:0] display_id,input wire [1:0] display_index,input wire display_valid,
    input wire feedback,input wire [31:0] feedback_epoch,feedback_position,
    input wire [2:0] feedback_flags,
    input wire reply_valid,input wire [31:0] reply_revision,reply_epoch,
    input wire [7:0] reply_status,
    input wire picture_restored,audio_ready,frame_sync,
    output reg [1:0] mode,output wire input_block,local_hold,
    output reg request_valid,input wire request_ready,
    output reg [31:0] revision,output wire [127:0] request_snapshot,
    output reg audio_allowed,output reg [31:0] allowed_epoch,
    output wire restore_picture,output wire [1:0] restore_index,
    output wire restore_valid,output wire [31:0] restore_id,
    output reg [7:0] status
);
    reg snapshot_ready,picture_ready,position_ready;
    reg [66:0] audio_snapshot;
    reg capture;
    (* async_reg="true" *) reg cap1,cap2,ack1,ack2,rest1,rest2,ready1,ready2;
    reg captured;
    reg [34:0] picture_snapshot;
    reg restore_reply;
    (* async_reg="true" *) reg frame1,frame2;
    reg frame_d;
    assign input_block=mode!=0;
    assign local_hold=input_block && (mode==2 || !audio_allowed);
    assign request_snapshot={picture_snapshot[34:3],audio_snapshot[66:35],audio_snapshot[34:3],
        28'd0,picture_snapshot[0],audio_snapshot[2:0]};
    assign restore_picture=mode==2;
    assign restore_id=picture_snapshot[34:3];
    assign restore_index=picture_snapshot[2:1];
    assign restore_valid=picture_snapshot[0];
    always @(posedge video_clk or posedge video_rst) begin
        if(video_rst) begin cap1<=0;cap2<=0;captured<=0;picture_snapshot<=0;end
        else begin
            cap1<=capture;cap2<=cap1;
            if(cap2!=captured) begin
                picture_snapshot<={display_id,display_index,display_valid};captured<=cap2;
            end
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            mode<=0;snapshot_ready<=0;picture_ready<=0;position_ready<=0;
            audio_snapshot<=0;capture<=0;ack1<=0;ack2<=0;rest1<=0;rest2<=0;
            request_valid<=0;revision<=0;audio_allowed<=0;allowed_epoch<=0;
            status<=0;restore_reply<=0;
            ready1<=0;ready2<=0;
            frame1<=0;frame2<=0;frame_d<=0;
        end else begin
            ack1<=captured;ack2<=ack1;rest1<=picture_restored;rest2<=rest1;
            ready1<=audio_ready;ready2<=ready1;
            frame1<=frame_sync;frame2<=frame1;frame_d<=frame2;
            if(input_block && !snapshot_ready) begin
                if(ack2==capture) picture_ready<=1;
                if(feedback && feedback_flags[2]) begin
                    audio_snapshot<={feedback_epoch,feedback_position,feedback_flags};position_ready<=1;
                end
                if(picture_ready && position_ready) begin snapshot_ready<=1;request_valid<=1;end
            end
            if(request_valid && request_ready) request_valid<=0;
            if(reply_valid && reply_revision==revision) begin
                status<=reply_status;
                if(reply_status==`DB_EM_PLAYING || reply_status==`DB_EM_RESTORED) begin
                    audio_allowed<=1;allowed_epoch<=reply_epoch;
                end
                if(mode==2 && (reply_status==`DB_EM_RESTORED || reply_status==`DB_EM_EMPTY ||
                   reply_status==`DB_EM_LOST || reply_status==`DB_EM_RESTORE_ERROR)) restore_reply<=1;
                if(mode==0 && (reply_status==`DB_EM_RESTORED || reply_status==`DB_EM_EMPTY ||
                   reply_status==`DB_EM_LOST || reply_status==`DB_EM_RESTORE_ERROR)) request_valid<=1;
                if(reply_status>=`DB_EM_EMPTY) audio_allowed<=0;
            end
            if(mode==2 && frame2 && !frame_d && rest2 && ((!link_up) ||
               (restore_reply && (status!=`DB_EM_RESTORED || ready2))) && snapshot_ready) begin
                mode<=0;audio_allowed<=0;restore_reply<=0;request_valid<=1;
            end
            if(session_reset || !link_up) begin
                audio_allowed<=0;
                if(input_block && snapshot_ready) request_valid<=1;
            end
            if(alarm_active && mode!=1) begin
                rest1<=0;rest2<=0;
                mode<=1;revision<=revision+1'b1;audio_allowed<=0;restore_reply<=0;status<=`DB_EM_LOADING;
                if(mode==0) begin
                    capture<=~capture;picture_ready<=0;position_ready<=0;snapshot_ready<=0;
                end else request_valid<=snapshot_ready;
            end else if(!alarm_active && mode==1) begin
                mode<=2;revision<=revision+1'b1;audio_allowed<=0;restore_reply<=0;status<=`DB_EM_RECOVERING;
                request_valid<=snapshot_ready;
            end
        end
    end
endmodule
