// Bounded ASCII first-line parser. The caller supplies at most 260 bytes.
// Completion is a successful bounded FAT read, not necessarily physical EOF.
module txt_prefix_parser(input wire clk,rst,start,byte_valid,input wire [7:0] byte_data,
 input wire finish,read_ok,input wire [31:0] file_size,
 output reg char_valid,output reg [7:0] char_index,output reg [7:0] char_data,
 output reg done,ok,output reg [8:0] length,output reg truncated,first_line);
 reg [1:0] bom;reg ended,bad;reg [8:0] consumed;
 task character;
  input [7:0] c;
  begin
   if(!ended) begin
    if(c==13 || c==10) begin ended<=1;first_line<=file_size>{24'd0,consumed}+32'd1;end
    else if(c==9 || (c>=32 && c<=126)) begin
     if(length<256) begin char_valid<=1;char_index<=length[7:0];char_data<=c==9 ? 8'd32:c;length<=length+1'b1;end
     else truncated<=1;
    end else bad<=1;
   end
  end
 endtask
 always @(posedge clk or posedge rst) begin
  if(rst) begin bom<=0;ended<=0;bad<=0;consumed<=0;char_valid<=0;char_index<=0;char_data<=0;done<=0;ok<=0;length<=0;truncated<=0;first_line<=0;end
  else begin
   char_valid<=0;done<=0;
   if(start) begin bom<=0;ended<=0;bad<=0;consumed<=0;ok<=0;length<=0;truncated<=0;first_line<=0;end
   else begin
    if(byte_valid) begin
     consumed<=consumed+1'b1;
     // Validate every inspected prefix byte, including bytes after the first
     // line. Line endings and TAB remain allowed; UTF-8 BOM only at offset zero.
     if(ended && byte_data!=9 && byte_data!=10 && byte_data!=13 &&
        (byte_data<32 || byte_data>126)) bad<=1;
     case(bom)
      0:if(consumed==0 && byte_data==8'hef) bom<=1;else character(byte_data);
      1:if(byte_data==8'hbb) bom<=2;else begin bad<=1;bom<=3;end
      2:begin bom<=3;if(byte_data!=8'hbf) bad<=1;end
      3:character(byte_data);
     endcase
    end
    // finish must follow the final byte by at least one clock.
    if(finish) begin done<=1;ok<=read_ok && !bad && bom!=1 && bom!=2;end
   end
  end
 end
endmodule
