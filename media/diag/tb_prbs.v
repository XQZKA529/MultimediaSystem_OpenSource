`timescale 1ns/1ps
module tb_prbs;
 reg a_clk=0,b_clk=0,rst=1,phy=1;
 always #4 a_clk=~a_clk;
 always #4.01 b_clk=~b_clk;
 wire[7:0]at,bt,ar,br;wire av,bv,aa,ba,arv,brv,ag,bg,ab,bb;
 wire[31:0]af,bf,arf,brf,afcs,bfcs,apat,bpat,alen,blen,agap,bgap;
 wire[41:0]atbytes,arbytes,btbytes,brbytes;wire ae,be;
 reg[1:0]mode=0;
 db_prbs_mac a(.rst(rst),.tx_clk(a_clk),.rx_clk(b_clk),.phy_ok(phy),.tx_data(at),.tx_valid(av),.tx_ack(aa),
  .rx_data(ar),.rx_valid(arv),.rx_good(ag),.rx_bad(ab),.tx_frames(af),.rx_frames(arf),.fcs_errors(afcs),.pattern_errors(apat),
  .length_errors(alen),.sequence_gaps(agap),.tx_payload_bytes(atbytes),.rx_payload_bytes(arbytes),.error_seen(ae));
 db_prbs_mac #(.ROLE(2),.LOCAL_MAC(48'h020000000002),.PEER_MAC(48'h020000000001))b(
  .rst(rst),.tx_clk(b_clk),.rx_clk(a_clk),.phy_ok(phy),.tx_data(bt),.tx_valid(bv),.tx_ack(ba),
  .rx_data(br),.rx_valid(brv),.rx_good(bg),.rx_bad(bb),.tx_frames(bf),.rx_frames(brf),.fcs_errors(bfcs),.pattern_errors(bpat),
  .length_errors(blen),.sequence_gaps(bgap),.tx_payload_bytes(btbytes),.rx_payload_bytes(brbytes),.error_seen(be));
 prbs_pipe forward(.clk(a_clk),.rst(rst),.din(at),.valid(av),.ack(aa),.mode(mode),.dout(br),.dv(brv),.good(bg),.bad(bb));
 prbs_pipe backward(.clk(b_clk),.rst(rst),.din(bt),.valid(bv),.ack(ba),.mode(2'd0),.dout(ar),.dv(arv),.good(ag),.bad(ab));
 task fail;input[511:0]why;begin $display("FAIL %0s",why);$finish;end endtask
 initial begin
  #100 rst=0;wait(arf>=20&&brf>=20);#50;
  if(ae||be||afcs||bfcs||apat||bpat||alen||blen||agap||bgap)fail("clean PRBS duplex frame failed");
  if(atbytes!={af,10'd0}||brbytes!={brf,10'd0})fail("payload counters");
  // Independent PRBS31 reference vector: seed 0x01234567, first four bytes.
  if(a.seed(0,1)!=31'h01234567 || a.step8(31'h01234567)!=31'h23456710 || a.step8(31'h23456710)!=31'h45671072)fail("PRBS polynomial/vector");
  mode=1;wait(bpat>=1);mode=0;wait(brf>=23);if(!be)fail("pattern error not sticky");
  mode=2;wait(bfcs>=1);mode=0;wait(brf>=25);
  mode=3;wait(blen>=1);mode=0;wait(brf>=27);
  phy=0;#20000;phy=1;wait(brf>=30&&arf>=30);#100;
  if(apat||afcs||alen)fail("clean reverse direction corrupted");
  $display("*** PASS *** raw PRBS31: duplex/byte order/pattern/FCS/length/PHY recovery counters");$finish;
 end
 initial begin #3000000;fail("watchdog");end
endmodule
module prbs_pipe(input wire clk,rst,input wire[7:0]din,input wire valid,output wire ack,input wire[1:0]mode,
 output reg[7:0]dout,output reg dv,good,bad);
 reg active;reg[1:0]fault;reg[11:0]bytes;
 assign ack=valid&&!active;
 always @(posedge clk or posedge rst)begin
  if(rst)begin active<=0;fault<=0;bytes<=0;dout<=0;dv<=0;good<=0;bad<=0;end
  else begin
   dv<=0;good<=0;bad<=0;
   if(valid)begin
    active<=1;bytes<=active?bytes+1'b1:1;if(!active)fault<=mode;
    dout<=din^((active&&fault==1&&bytes==62)?8'h01:8'h00);
    dv<=!(active&&fault==3&&bytes==1045);
   end else if(active)begin active<=0;good<=fault!=2;bad<=fault==2;end
  end
 end
endmodule
