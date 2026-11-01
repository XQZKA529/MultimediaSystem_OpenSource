`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_rx_header_commit;
`include "db_crc.vh"
reg rx_clk=0,clk=0,rst=1,valid=0,good=0,bad=0,accept=1;
reg [7:0] din=0;
always #4 rx_clk=~rx_clk;always #5 clk=~clk;
wire pv,dv,last,mv;wire [255:0] header;wire [127:0] management;
wire [31:0] data,drops,errors;
db_mac_rx #(.LOCAL_MAC(`DB_MAC_RENDER),.PEER_MAC(`DB_MAC_MEDIA)) dut(
 .rst(rst),.rx_clk(rx_clk),.rx_data(din),.rx_valid(valid),.rx_good(good),.rx_bad(bad),
 .bus_clk(clk),.pkt_valid(pv),.pkt_header(header),.pkt_ready(accept),
 .data_valid(dv),.data(data),.data_ready(accept),.data_last(last),
 .mgmt_valid(mv),.mgmt_header(management),.mgmt_ready(1'b1),.crc_errors(errors),.rx_drops(drops));
reg [255:0] expected[0:31];integer expected_count=0,packets=0,completed=0,word_index=0,management_count=0;
integer n,before_packets,before_errors;reg [255:0] held;reg held_valid=0;
reg [31:0] current_id;integer current_words;
function [31:0] payload_word;input [31:0] id;input integer index;
 begin payload_word=32'hfc123000+id+index;end endfunction
always @(posedge clk)if(!rst)begin
 if(held_valid && pv && !accept && header!==held)$fatal(1,"stalled metadata changed");
 held=header;held_valid=pv && !accept;
 if(pv && accept)begin
  if(packets>=expected_count || header!==expected[packets])$fatal(1,"descriptor mismatch packet=%0d",packets);
  current_id=header[127:96];current_words=header[63:48]/4;word_index=0;packets=packets+1;
  if(current_words==0)completed=completed+1;
 end
 if(dv && accept)begin
  if(data!==payload_word(current_id,word_index) || last!==(word_index==current_words-1))
   $fatal(1,"payload mismatch id=%0d word=%0d",current_id,word_index);
  word_index=word_index+1;if(last)completed=completed+1;
 end
 if(mv)management_count=management_count+1;
end
task send_frame;
 input [31:0] id;input integer announced,actual,damage,completion_delay;
 // damage: 1 CRC, 2 address, 3 MAC bad, 4 management frame.
 reg [255:0] h;reg [31:0] crc,p;integer b,length;
 begin
  h={`DB_MAJOR,`DB_MINOR,8'd1,8'h81,64'h123456789abcdef0,
     32'hfedcba98,id,32'h87654321,announced[15:0],8'd2,`DB_IMG_DATA,32'd0};
  if(damage==4)h={`DB_MAJOR,`DB_MINOR,8'd0,8'd0,64'h123456789abcdef0,
     32'd0,32'h01000103,32'h04020205,16'd0,8'd0,`DB_HELLO,32'd0};
  crc=32'hffffffff;
  for(b=0;b<28;b=b+1)crc=db_crc_byte(crc,h[255-b*8-:8]);
  for(b=0;b<actual;b=b+1)begin p=payload_word(id,b/4);crc=db_crc_byte(crc,p[31-(b%4)*8-:8]);end
  h[31:0]=~crc;if(damage==1)h[0]=~h[0];
  if(damage==0 && announced==actual && announced%4==0 && announced<=1024)begin
   expected[expected_count]=h;expected[expected_count][31:0]=0;expected_count=expected_count+1;
  end
  length=46+actual;if(length<60)length=60;
  for(b=0;b<length;b=b+1)begin
   @(negedge rx_clk);valid=1;
   if(b<6)din=(`DB_MAC_RENDER >> ((5-b)*8)) ^ ((damage==2 && b==0)?8'd1:8'd0);
   else if(b<12)din=`DB_MAC_MEDIA >> ((11-b)*8);
   else if(b==12)din=8'h88;else if(b==13)din=8'hb5;
   else if(b<46)din=h[255-(b-14)*8-:8];
   else if(b<46+actual)begin p=payload_word(id,(b-46)/4);din=p[31-((b-46)%4)*8-:8];end
   else din=0;
  end
  @(negedge rx_clk);valid=0;
  repeat(completion_delay)begin
   @(negedge rx_clk);
   if(pv && header[127:96]==id)$fatal(1,"published before MAC completion");
  end
  if(damage==3)bad=1;else good=1;
  @(negedge rx_clk);good=0;bad=0;
  repeat(12)@(negedge rx_clk);
 end
endtask
initial begin
 #100;rst=0;repeat(4)@(negedge rx_clk);
 send_frame(1,0,0,0,3);wait(completed==1);
 send_frame(2,1024,1024,0,20);wait(completed==2);
 for(n=1;n<=3;n=n+1)begin
  before_packets=packets;before_errors=errors;
  send_frame(10+n,4,4,n,5);repeat(30)@(negedge clk);
  if(packets!=before_packets || errors!=before_errors+1)$fatal(1,"bad frame published or miscounted damage=%0d",n);
  send_frame(20+n,4,4,0,1);wait(completed==expected_count);
 end
 before_packets=packets;before_errors=errors;
 send_frame(31,1025,0,0,1);send_frame(32,2,2,0,1);send_frame(33,16,8,0,1);
 repeat(30)@(negedge clk);
 if(packets!=before_packets || errors!=before_errors+3)$fatal(1,"invalid lengths were published");
 send_frame(34,0,0,4,12);wait(management_count==1);
 // Minimum legal inter-frame gaps while the descriptor consumer is stalled.
 accept=0;for(n=0;n<7;n=n+1)send_frame(40+n,4,4,0,0);
 repeat(20)@(negedge clk);accept=1;wait(completed==expected_count);
 if(drops!=0)$fatal(1,"unexpected admission drop %0d",drops);
 $display("*** PASS *** RX header commit: zero/max payload, delayed MAC, CRC/address/MAC rejection, invalid lengths, management, minimum IFG and stalled metadata (%0d descriptors)",packets);
 $finish;
end
initial begin #500000;$fatal(1,"RX header commit watchdog packets=%0d expected=%0d",packets,expected_count);end
endmodule
