// TM1650-specific open-drain master. No UI or transport dependencies.
// Transactions: 48 19 (initialise), 49 + one byte + master NACK (poll).
module tm1650_keypad #(parameter CLK_HZ=100000000, parameter STEP_US=4)(
 input wire clk,rst, inout wire scl,sda,
 output reg down,output reg [3:0] key_id,output reg online,output reg cancel);
 localparam DIV=CLK_HZ/1000000*STEP_US;
 reg [$clog2(DIV+1)-1:0] div;
 reg [17:0] wait_steps;
 reg [4:0] state;
 reg scl_low,sda_low,init_read;
 reg [7:0] shift,raw,previous;
 reg [2:0] bit_no;
 reg [1:0] byte_no;
 reg [3:0] recovery;
 reg ack,armed;
 (* async_reg="true" *) reg scl1,scl2,sda1,sda2;
 reg [9:0] stuck;
 assign scl=scl_low ? 1'b0:1'bz;
 assign sda=sda_low ? 1'b0:1'bz;
 always @(posedge clk) begin scl1<=scl;scl2<=scl1;sda1<=sda;sda2<=sda1;end
 always @(posedge clk or posedge rst) begin
  if(rst) begin div<=0;wait_steps<=100000/STEP_US;state<=0;scl_low<=0;sda_low<=0;
   init_read<=0;shift<=0;raw<=0;previous<=8'hff;bit_no<=7;byte_no<=0;
   recovery<=0;ack<=0;armed<=0;down<=0;key_id<=0;online<=0;cancel<=0;stuck<=0;
  end else begin
   cancel<=0;
   if(div==DIV-1) begin
   div<=0;
   // Bounded clock stretching; a failed transaction discards held input.
   if(!scl_low && !scl2 && state!=0 && state!=20) begin
    if(stuck==2000/STEP_US-1) begin state<=0;wait_steps<=500000/STEP_US;stuck<=0;scl_low<=0;sda_low<=0;online<=0;down<=0;armed<=0;init_read<=0;previous<=8'hff;end
    else stuck<=stuck+1'b1;
   end else begin
    stuck<=0;
    case(state)
     0:if(wait_steps!=0) wait_steps<=wait_steps-1'b1;
       else if(!sda2) state<=20;
       else begin sda_low<=1;state<=1;end
     1:begin scl_low<=1;shift<=init_read ? 8'h49:8'h48;bit_no<=7;byte_no<=0;state<=2;end
     2:begin sda_low<=!shift[bit_no];state<=3;end
     3:begin scl_low<=0;state<=4;end
     4:begin scl_low<=1;if(bit_no==0) state<=5;else begin bit_no<=bit_no-1'b1;state<=2;end end
     5:begin sda_low<=0;state<=6;end
     // Capture the stable low-phase ACK immediately before releasing SCL.
     6:begin ack<=!sda2;scl_low<=0;state<=7;end
     7:begin scl_low<=1;state<=8;end
     8:if(!ack) state<=20;
       else if(init_read) begin bit_no<=7;shift<=0;state<=10;end
       else if(byte_no==0) begin byte_no<=1;shift<=8'h19;bit_no<=7;state<=2;end
       else state<=15;
     10:begin sda_low<=0;scl_low<=0;state<=11;end
     11:begin shift[bit_no]<=sda2;scl_low<=1;
       if(bit_no==0) state<=12;else begin bit_no<=bit_no-1'b1;state<=10;end end
     12:begin sda_low<=0;scl_low<=0;state<=13;end
     13:begin scl_low<=1;raw<=shift;state<=15;end
     15:begin scl_low<=1;sda_low<=1;state<=16;end
     16:begin scl_low<=0;state<=17;end
     17:begin sda_low<=0;state<=18;end
     18:begin
       online<=1;state<=0;wait_steps<=init_read ? 10000/STEP_US:5000/STEP_US;init_read<=1;
       if(init_read) begin
        previous<=raw;
        if(raw==previous) begin
         if(raw==0 || (!raw[7] && raw[2] && raw[5:3]<4 && !raw[6])) begin down<=0;armed<=1;end
         else if(!raw[7] && raw[6] && raw[2] && raw[5:3]<4) begin
          if(armed) begin down<=1;key_id<={raw[4:3],raw[1:0]};end
         end else begin down<=0;armed<=0;if(raw!=0 && (down || armed)) cancel<=1;end
        end
       end
     end
     20:begin online<=0;down<=0;armed<=0;previous<=8'hff;init_read<=0;
       scl_low<=1;sda_low<=0;recovery<=0;state<=21;end
     21:begin scl_low<=0;state<=22;end
     22:begin scl_low<=1;
       if(recovery==8) begin sda_low<=1;state<=23;end
       else begin recovery<=recovery+1'b1;state<=21;end end
     23:begin scl_low<=0;state<=24;end
     24:begin sda_low<=0;wait_steps<=500000/STEP_US;state<=0;end
     default:state<=20;
    endcase
   end
  end else div<=div+1'b1;
  end
 end
endmodule
