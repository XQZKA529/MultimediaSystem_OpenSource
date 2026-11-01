// Receive one 264-byte snapshot into the invisible bank, then publish at VS.
// Four-phase handshake retains RAM ownership until video acknowledgement.
module sd_subtitle_view(
 input wire clk,rst,session_reset,start,input wire [31:0] revision,
 output wire start_ready,input wire data_valid,input wire [31:0] data,input wire last,output wire data_ready,
 output wire applied,input wire applied_ready,output wire [31:0] applied_revision,output wire [1:0] applied_result,
 input wire video_clk,video_rst,vs,input wire [31:0] display_image_id,input wire image_valid,mix_active,
 input wire [7:0] text_addr,output wire [7:0] text_data,output wire [14:0] metadata,output wire selected,output reg video_commit);
 localparam IDLE=0,RECEIVE=1,WAIT_ACK=2,WAIT_LOW=3,RESULT=4;
 reg [2:0] state;
 reg [6:0] words;reg [12:0] flags,view_flags;
 reg [31:0] binding,view_binding,revision_q;
 reg bad,bank,front,request,ack,vs_d;
 reg [1:0] result,video_result;
 reg epoch,mail_epoch;
 reg alive,alive1,alive2,alive_d,restore_pending,cache_valid,cache_bank;
 reg [12:0] cache_flags;reg [31:0] cache_binding,cache_revision;
 (* async_reg="true" *) reg req1,req2,ack1,ack2,front1,front2,epoch1,epoch2;
 reg [1:0] write_count;reg [15:0] second_half;reg [6:0] write_index;
 wire [15:0] qa,qb;
 wire take=data_valid && data_ready && state==RECEIVE;
 wire first_half=take && words>=2;
 wire ram_we=first_half || write_count!=0;
 wire [6:0] pair_index=first_half ? ((words-7'd2)<<1):write_index;
 subtitle_ram u_ram(.clk(clk),.wr_en(ram_we && !session_reset && !rst),
 .addr_a({3'd0,bank,pair_index}),.data_a(first_half ? data[31:16]:second_half),.q_a(qa),
 .rd_clk(video_clk),.addr_b({3'd0,front,text_addr[7:1]}),.q_b(qb));
 reg odd,in_range;
 always @(posedge video_clk) begin odd<=text_addr[0];in_range<=!video_rst && {1'b0,text_addr}<view_flags[8:0];end
 assign text_data=in_range ? (odd ? qb[7:0]:qb[15:8]):8'd0;
 assign selected=view_flags[9];
 wire bound_ok=!view_flags[10] || (image_valid && !mix_active && view_binding==display_image_id);
 assign metadata={view_flags[9] && bound_ok,5'd0,view_flags[8:0]};
 assign start_ready=state==IDLE && alive2 && !restore_pending;
 assign data_ready=state==RECEIVE && write_count==0;
 assign applied=state==RESULT;
 assign applied_revision=revision_q;assign applied_result=result;
 function byte_ok;input [7:0] c;input [8:0] i,len;
  begin byte_ok=i<len ? (c>=32 && c<=126):c==0;end
 endfunction
 wire [8:0] byte_base=(words-7'd2)<<2;
 wire word_ok=byte_ok(data[31:24],byte_base,flags[8:0]) &&
  byte_ok(data[23:16],byte_base+9'd1,flags[8:0]) &&
  byte_ok(data[15:8],byte_base+9'd2,flags[8:0]) && byte_ok(data[7:0],byte_base+9'd3,flags[8:0]);
 reg receive_finished,receive_ok;
 always @(posedge clk or posedge rst) begin
  if(rst) begin state<=IDLE;words<=0;flags<=0;binding<=0;revision_q<=0;bad<=0;bank<=1;request<=0;
   ack1<=0;ack2<=0;front1<=0;front2<=0;result<=0;write_count<=0;write_index<=0;second_half<=0;
   alive1<=0;alive2<=0;alive_d<=0;restore_pending<=0;cache_valid<=0;cache_bank<=0;cache_flags<=0;cache_binding<=0;cache_revision<=0;
   epoch<=0;mail_epoch<=0;receive_finished<=0;receive_ok<=0;
  end else begin
   alive1<=alive;alive2<=alive1;alive_d<=alive2;
   if(alive2 && !alive_d && cache_valid) restore_pending<=1;
   ack1<=ack;ack2<=ack1;front1<=front;front2<=front1;
   if(session_reset) epoch<=~epoch;
   if(write_count!=0) write_count<=write_count-1'b1;
   case(state)
    IDLE:if(restore_pending && alive2) begin
      flags<=cache_flags;binding<=cache_binding;revision_q<=cache_revision;bank<=cache_bank;mail_epoch<=epoch;request<=1;state<=WAIT_ACK;restore_pending<=0;
     end else if(start && start_ready) begin state<=RECEIVE;words<=0;bad<=0;revision_q<=revision;bank<=~front2;receive_finished<=0;mail_epoch<=epoch;end
    RECEIVE:begin
     if(take) begin
      words<=words+1'b1;
      if(words==0) begin flags<=data[12:0];if(data[31:13]!=0 || data[8:0]>256) bad<=1;end
      else if(words==1) begin binding<=data;if(!flags[10] && data!=0) bad<=1;end
      else begin
       second_half<=data[15:0];write_index<=pair_index+1'b1;write_count<=1;
       if(!word_ok) bad<=1;
      end
      if(last) begin receive_finished<=1;receive_ok<=words==65 && !bad && (words<2 || word_ok);end
      else if(words>=65) begin bad<=1;end
     end
     if(receive_finished && write_count==0) begin
      receive_finished<=0;
      if(receive_ok) begin request<=1;state<=WAIT_ACK;end
      else begin result<=2;state<=RESULT;end
     end
    end
    WAIT_ACK:if(ack2) begin
     result<=video_result;request<=0;state<=WAIT_LOW;
     if(video_result==0) begin cache_valid<=1;cache_bank<=bank;cache_flags<=flags;cache_binding<=binding;cache_revision<=revision_q;end
    end
    WAIT_LOW:if(!ack2) state<=RESULT;
    RESULT:if(applied_ready) state<=IDLE;
    default:state<=IDLE;
   endcase
   // A complete published bank remains owned until the handshake retires.
   // Session changes invalidate its epoch; partial packets can be discarded.
   if(session_reset && (state==IDLE || state==RECEIVE || state==RESULT)) begin state<=IDLE;write_count<=0;receive_finished<=0;end
  end
 end
 always @(posedge video_clk or posedge video_rst) begin
  if(video_rst) begin req1<=0;req2<=0;ack<=0;front<=0;view_flags<=0;view_binding<=0;vs_d<=0;video_result<=0;epoch1<=0;epoch2<=0;alive<=0;video_commit<=0;end
  else begin
   alive<=1;req1<=request;req2<=req1;epoch1<=epoch;epoch2<=epoch1;vs_d<=vs;video_commit<=0;
   if(!req2) ack<=0;
    else if(vs && !vs_d && !ack) begin
    ack<=1;
    if(mail_epoch!=epoch2) video_result<=2;
    else if(flags[10] && flags[9] && image_valid && binding!=display_image_id) video_result<=1;
    else begin view_flags<=flags;view_binding<=binding;front<=bank;video_result<=0;video_commit<=1;end
   end
  end
 end
endmodule
