// Two-channel SD sector model with a real FAT32 root and two PCM WAV files.
// No PHY timing is modelled. Production FAT/map/lba/WAV paths consume every byte.
module sd_card_sdio #(
 parameter CLK_FREQ_HZ=100000000,SD_CLK_DIV_INIT=125,SD_CLK_DIV_FAST=2,SD_CLK_DIV_HS=1,
 parameter SAMPLE_DLY=0,SPEED_TARGET=1
)(input wire clk,rst,output wire SD_CLK,inout wire SD_CMD,input wire SD_DAT0,SD_DAT1,SD_DAT2,SD_DAT3,
 output wire sd_init_done,sd_init_error,output wire [7:0] sd_init_err_code,output wire sd_high_speed,
 output wire [1:0] sd_bus_width,output wire sd_is_sdhc,output wire [15:0] sd_card_rca,
 input wire ch0_req,input wire [31:0] ch0_sector,input wire [15:0] ch0_count,
 output wire ch0_grant,output wire [7:0] ch0_data,output wire ch0_data_valid,ch0_end,ch0_error,
 input wire ch1_req,input wire [31:0] ch1_sector,input wire [15:0] ch1_count,
 output wire ch1_grant,output wire [7:0] ch1_data,output wire ch1_data_valid,ch1_end,ch1_error,
 output wire [4:0] dbg_state,output wire [5:0] dbg_resp_cmd,output wire [31:0] dbg_resp_arg,
 output wire [7:0] dbg_switch_fn,output wire [15:0] dbg_clk_div);
 assign SD_CLK=clk;assign SD_CMD=1'bz;
 assign sd_init_done=!rst;assign sd_init_error=0;assign sd_init_err_code=0;assign sd_high_speed=0;
 assign sd_bus_width=1;assign sd_is_sdhc=1;assign sd_card_rca=1;
 assign dbg_state=0;assign dbg_resp_cmd=0;assign dbg_resp_arg=0;assign dbg_switch_fn=0;assign dbg_clk_div=1;
 reg channel=0,busy=0,grant=0,valid=0,ending=0,bad_restore_body=0;reg [7:0] data=0;
 integer base=0,pos=0,total=0;
 assign ch0_grant=grant && !channel;assign ch1_grant=grant && channel;
 assign ch0_data=data;assign ch1_data=data;
 assign ch0_data_valid=valid && !channel;assign ch1_data_valid=valid && channel;
 assign ch0_end=ending && !channel;assign ch1_end=ending && channel;
 assign ch0_error=0;assign ch1_error=ending && channel &&
  ((base>=321*512 && base<449*512 && $test$plusargs("EM_READ_ERROR")) ||
   (bad_restore_body && base>=194*512 && base<321*512));
 reg [7:0] disk[0:262143];integer i,j,b,mono,frames,bytes;reg [87:0] name;
 task put16;input integer a;input [15:0] v;begin disk[a]=v[7:0];disk[a+1]=v[15:8];end endtask
 task put32;input integer a;input [31:0] v;begin put16(a,v[15:0]);put16(a+2,v[31:16]);end endtask
 task tag;input integer a;input [31:0] v;begin disk[a]=v[31:24];disk[a+1]=v[23:16];disk[a+2]=v[15:8];disk[a+3]=v[7:0];end endtask
 initial begin
  mono=$test$plusargs("EM_MONO");frames=8000;bytes=frames*(mono ? 2:4);
  for(i=0;i<262144;i=i+1) disk[i]=0;
  put16(11,512);disk[13]=128;put16(14,1);disk[16]=1;put32(32,7000);put32(36,64);put32(44,2);
  disk[510]=8'h55;disk[511]=8'haa;
  for(i=0;i<6;i=i+1) put32(512+4*i,32'h0fffffff);
  for(j=0;j<3;j=j+1) begin
   name=j==0 ? "SONG    WAV":j==2 ? "NEXT    WAV":($test$plusargs("EM_MISSING") ? "OTHER   WAV":"EMERG   WAV");
   for(i=0;i<11;i=i+1) disk[65*512+j*32+i]=name[(10-i)*8+:8];
   disk[65*512+j*32+11]=8'h20;put16(65*512+j*32+26,3+j);put32(65*512+j*32+28,44+bytes);
   b=(193+j*128)*512;
   tag(b,"RIFF");put32(b+4,36+bytes);tag(b+8,"WAVE");tag(b+12,"fmt ");put32(b+16,16);
   put16(b+20,1);put16(b+22,mono ? 1:2);put32(b+24,48000);put32(b+28,48000*(mono ? 2:4));
   put16(b+32,mono ? 2:4);put16(b+34,16);tag(b+36,"data");put32(b+40,bytes);
   for(i=0;i<frames;i=i+1) begin
    put16(b+44+i*(mono ? 2:4),(j==0 ? 1000:j==2 ? 6000:16000)+i);
    if(!mono) put16(b+46+i*4,-((j==0 ? 1000:j==2 ? 6000:16000)+i));
   end
  end
 end
 always @(posedge clk) begin
  grant<=0;valid<=0;ending<=0;
  if(rst) begin busy<=0;pos<=0;end
  else if(!busy && !ending && (ch0_req || ch1_req)) begin
   channel<=!ch0_req;base<=(ch0_req ? ch0_sector:ch1_sector)*512;
   total<=(ch0_req ? ch0_count:ch1_count)*512;pos<=0;busy<=1;grant<=1;
  end else if(busy && !grant) begin
   data<=disk[base+pos];valid<=1;pos<=pos+1;
   if(pos==total-1) begin busy<=0;ending<=1;end
  end
 end
endmodule
