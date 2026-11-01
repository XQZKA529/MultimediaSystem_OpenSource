// Raw TEMAC client diagnostic: PRBS31 in both directions, no storage/display.
// Frame: dst6/src6/88B6/sequence4/"PRB1"4/1024 PRBS bytes; MAC adds FCS.
module db_prbs_mac #(
 parameter [47:0] LOCAL_MAC=48'h020000000001,
 parameter [47:0] PEER_MAC=48'h020000000002,
 parameter integer ROLE=1
)(
 input wire rst,tx_clk,rx_clk,phy_ok,
 output reg [7:0] tx_data,output reg tx_valid,input wire tx_ack,
 input wire [7:0] rx_data,input wire rx_valid,rx_good,rx_bad,
 output reg [31:0] tx_frames,rx_frames,fcs_errors,pattern_errors,length_errors,sequence_gaps,
 output wire [41:0] tx_payload_bytes,rx_payload_bytes,
 output reg error_seen
);
 localparam FRAME_BYTES=1046;
 function [30:0] step8;
  input [30:0] x;reg [30:0] v;integer j;
  begin v=x;for(j=0;j<8;j=j+1)v={v[29:0],v[30]^v[27]};step8=v;end
 endfunction
 function [30:0] seed;
  input [31:0] seq;input integer role;reg [30:0] v;
  begin v=(seq^(role*32'h01234567))&32'h7fffffff;seed=v==0?31'd1:v;end
 endfunction
 function [7:0] frame_byte;
  input [10:0] index;input [31:0] seq;input [30:0] prbs;
  begin
   if(index<6)frame_byte=PEER_MAC[47-index*8 -:8];
   else if(index<12)frame_byte=LOCAL_MAC[47-(index-6)*8 -:8];
   else case(index)
    12:frame_byte=8'h88;13:frame_byte=8'hb6;
    14:frame_byte=seq[31:24];15:frame_byte=seq[23:16];
    16:frame_byte=seq[15:8];17:frame_byte=seq[7:0];
    18:frame_byte="P";19:frame_byte="R";20:frame_byte="B";21:frame_byte="1";
    default:frame_byte=prbs[30:23];
   endcase
  end
 endfunction
 (* async_reg="true" *)reg [1:0] tx_release,rx_release;
 (* async_reg="true" *)reg tx_phy1,tx_phy2,rx_phy1,rx_phy2;
 always @(posedge tx_clk or posedge rst)
  if(rst)begin tx_release<=0;tx_phy1<=0;tx_phy2<=0;end
  else begin tx_release<={tx_release[0],1'b1};tx_phy1<=phy_ok;tx_phy2<=tx_phy1;end
 always @(posedge rx_clk or posedge rst)
  if(rst)begin rx_release<=0;rx_phy1<=0;rx_phy2<=0;end
  else begin rx_release<={rx_release[0],1'b1};rx_phy1<=phy_ok;rx_phy2<=rx_phy1;end
 wire tx_rst=~(&tx_release),rx_rst=~(&rx_release);
 reg [1:0] tx_state;
 reg [10:0] tx_index;
 reg [31:0] tx_sequence;
 reg [30:0] tx_prbs;
 reg [3:0] gap;
 assign tx_payload_bytes={tx_frames,10'd0};
 assign rx_payload_bytes={rx_frames,10'd0};
 always @(posedge tx_clk or posedge tx_rst)begin
  if(tx_rst)begin tx_state<=0;tx_index<=0;tx_sequence<=0;tx_prbs<=1;gap<=0;tx_data<=0;tx_valid<=0;tx_frames<=0;end
  else case(tx_state)
   0:if(tx_phy2)begin tx_prbs<=seed(tx_sequence,ROLE);tx_index<=0;tx_data<=PEER_MAC[47:40];tx_valid<=1;tx_state<=1;end
   1:if(tx_ack)begin tx_index<=1;tx_data<=PEER_MAC[39:32];tx_state<=2;end
     else if(!tx_phy2)begin tx_valid<=0;tx_state<=0;end
   2:if(tx_index==FRAME_BYTES-1)begin
      tx_valid<=0;tx_sequence<=tx_sequence+1'b1;tx_frames<=tx_frames+1'b1;gap<=0;tx_state<=3;
     end else begin
      tx_index<=tx_index+1'b1;tx_data<=frame_byte(tx_index+1'b1,tx_sequence,tx_prbs);
      if(tx_index>=21)tx_prbs<=step8(tx_prbs);
     end
   3:if(gap==11)tx_state<=0;else gap<=gap+1'b1;
  endcase
 end
 reg receiving;
 reg [10:0] rx_index;
 reg [31:0] rx_sequence,expected_sequence;
 reg [30:0] rx_prbs;
 reg frame_error,sequence_seen;
 wire [10:0] index_now=receiving?rx_index:11'd0;
 reg byte_error;
 always @*begin
  byte_error=0;
  if(index_now<6)byte_error=rx_data!=LOCAL_MAC[47-index_now*8 -:8];
  else if(index_now<12)byte_error=rx_data!=PEER_MAC[47-(index_now-6)*8 -:8];
  else case(index_now)
   12:byte_error=rx_data!=8'h88;13:byte_error=rx_data!=8'hb6;
   18:byte_error=rx_data!="P";19:byte_error=rx_data!="R";
   20:byte_error=rx_data!="B";21:byte_error=rx_data!="1";
   default:if(index_now>=22)byte_error=rx_data!=rx_prbs[30:23];
  endcase
 end
 always @(posedge rx_clk or posedge rx_rst)begin
  if(rx_rst)begin
   receiving<=0;rx_index<=0;rx_sequence<=0;rx_prbs<=1;frame_error<=0;
   rx_frames<=0;fcs_errors<=0;pattern_errors<=0;length_errors<=0;sequence_gaps<=0;
   expected_sequence<=0;sequence_seen<=0;error_seen<=0;
  end else begin
   if(!rx_phy2)sequence_seen<=0;
   if(rx_valid)begin
    receiving<=1;
    if(index_now<2047)rx_index<=index_now+1'b1;
    if(!receiving)frame_error<=byte_error;else if(byte_error)frame_error<=1;
    case(index_now)
     14:rx_sequence[31:24]<=rx_data;15:rx_sequence[23:16]<=rx_data;
     16:rx_sequence[15:8]<=rx_data;17:rx_sequence[7:0]<=rx_data;
     21:rx_prbs<=seed(rx_sequence,ROLE==1?2:1);
     default:if(index_now>=22)rx_prbs<=step8(rx_prbs);
    endcase
   end else receiving<=0;
   // MAC status arrives after the last client data byte. Do not count a
   // rejected frame as delivered payload, even if its PRBS happened to match.
   if(rx_good||rx_bad)begin
    if(rx_bad)begin fcs_errors<=fcs_errors+1'b1;error_seen<=1;end
    if(rx_index!=FRAME_BYTES)begin length_errors<=length_errors+1'b1;error_seen<=1;end
    if(frame_error)begin pattern_errors<=pattern_errors+1'b1;error_seen<=1;end
    if(rx_good && rx_index==FRAME_BYTES && !frame_error)begin
     rx_frames<=rx_frames+1'b1;
     if(sequence_seen && rx_sequence!=expected_sequence)sequence_gaps<=sequence_gaps+1'b1;
     expected_sequence<=rx_sequence+1'b1;sequence_seen<=1;
    end
   end
  end
 end
endmodule
