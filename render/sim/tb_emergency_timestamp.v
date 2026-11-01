`timescale 1ns/1ps
module tb_emergency_timestamp;
 reg publish_frames=1;reg frame_sync=0;always begin #100;frame_sync=publish_frames;#40;frame_sync=0;end
 reg clk=0,vclk=0,rst=1,vrst=1,b0=0,b1=0,down=0;
 reg [3:0] key=11;reg [1:0] mode=0;
 reg edit=0,confirm=0;wire [32:0] live,draft;wire [2:0] focus;wire editing;
 wire [2:0] sources,vsources;wire [8:0] groups,vgroups;wire active,en;
 wire [98:0] times;wire [143:0] vtimes;
 emergency_overlay #(.FRAME_TIMESTAMPS(1)) overlay(.clk(vclk),.rst(vrst),
  .hs(1'b0),.vs(frame_sync),.de(1'b0),.rgb_in(24'd0),.enable(en),
  .sources(vsources),.groups(vgroups),.timestamps(vtimes));
 reg [155:0] frame_snapshot=0;reg frame_vs=0;
 always @(posedge vclk) begin
  if(vrst) begin frame_snapshot=0;frame_vs=0;end
  else begin
   if(!frame_sync && frame_vs) begin
    #1;frame_snapshot={overlay.frame_sources,overlay.frame_groups,overlay.frame_timestamps};
   end else if(!frame_sync) begin
    #1;if(overlay.active && {overlay.frame_sources,overlay.frame_groups,overlay.frame_timestamps}!==frame_snapshot)
     $fatal(1,"production CDC/overlay changed during active frame");
   end
   frame_vs=frame_sync;
  end
 end

 reg [32:0] sampled=0;reg [98:0] expected=0;reg [2:0] adds;
 reg [32:0] old_time,new_time;reg [143:0] saved_digits;
 reg [8:0] saved_groups;reg [2:0] saved_sources;integer checks=0,k;reg [156:0] previous_view=0;reg previous_vs=0;
 always @(posedge vclk) begin
  previous_vs=frame_sync;previous_view={en,vsources,vgroups,vtimes};
  #1;if(!vrst && (({en,vsources,vgroups}!==previous_view[156:144]) || (en && {en,vsources,vgroups,vtimes}!==previous_view)) && !frame_sync)
   $fatal(1,"CDC snapshot changed outside frame boundary");
 end
 always #5 clk=~clk;always #7 vclk=~vclk;
 calendar_clock #(.CLK_HZ(20)) calendar(.clk(clk),.rst(rst),.edit_enable(edit),.cancel(1'b0),
  .up(1'b0),.down(1'b0),.left(1'b0),.right(1'b0),.confirm(confirm),
  .live(live),.draft(draft),.focus(focus),.editing(editing));
 emergency_inputs #(.FILTER_CYCLES(4)) inputs(.clk(clk),.rst(rst),.gpio_b0(b0),.gpio_b1(b1),
  .key_down(down),.key_online(1'b1),.key_cancel(1'b0),.key_id(key),.clock_live(live),
  .sources(sources),.groups(groups),.timestamps(times),.active(active));
 emergency_view_cdc view(.clk(clk),.rst(rst),.mode(mode),.sources(sources),.groups(groups),.timestamps(times),
  .video_clk(vclk),.video_rst(vrst),.enable(en),.video_sources(vsources),.video_groups(vgroups),.video_timestamps(vtimes),.vs(frame_sync));
 function [32:0] pack;
  input integer y,m,d,h,n,s;begin pack={y[6:0],m[3:0],d[4:0],h[4:0],n[5:0],s[5:0]};end
 endfunction
 function [7:0] decimal_pair;
  input integer n;begin decimal_pair=((n/10)<<4)|(n%10);end
 endfunction
 function [47:0] digits;
  input [32:0] t;
  begin digits={decimal_pair(t[32:26]),decimal_pair(t[25:22]),decimal_pair(t[21:17]),
   decimal_pair(t[16:12]),decimal_pair(t[11:6]),decimal_pair(t[5:0])};end
 endfunction
 // Every published input record must equal the pre-confirmation calendar,
 // including confirmation on the very edge that ticks or applies a draft.
 always @(posedge clk) begin
  if(rst) begin expected=0;sampled=0;end
  else begin
   adds=inputs.confirmed_sources & ~sources;
   if(adds[0]) expected[32:0]=sampled;
   if(adds[1]) expected[65:33]=sampled;
   if(adds[2]) expected[98:66]=sampled;
   if(|(inputs.next_sources & ~inputs.confirmed_sources)) sampled=live;
   #1;if(times!==expected) $fatal(1,"timestamp alignment got=%h expected=%h",times,expected);
   checks=checks+1;
  end
 end
 task step;input integer n;begin repeat(n) @(negedge clk);end endtask
 task press;begin down=0;step(3);down=1;step(3);down=0;step(3);end endtask
 task settled;
  reg [143:0] want;
  begin
   step(450);want={digits(times[98:66]),digits(times[65:33]),digits(times[32:0])};
   if(sources!=0) begin
    if(!en || vsources!==sources || vgroups!==groups || vtimes!==want)
     $fatal(1,"CDC complete snapshot got=%h expected=%h sources=%h groups=%h",vtimes,want,vsources,vgroups);
   end else if(mode==0 && en) $fatal(1,"normal mode still enabled");
  end
 endtask
 task reset_all;begin
  rst=1;vrst=1;b0=0;b1=0;down=0;mode=0;edit=0;confirm=0;step(5);rst=0;vrst=0;step(5);
 end endtask
 initial begin
  reset_all;
  b0=1;b1=1;step(12);
  if(sources!=3 || groups!=3 || times[32:0]!==times[65:33]) $fatal(1,"tied GPIO timestamps");
  old_time=times[32:0];press;
  if(sources!=7 || groups!=35 || times[98:66]==old_time) $fatal(1,"later source timestamp");
  settled;if(times[32:0]!=old_time) $fatal(1,"live clock rewrote source time");
  b0=0;step(12);settled;if(groups!=34) $fatal(1,"partial removal");
  b0=1;step(12);settled;if(groups!=98 || times[32:0]==old_time) $fatal(1,"retrigger timestamp/order");
  // Changes faster than a conversion must converge on one coherent newest view.
  b1=0;step(12);b1=1;step(12);press;step(5);press;settled;
  // Backpressure may hide a clear/retrigger that returns to the same group.
  // It must still republish the new time after the old mailbox is acknowledged.
  press;settled;publish_frames=0;press;wait(view.request);step(1);
  old_time=times[98:66];press;step(30);press;
  if(sources!=7 || times[98:66]==old_time) $fatal(1,"backpressured reentry setup");
  publish_frames=1;settled;
  // Reset the consumer only, with identical bus state: it must be republished.
  vrst=1;step(8);vrst=0;settled;
  // Retain the last alarm frame throughout restore, including the final time.
  b0=0;b1=0;step(12);settled;
  saved_digits=vtimes;saved_groups=vgroups;saved_sources=vsources;
  mode=2;press;step(12);settled;
  if(sources!=0 || !en || vtimes!==saved_digits || vgroups!==saved_groups || vsources!==saved_sources)
   $fatal(1,"recovery lost the last complete timestamp view");
  mode=0;settled;
  // Normal release is decided AFTER VS rising by the business controller.
  // It must be received in this same blanking window, not one frame later.
  reset_all;press;settled;mode=2;press;settled;
  force frame_sync=1;step(20);mode=0;step(220);
  if(en) $fatal(1,"release missed the current vertical-sync window");
  force frame_sync=0;step(5);if(overlay.active) $fatal(1,"picture release lagged audio by a frame");
  release frame_sync;step(5);
  // Ticks at date boundaries, checked directly against independent vectors.
  for(k=0;k<5;k=k+1) begin
   reset_all;
   case(k)
    0:begin old_time=pack(0,2,29,23,59,59);new_time=pack(0,3,1,0,0,0);end
    1:begin old_time=pack(1,2,28,23,59,59);new_time=pack(1,3,1,0,0,0);end
    2:begin old_time=pack(26,4,30,23,59,59);new_time=pack(26,5,1,0,0,0);end
    3:begin old_time=pack(26,12,31,23,59,59);new_time=pack(27,1,1,0,0,0);end
    4:begin old_time=pack(99,12,31,23,59,59);new_time=pack(0,1,1,0,0,0);end
   endcase
   calendar.live=old_time;calendar.fraction=19;down=1;
   step(1);if(live!==new_time) $fatal(1,"date boundary tick %d",k);
   step(2);down=0;if(times[98:66]!==old_time) $fatal(1,"tick edge captured post-tick time");
   settled;
  end
  // APPLY and a C confirmation coincide. The applied clock does not rewrite
  // the trigger's pre-edge value, even when APPLY wins over a second tick.
  reset_all;edit=1;step(3);old_time=pack(26,10,14,15,30,59);new_time=pack(30,1,1,12,34,56);
  calendar.live=old_time;calendar.fraction=19;calendar.draft=new_time;calendar.focus=6;
  confirm=1;down=1;step(1);confirm=0;edit=0;
  if(live!==new_time) $fatal(1,"APPLY did not win tick");
  step(2);down=0;if(times[98:66]!==old_time) $fatal(1,"APPLY edge captured new draft");settled;
  // Different confirmation cycles in one second remain separate groups.
  reset_all;calendar.fraction=0;b0=1;step(8);old_time=times[32:0];down=1;step(2);
  if(groups!=33 || times[98:66]!==old_time) $fatal(1,"same-second order collapsed");
  down=0;settled;
  // Decimal conversion across every supported year and varied calendar fields.
  reset_all;
  for(k=0;k<100;k=k+1) begin
   old_time=pack(k,(k%12)+1,(k%28)+1,k%24,(k*7)%60,(k*11)%60);
   calendar.live=old_time;calendar.fraction=0;press;
   if(times[98:66]!==old_time) $fatal(1,"year/field capture %d",k);
   settled;press;
  end
  // System reset clears records; a high GPIO is captured again after filtering.
  rst=1;vrst=1;b0=1;step(4);if(times!=0) $fatal(1,"reset did not clear timestamps");
  rst=0;vrst=0;step(12);if(sources!=1 || times[32:0]==0) $fatal(1,"boot-high timestamp");settled;
  $display("*** PASS *** %0d timestamp cycles: ties, same-second order, freeze, remove/retrigger, conversion churn/backpressure, 100 years/varied fields, video reset, recovery/same-frame release, leap/month/year wrap and tick/APPLY pre-edge capture",checks);$finish;
 end
 initial begin #2000000;$fatal(1,"timeout");end
endmodule
