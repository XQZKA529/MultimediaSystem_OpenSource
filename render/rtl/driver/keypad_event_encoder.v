// Device-neutral input events: {kind[1:0], row-major key[3:0]}.
// 0=press, 1=release, 2=repeat, 3=cancel. Eight register entries.
module keypad_event_encoder #(parameter CLK_HZ=100000000)(
 input wire clk,rst,cancel,enabled,down,online,input wire [3:0] key_id,
 output wire valid,input wire ready,output wire [5:0] data);
 reg [5:0] fifo[0:7];reg [2:0] rd,wr;reg [3:0] count;
 reg held,armed,was_online;reg [3:0] held_id;
 reg [$clog2(CLK_HZ/1000+1)-1:0] tick;
 reg [8:0] repeat_ms;
 reg cancel_pending;
 wire pop=valid && ready;
 wire direction=held_id==1 || held_id==4 || held_id==6 || held_id==9;
 wire ms=tick==CLK_HZ/1000-1;
 wire release_ev=held && (!down || key_id!=held_id);
 wire press_ev=armed && down && !held;
 wire repeat_ev=held && direction && ms && repeat_ms==1 && !release_ev;
 wire push=enabled && online && (release_ev || press_ev || repeat_ev);
 wire [5:0] event_data=release_ev ? {2'd1,held_id}:press_ev ? {2'd0,key_id}:{2'd2,held_id};
 assign valid=enabled && (cancel_pending || count!=0);
 assign data=cancel_pending ? 6'b110000:fifo[rd];
 always @(posedge clk or posedge rst) begin
  if(rst) begin rd<=0;wr<=0;count<=0;held<=0;armed<=0;held_id<=0;tick<=0;repeat_ms<=0;cancel_pending<=1;was_online<=0;end
  else begin
   tick<=ms ? 0:tick+1'b1;was_online<=online;
   if(!enabled || cancel || (was_online && !online)) begin
    rd<=0;wr<=0;count<=0;held<=0;armed<=0;repeat_ms<=0;cancel_pending<=1;
   end else if(cancel_pending) begin
    if(ready) cancel_pending<=0;
   end else if(online) begin
    if(!down) armed<=1;
    if(release_ev) begin held<=0;repeat_ms<=0;end
    else if(press_ev) begin held<=1;held_id<=key_id;repeat_ms<=500;end
    else if(ms && repeat_ms!=0) repeat_ms<=repeat_ms==1 ? 150:repeat_ms-1'b1;
    if(push && count==8 && !pop) begin
     count<=0;rd<=0;wr<=0;held<=0;armed<=0;cancel_pending<=1;
    end else begin
     if(push) begin fifo[wr]<=event_data;wr<=wr+1'b1;end
     if(pop) rd<=rd+1'b1;
     case({push,pop}) 2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:;endcase
    end
   end
  end
 end
endmodule
