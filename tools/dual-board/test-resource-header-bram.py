"""Exact public-cycle RX comparison against the retained pre-BRAM implementation."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);p.add_argument('--tag',default='header-equivalence');a=p.parse_args()
w=a.candidate.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
s=(a.reference/'rtl/link/db_mac_rx.v').read_text(encoding='utf-8-sig')
s=s.replace('module db_mac_rx #(','module reference_rx #(').replace('db_management_word_fifo','reference_management_fifo')
ref=w/'reference.v';ref.write_text(s)
tb=w/'tb_header.v';tb.write_text(r'''`include "pkg/board_link.vh"
module tb_header;
`include "db_crc.vh"
reg rx_clk=0,clk=0,rst=1,valid=0,good=0,bad=0,pr=0,dr=0,mr=0,random_ready=0;
always #4 rx_clk=~rx_clk;always #5 clk=~clk;
reg [7:0] din=0;wire ap,ep,av,ev,al,el,am,em,ax,ex,ay,ey;
wire [255:0] ah,eh;wire [127:0] amh,emh;wire [31:0] ad,ed,ae,ee,an,en;
db_mac_rx #(.BRAM_HEADER(1)) dut(.rst(rst),.rx_clk(rx_clk),.rx_data(din),.rx_valid(valid),.rx_good(good),.rx_bad(bad),
 .bus_clk(clk),.pkt_valid(ap),.pkt_header(ah),.pkt_ready(pr),.data_valid(av),.data(ad),.data_last(al),.data_ready(dr),
 .mgmt_valid(am),.mgmt_header(amh),.mgmt_ready(mr),.crc_errors(ae),.rx_drops(an),.error_seen(ax),.drop_seen(ay));
reference_rx ref(.rst(rst),.rx_clk(rx_clk),.rx_data(din),.rx_valid(valid),.rx_good(good),.rx_bad(bad),
 .bus_clk(clk),.pkt_valid(ep),.pkt_header(eh),.pkt_ready(pr),.data_valid(ev),.data(ed),.data_last(el),.data_ready(dr),
 .mgmt_valid(em),.mgmt_header(emh),.mgmt_ready(mr),.crc_errors(ee),.rx_drops(en),.error_seen(ex),.drop_seen(ey));
wire full_probe=dut.rx_full;
integer checks=0,packets=0,words=0,management=0,full_cycles=0,errors=0,drops=0;
reg [31:0] rng=32'h5e17ab93;
always @(negedge clk) if(random_ready) begin
 rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};pr=rng[0]|rng[5];dr=rng[3];mr=rng[7];
end
always @(posedge clk) begin
 #1;
 if(!rst) begin
  checks=checks+1;
  if({ap,av,al,am,ah,ad,amh,ae,an,ax,ay} !== {ep,ev,el,em,eh,ed,emh,ee,en,ex,ey})
   $fatal(1,"public cycle mismatch cycle=%d header=%h/%h",checks,ah,eh);
  if(ap&&pr)packets=packets+1;if(av&&dr)words=words+1;if(am&&mr)management=management+1;
  if(full_probe)full_cycles=full_cycles+1;
  if(ae!=0)errors=errors+1;if(an!=0)drops=drops+1;
 end
end
function [7:0] payload;input integer id,b;begin payload=(id*37)^(b*13)^(b>>3);end endfunction
task send;
 input integer id,len,mg,damage;
 reg [255:0] h;reg [31:0] crc;integer b,total;
 begin
  h={`DB_MAJOR,`DB_MINOR,8'd1,8'hb7,32'hffffffff-id,32'habcdef12-id,
     32'hfedcba00+id,32'h02000103,32'h04020205,16'd0,id[7:0],8'd2,32'd0};
  h[63:48]=len;h[239:232]=mg ? 0:1;
  if(mg) begin h[127:120]=1;h[39:32]=`DB_HELLO;end
  if(damage==4)h[255:248]=8'hff;
  crc=32'hffffffff;for(b=0;b<28;b=b+1)crc=db_crc_byte(crc,h[255-b*8-:8]);
  for(b=0;b<len;b=b+1)crc=db_crc_byte(crc,payload(id,b));h[31:0]=~crc;
  if(damage==1)h[1]=~h[1];
  total=46+len;if(total<60)total=60;if(damage==5)total=total-1;
  for(b=0;b<total;b=b+1) begin
   @(negedge rx_clk);valid=1;
   if(b<6)din=`DB_MAC_MEDIA >> ((5-b)*8);
   else if(b<12)din=`DB_MAC_RENDER >> ((11-b)*8);
   else if(b==12)din=8'h88;else if(b==13)din=8'hb5;
   else if(b<46)din=h[255-(b-14)*8-:8];else din=payload(id,b-46);
   if(damage==3 && b==0)din=din^1;
  end
  @(negedge rx_clk);valid=0;
  repeat(id%5)@(negedge rx_clk);
  if(damage==2)bad=1;else good=1;
  @(negedge rx_clk);good=0;bad=0;repeat(12)@(negedge rx_clk);
 end
endtask
integer epoch,n,len,damage;
initial begin
 for(epoch=0;epoch<4;epoch=epoch+1)begin
  rst=1;valid=0;good=0;bad=0;random_ready=0;pr=0;dr=0;mr=0;
  #103;rst=0;repeat(8)@(negedge rx_clk);
  // Fill all eight normal slots. Management remains independently usable.
  for(n=0;n<25;n=n+1)send(n+epoch*1000, n%5==0 ? 0:4, n%5==0,0);
  random_ready=1;
  for(n=0;n<250;n=n+1)begin
   case(n%8)0:len=0;1:len=4;2:len=1024;3:len=1020;4:len=12;5:len=256;6:len=1028;7:len=3;endcase
   damage=n%31==0 ? 1:n%37==0 ? 2:n%41==0 ? 3:n%43==0 ? 4:n%47==0 ? 5:0;
   if(n%7==0)send(n+epoch*1000,0,1,damage);else send(n+epoch*1000,len,0,damage);
  end
  random_ready=0;pr=1;dr=1;mr=1;repeat(10000)@(negedge clk);
  // Reset during reception, including unpublished partial RAM writes.
  fork send(12345,1024,0,0);begin repeat(40+epoch*11)@(negedge rx_clk);rst=1;end join
 end
 if(packets<100 || words<1000 || management<50 || full_cycles==0 || errors==0 || drops==0)
  $fatal(1,"coverage missing %d %d %d %d %d %d",packets,words,management,full_cycles,errors,drops);
 $display("PASS %d exact public cycles: %d headers %d payload words %d management; full queue, malformed lengths/MAC/CRC/FCS, wrap, backpressure, independent clocks and reset",checks,packets,words,management);$finish;
end
initial begin #20000000;$fatal(1,"watchdog");end
endmodule
''')
files=[a.candidate/'rtl/link/db_packet_ram.v',ref,a.candidate/'rtl/link/db_mac_rx.v',tb]
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb_header',files,
  includes=[a.candidate/'rtl',a.candidate/'rtl/link'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
