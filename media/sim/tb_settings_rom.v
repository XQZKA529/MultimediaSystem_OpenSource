`timescale 1ns/1ps
module tb_settings_rom;
 reg clk=0;always #5 clk=~clk;
 reg [3:0] page=1;reg [1:0] mode=0;reg [3:0] row=0;reg [4:0] col=0;
 wire [7:0] behavioral,physical;integer p,m,r,c;
 settings_menu_text_rom reference_rom(.clk(clk),.page(page),.mode(mode),.row(row),.col(col),.data(behavioral));
 settings_menu_text_rom_hw physical_rom(.clk(clk),.page(page),.mode(mode),.row(row),.col(col),.data(physical));
 initial begin
  repeat(30) @(negedge clk);
  for(p=1;p<=9;p=p+1) if(p<=5 || p==8 || p==9) for(m=0;m<4;m=m+1) for(r=0;r<9;r=r+1) for(c=0;c<32;c=c+1) begin
   @(negedge clk);page=p;mode=m;row=r;col=c;
   repeat(2) @(posedge clk);#1;
   if(physical!==behavioral) $fatal(1,"ROM initialization/address mismatch page %d row %d col %d: hw %h ref %h",p,r,c,physical,behavioral);
   if(p==1 && r==0 && c==0 && physical!=="S") $fatal(1,"settings title");
   if(p==9 && r==0 && c==0 && physical!=="S") $fatal(1,"saturation title");
   if(p==8 && r==0 && c==0 && physical!=="I") $fatal(1,"interval title");
   if(p==8 && r==2 && c==7 && physical!=="0") $fatal(1,"interval default hundreds");
  end
  for(r=0;r<10;r=r+1) for(c=0;c<32;c=c+1) begin
   @(negedge clk);page=6;mode=0;row=r;col=c;repeat(2) @(posedge clk);#1;
   if(physical!==behavioral || (c>=16 && physical!==32)) $fatal(1,"packed subtitle status ROM");
  end
  $display("*** PASS *** physical EG_PHY_BRAM INIT parameters match menu pages including INTERVAL, SATURATION and subtitle status");$finish;
 end
 initial begin #200000;$fatal(1,"timeout");end
endmodule
