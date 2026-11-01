`timescale 1ns/1ps
module tb_keypad_router;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,cancel=0,valid=0,active=0,nav=1,playing=1,new_track=0;
 reg [5:0] data=0;reg [3:0] page=1;
 wire open_menu,back,up,down,left,right,confirm,prev_image,next_image,auto_toggle,pause_toggle,next_track;
 wire volume_up,volume_down,stop_track;integer pauses=0,tracks=0;
 keypad_action_router #(.CLK_HZ(1000)) dut(.clk(clk),.rst(rst),.cancel(cancel),.event_valid(valid),.event_data(data),
 .ui_active(active),.text_osd_page(1'b0),.ui_page(page),.navigable(nav),.playing(playing),.new_track(new_track),
 .volume_up(volume_up),.volume_down(volume_down),.stop_track(stop_track),.open_menu(open_menu),.back(back),.up(up),.down(down),.left(left),.right(right),.confirm(confirm),
 .prev_image(prev_image),.next_image(next_image),.auto_toggle(auto_toggle),.pause_toggle(pause_toggle),.next_track(next_track));
 always @(posedge clk) begin if(pause_toggle) pauses=pauses+1;if(next_track) tracks=tracks+1;end
 task ev;input [1:0] kind;input [3:0] id;begin @(negedge clk);valid=1;data={kind,id};@(negedge clk);valid=0;end endtask
 initial begin
 repeat(3) @(negedge clk);rst=0;repeat(3) @(negedge clk);
 ev(0,5);ev(1,5);repeat(305) @(negedge clk);
 if(pauses!=1 || tracks!=0) $fatal(1,"single click");
 ev(0,5);ev(1,5);repeat(30) @(negedge clk);ev(0,5);ev(1,5);repeat(305) @(negedge clk);
 if(pauses!=1 || tracks!=1) $fatal(1,"double click emitted pause");
 ev(0,5);ev(1,5);cancel=1;@(negedge clk);cancel=0;repeat(305) @(negedge clk);
 if(pauses!=1) $fatal(1,"cancel did not drain click");
 @(negedge clk);valid=1;data=4;#1;if(!prev_image || left) $fatal(1,"background prev");
 @(negedge clk);data=6;#1;if(!next_image) $fatal(1,"background next");
 @(negedge clk);valid=0;active=1;repeat(3) @(negedge clk);
 valid=1;data=5;#1;if(!confirm || next_image) $fatal(1,"menu confirm");
 @(negedge clk);valid=0;page=2;repeat(3) @(negedge clk);
 valid=1;data={2'd2,4'd4};#1;if(left) $fatal(1,"held input crossed page");
 @(negedge clk);data=4;#1;if(!left) $fatal(1,"fresh left");
 @(negedge clk);valid=0;nav=0;@(negedge clk);valid=1;data=5;#1;if(confirm) $fatal(1,"busy confirm");
 @(negedge clk);cancel=1;valid=1;data=4;active=0;#1;if(prev_image) $fatal(1,"cancel did not suppress immediate direction");
 data=12;#1;if(open_menu) $fatal(1,"cancel did not suppress menu open");
 cancel=0;valid=0;playing=0;repeat(3) @(negedge clk);
 valid=1;data=1;#1;if(!volume_up || up) $fatal(1,"No-track volume up");
 @(negedge clk);data={2'd2,4'd9};#1;if(!volume_down) $fatal(1,"Volume repeat");
 @(negedge clk);valid=0;cancel=1;@(negedge clk);cancel=0;valid=1;data={2'd2,4'd9};#1;
 if(volume_down) $fatal(1,"Volume cancelled repeat");
 @(negedge clk);valid=0;active=1;page=4;repeat(3) @(negedge clk);
 valid=1;data=1;#1;if(volume_up || volume_down) $fatal(1,"Menu leaked shortcut");
 @(negedge clk);valid=0;active=0;playing=1;repeat(3) @(negedge clk);
 // A pending 5 click must not pause after physical 9 (row-major ID 10).
 ev(0,5);ev(1,5);
 valid=1;data=10;#1;if(!stop_track || volume_down) $fatal(1,"physical 9 stop mapping");
 @(negedge clk);data={2'd2,4'd10};#1;if(stop_track) $fatal(1,"stop repeated");
 @(negedge clk);data={2'd1,4'd10};#1;if(stop_track) $fatal(1,"stop on release");
 @(negedge clk);valid=0;repeat(305) @(negedge clk);
 if(pauses!=1 || tracks!=1) $fatal(1,"stop retained pending click");
 valid=1;data=10;cancel=1;#1;if(stop_track) $fatal(1,"cancel leaked stop");
 @(negedge clk);cancel=0;playing=0;#1;if(stop_track) $fatal(1,"idle stop");
 @(negedge clk);playing=1;active=1;#1;if(stop_track) $fatal(1,"menu stop");
 $display("*** PASS *** keypad router click/cancel/context/background/physical-9 exit");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
