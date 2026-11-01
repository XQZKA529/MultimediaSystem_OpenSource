// Device-neutral event ownership. The encoder remains unaware of menus.
module text_osd_event_router(
    input wire clk,rst,link_up,session_reset,input_cancel,
    input wire ui_active,text_osd_page,ui_commit_toggle,ui_commit_seen,input wire [3:0] ui_page,
    input wire event_valid,input wire [5:0] event_data,output wire event_ready,
    output wire remote_valid,output wire [5:0] remote_data,input wire remote_ready,
    output wire encoder_cancel,edit_enable,up,down,left,right,confirm,
    output wire clock_edit_enable,clock_up,clock_down,clock_left,clock_right,clock_confirm
);
    (* async_reg="true" *) reg ack1,ack2;
    reg commit_seen,fresh,owner_d,ready_d,exit_pending,clock_cancelled;
    wire new_snapshot=ui_commit_toggle!=commit_seen;
    wire clock_owner=ui_page===4'd7;
    wire owner=fresh && ui_active && (text_osd_page || clock_owner);
    wire ready_local=link_up && !session_reset && owner &&
                     ack2==ui_commit_toggle && !exit_pending && !(clock_owner && clock_cancelled);
    assign encoder_cancel=(owner!=owner_d) || (ready_local && !ready_d);
    wire cancel_ev=event_data[5:4]==3;
    wire back_ev=event_data[3:0]==14;
    // During transitions discard editing events, but always drain CANCEL.
    wire forward=cancel_ev || (fresh && (!owner || (back_ev && !exit_pending)));
    assign remote_valid=event_valid && forward && link_up && !session_reset &&
                        (!encoder_cancel || cancel_ev) && (!input_cancel || cancel_ev);
    assign remote_data=event_data;
    assign event_ready=forward ? remote_ready && link_up && !session_reset &&
                       (!encoder_cancel || cancel_ev) && (!input_cancel || cancel_ev):1'b1;
    wire fire=event_valid && event_ready;
    wire press=event_data[5:4]==0;
    wire nav_ev=press || event_data[5:4]==2;
    wire local_enable=ready_local && !encoder_cancel && !input_cancel;
    assign edit_enable=local_enable && !clock_owner;
    assign clock_edit_enable=local_enable && clock_owner;
    assign clock_up=fire && clock_edit_enable && nav_ev && event_data[3:0]==1;
    assign clock_down=fire && clock_edit_enable && nav_ev && event_data[3:0]==9;
    assign clock_left=fire && clock_edit_enable && nav_ev && event_data[3:0]==4;
    assign clock_right=fire && clock_edit_enable && nav_ev && event_data[3:0]==6;
    assign clock_confirm=fire && clock_edit_enable && press && event_data[3:0]==5;
    assign up=fire && edit_enable && nav_ev && event_data[3:0]==1;
    assign down=fire && edit_enable && nav_ev && event_data[3:0]==9;
    assign left=fire && edit_enable && nav_ev && event_data[3:0]==4;
    assign right=fire && edit_enable && nav_ev && event_data[3:0]==6;
    assign confirm=fire && edit_enable && press && event_data[3:0]==5;
    always @(posedge clk or posedge rst) begin
        if(rst) begin ack1<=0;ack2<=0;commit_seen<=0;fresh<=0;owner_d<=0;ready_d<=0;exit_pending<=0;clock_cancelled<=0;end
        else begin
            ack1<=ui_commit_seen;ack2<=ack1;
            commit_seen<=ui_commit_toggle;owner_d<=owner;ready_d<=ready_local;
            if(!ui_active || !clock_owner || !link_up || session_reset) clock_cancelled<=0;
            else if(input_cancel) clock_cancelled<=1;
            if(!link_up || session_reset) begin fresh<=0;exit_pending<=0;end
            else begin
                if(new_snapshot) begin
                    fresh<=1;
                    // An older local-page snapshot cannot undo a requested exit.
                    if(!ui_active || (!text_osd_page && !clock_owner)) exit_pending<=0;
                end
                if(fire && remote_valid && owner && back_ev && press) exit_pending<=1;
            end
        end
    end
endmodule
