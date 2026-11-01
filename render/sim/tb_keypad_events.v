`timescale 1ns/1ps
module tb_keypad_events;
 reg clk=0;always #5 clk=~clk;
 reg fault=0;reg rst=1,enabled=1,down=0,online=1,ready=0;reg [3:0] id=0;
 wire valid;wire [5:0] data;reg [5:0] saved;
 keypad_event_encoder #(.CLK_HZ(1000)) dut(.clk(clk),.rst(rst),.cancel(fault),.enabled(enabled),.down(down),.online(online),.key_id(id),.valid(valid),.ready(ready),.data(data));
 task consume;input [5:0] want;begin
  @(negedge clk);if(!valid || data!==want) $fatal(1,"event got %h expected %h",data,want);
  ready=1;@(negedge clk);ready=0;
 end endtask
 initial begin
 repeat(3) @(negedge clk);rst=0;consume(6'b110000);repeat(3) @(negedge clk);
 down=1;id=4;repeat(3) @(negedge clk);saved=data;
 repeat(510) @(negedge clk);if(data!==saved) $fatal(1,"backpressure mutated event");
 consume({2'd0,4'd4});consume({2'd2,4'd4});
 down=0;repeat(3) @(negedge clk);consume({2'd1,4'd4});
 down=1;id=5;repeat(3) @(negedge clk);consume({2'd0,4'd5});
 fault=1;@(negedge clk);fault=0;consume(6'b110000);
 repeat(10) @(negedge clk);if(valid) $fatal(1,"invalid-input cancel replayed key");
 down=0;repeat(3) @(negedge clk);
 online=0;repeat(3) @(negedge clk);consume(6'b110000);
 repeat(10) @(negedge clk);if(valid) $fatal(1,"offline cancel flooding");
 online=1;down=1;repeat(10) @(negedge clk);if(valid) $fatal(1,"reconnect held key");
 down=0;repeat(3) @(negedge clk);down=1;id=9;repeat(1700) @(negedge clk);
 consume(6'b110000);repeat(3) @(negedge clk);if(valid) $fatal(1,"overflow stale events");
 $display("*** PASS *** keypad event repeat/backpressure/recovery/overflow");$finish;
 end
 initial begin #50000;$fatal(1,"timeout");end
endmodule

