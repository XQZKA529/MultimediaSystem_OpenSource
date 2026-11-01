`timescale 1ns/1ps
module tb_clock_events;
 reg clk=0,rst=1,link=1,sreset=0,cancel=0,active=0,text_page=0,commit=0,seen=0,valid=0,remote_ready=1;
 reg [3:0] page=1;reg [5:0] data=0;
 wire ready,remote_valid,encoder_cancel,edit_enable,ce,cu,cd,cl,cr,cc;wire [5:0] remote_data;
 wire [32:0] live,draft;wire [2:0] focus;wire editing;
 always #5 clk=~clk;
 text_osd_event_router dut(.clk(clk),.rst(rst),.link_up(link),.session_reset(sreset),.input_cancel(cancel),
  .ui_active(active),.text_osd_page(text_page),.ui_page(page),.ui_commit_toggle(commit),.ui_commit_seen(seen),
  .event_valid(valid),.event_data(data),.event_ready(ready),.remote_valid(remote_valid),.remote_data(remote_data),.remote_ready(remote_ready),
  .encoder_cancel(encoder_cancel),.edit_enable(edit_enable),.clock_edit_enable(ce),.clock_up(cu),.clock_down(cd),.clock_left(cl),.clock_right(cr),.clock_confirm(cc));
 calendar_clock #(.CLK_HZ(256)) owner(.clk(clk),.rst(rst),.edit_enable(ce),.cancel(cancel),
  .up(cu),.down(cd),.left(cl),.right(cr),.confirm(cc),.live(live),.draft(draft),.focus(focus),.editing(editing));
 task step;input integer n;begin repeat(n) @(negedge clk);end endtask
 task send;input [5:0] e;begin @(negedge clk);data=e;valid=1;step(1);valid=0;step(1);end endtask
 task close;begin active=0;page=1;commit=~commit;seen=commit;step(8);end endtask
 task open;begin active=1;page=7;commit=~commit;step(8);seen=commit;step(8);end endtask
 initial begin
  step(4);rst=0;step(3);active=1;page=7;commit=~commit;step(8);
  send(6'd5);if(editing || cc || remote_valid) $fatal(1,"Entry key before video ACK");
  seen=commit;step(8);if(!ce || !editing || edit_enable) $fatal(1,"Clock ownership");
  send(6'd6);if(draft[32:26]!=1 || live[32:26]!=0) $fatal(1,"Local year edit");
  send({2'd2,4'd6});if(draft[32:26]!=2) $fatal(1,"Direction repeat");
  send(6'd5);if(live[32:26]!=0) $fatal(1,"Field confirm applied");
  repeat(6) send(6'd9);if(focus!=6) $fatal(1,"APPLY focus");send(6'd5);if(live[32:26]!=2) $fatal(1,"APPLY event");
  @(negedge clk);data=14;valid=1;remote_ready=0;step(3);
  if(!remote_valid || ready || remote_data!=14) $fatal(1,"Backpressure contract");
  remote_ready=1;step(1);valid=0;step(3);if(ce || editing) $fatal(1,"Back did not cancel");
  close;open;cancel=1;step(1);cancel=0;step(8);if(ce || editing || live[32:26]!=2) $fatal(1,"Fault cancellation");
  close;open;link=0;step(8);if(ce || editing || live[32:26]!=2) $fatal(1,"Disconnect reset live");
  link=1;step(8);if(ce) $fatal(1,"Stale reconnect page");
  close;open;sreset=1;step(5);sreset=0;step(5);if(ce || live[32:26]!=2) $fatal(1,"Session reset");
  close;active=1;text_page=1;page=1;commit=~commit;seen=commit;step(8);
  if(!edit_enable || ce) $fatal(1,"Text OSD ownership changed");
  $display("*** PASS *** clock ownership, entry ACK, repeat, apply, backpressure, cancel, disconnect, session reset and Text OSD isolation");$finish;
 end
 initial begin #20000;$fatal(1,"Events watchdog");end
endmodule
