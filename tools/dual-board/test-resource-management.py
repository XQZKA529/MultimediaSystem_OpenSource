from pathlib import Path
from resource_sim import simulate
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'build/resource-v1';BASE=OUT/'base/media';CAND=OUT/'rx_management/media'
work=OUT/'management-equivalence';work.mkdir(parents=True,exist_ok=True)
ref=work/'reference.v';ref.write_text((BASE/'rtl/link/db_mac_rx.v').read_text(encoding='utf-8-sig').replace('module db_mac_rx #(', 'module reference_rx #('))
tb=work/'tb_management.v';tb.write_text('''`include "pkg/board_link.vh"
module tb_management;
`include "db_crc.vh"
reg rx_clk=0,clk=0,rst=1,valid=0,good=0,bad=0,ready=1;
always #4 rx_clk=~rx_clk;always #5 clk=~clk;
reg [7:0] din=0;wire av,ev;wire [127:0] ah,eh;wire [31:0] ae,ee,ad,ed;
db_mac_rx dut(.rst(rst),.rx_clk(rx_clk),.rx_data(din),.rx_valid(valid),.rx_good(good),.rx_bad(bad),.bus_clk(clk),
 .pkt_ready(1'b1),.data_ready(1'b1),.mgmt_valid(av),.mgmt_header(ah),.mgmt_ready(ready),.crc_errors(ae),.rx_drops(ad));
reference_rx ref(.rst(rst),.rx_clk(rx_clk),.rx_data(din),.rx_valid(valid),.rx_good(good),.rx_bad(bad),.bus_clk(clk),
 .pkt_ready(1'b1),.data_ready(1'b1),.mgmt_valid(ev),.mgmt_header(eh),.mgmt_ready(ready),.crc_errors(ee),.rx_drops(ed));
reg [127:0] a[0:511],e[0:511];integer na=0,ne=0,n,k;
always @(posedge clk) if(!rst && ready) begin
 if(av) begin a[na]=ah;na=na+1;end
 if(ev) begin e[ne]=eh;ne=ne+1;end
end
task send;
 input integer id,damage,release_mid;
 reg [255:0] h;reg [31:0] crc;integer b;
 begin
  h={`DB_MAJOR,`DB_MINOR,8'd0,8'd0,32'h91827364+id,32'habcdef12-id,
     32'hfedcba00+id,32'h02000103,32'h04020205,16'd0,id[7:0],8'd2,32'd0};
  if(id%3==0) begin h[127:120]=8'd1;h[39:32]=`DB_HELLO;end
  if(id%7==0) h[99]=~h[99];
  if(damage==3) h[255:248]=8'hff;
  crc=32'hffffffff;for(b=0;b<28;b=b+1)crc=db_crc_byte(crc,h[255-b*8-:8]);h[31:0]=~crc;
  if(damage==1) h[1]=~h[1];
  for(b=0;b<60;b=b+1) begin
   @(negedge rx_clk);valid=1;
   if(release_mid && b==20) ready=1;
   if(b<6)din=`DB_MAC_MEDIA >> ((5-b)*8);
   else if(b<12)din=`DB_MAC_RENDER >> ((11-b)*8);
   else if(b==12)din=8'h88;else if(b==13)din=8'hb5;
   else if(b<46)din=h[255-(b-14)*8-:8];else din=0;
  end
  @(negedge rx_clk);valid=0;
  // Completion near the next start still leaves scratch reads before header writes.
  repeat(id%5) @(negedge rx_clk);
  if(damage==2)bad=1;else good=1;
  @(negedge rx_clk);good=0;bad=0;repeat(12) @(negedge rx_clk);
 end
endtask
initial begin
 #100;rst=0;repeat(8) @(negedge rx_clk);
 for(n=0;n<160;n=n+1) begin
  if(n==30 || n==80 || n==120) ready=0;
  send(n,n%19==0 ? 1:n%23==0 ? 2:n%29==0 ? 3:0,n==42 || n==92 || n==132);
 end
 ready=1;repeat(500) @(negedge clk);
 if(na!=ne || ae!==ee || ad!==ed) $fatal(1,"count mismatch n=%d/%d errors=%d/%d drops=%d/%d",na,ne,ae,ee,ad,ed);
 for(k=0;k<na;k=k+1) if(a[k]!==e[k]) $fatal(1,"management fields differ %d %h %h",k,a[k],e[k]);
 $display("PASS %d complete management descriptors; 160 frames, full/mid-frame recovery, malformed capabilities, CRC/FCS, sessions/32-bit ACKs",na);$finish;
end
initial begin #2000000;$fatal(1,"watchdog");end
endmodule
''')
files=[BASE/'rtl/link/db_packet_ram.v',BASE/'rtl/link/db_async_fifo.v',ref,CAND/'rtl/link/db_mac_rx.v',tb]
for native in [False,True]:simulate(work/('native' if native else 'behavioral'),'tb_management',files,includes=[BASE/'rtl',BASE/'rtl/link'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
