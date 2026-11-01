// Semantic adapter. The input driver and link never inspect menu state.
module keypad_action_router #(parameter CLK_HZ=100000000)(
 input wire clk,rst,cancel,event_valid,input wire [5:0] event_data,
 input wire ui_active,text_osd_page,input wire [3:0] ui_page,input wire navigable,playing,new_track,
 output wire open_menu,back,up,down,left,right,confirm,prev_image,next_image,auto_toggle,
 output wire volume_up,volume_down,stop_track,
 output reg pause_toggle,next_track);
 wire event_active=event_valid && !cancel;
 wire press=event_active && event_data[5:4]==0;
 wire repeat_ev=event_active && event_data[5:4]==2;
 wire release_ev=event_active && event_data[5:4]==1;
 wire [3:0] id=event_data[3:0];
 reg five_down,pending;reg [$clog2(CLK_HZ/1000+1)-1:0] tick;reg [8:0] window_ms;
 reg active_d,local_d;reg [3:0] page_d;reg blocked;
 wire ms=tick==CLK_HZ/1000-1;
 wire context_change=active_d!=ui_active || page_d!=ui_page || local_d!=text_osd_page;
 wire nav=ui_active && navigable && (press || (repeat_ev && !blocked)) && !context_change;
 wire shortcut_nav=!ui_active && (press || (repeat_ev && !blocked)) && !context_change;
 assign volume_up=shortcut_nav && id==1;
 assign volume_down=shortcut_nav && id==9;
 assign open_menu=press && id==12 && !ui_active;
 assign back=press && id==14 && ui_active;
 assign up=nav && id==1;assign down=nav && id==9;
 assign left=nav && id==4;assign right=nav && id==6;
 assign confirm=nav && press && id==5;
 assign prev_image=press && id==4 && !ui_active;
 assign next_image=press && id==6 && !ui_active;
 assign auto_toggle=press && id==3 && !ui_active;
 // Physical 9 is row-major ID 10 (ID 9 is physical 8 / volume down).
 assign stop_track=press && id==10 && !ui_active && playing;
 always @(posedge clk or posedge rst) begin
  if(rst) begin five_down<=0;pending<=0;window_ms<=0;tick<=0;pause_toggle<=0;next_track<=0;active_d<=0;local_d<=0;page_d<=1;blocked<=1;end
  else begin
   tick<=ms ? 0:tick+1'b1;active_d<=ui_active;local_d<=text_osd_page;page_d<=ui_page;pause_toggle<=0;next_track<=0;
   if(press) blocked<=0;
   if(cancel || context_change || new_track || stop_track || (event_valid && event_data[5:4]==3)) begin
    five_down<=0;pending<=0;window_ms<=0;blocked<=1;
   end else if(ui_active || !playing) begin five_down<=0;pending<=0;window_ms<=0;end
   else if(press && id==5) begin
    if(pending && window_ms!=0) begin next_track<=1;pending<=0;window_ms<=0;five_down<=0;end
    else five_down<=1;
   end else if(release_ev && id==5 && five_down) begin five_down<=0;pending<=1;window_ms<=300;end
   else if(ms && window_ms!=0) begin
    window_ms<=window_ms-1'b1;
    if(window_ms==1 && pending) begin pause_toggle<=1;pending<=0;end
   end
  end
 end
endmodule
