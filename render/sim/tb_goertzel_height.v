`timescale 1ns/1ps
module tb_goertzel_height;
 wire a,b;
 goertzel_height_case #(.WIDTH(25),.OFFSET(10),.MAX_HEIGHT(22)) x(a);
 goertzel_height_case #(.WIDTH(26),.OFFSET(7),.MAX_HEIGHT(21)) y(b);
 initial begin wait(a && b);$display("*** PASS *** exact signed height: power-of-two +/-1 boundaries, negative minimum, random states, 25/26 bits and odd clamp");$finish;end
endmodule
module goertzel_height_case #(parameter WIDTH=25,OFFSET=10,MAX_HEIGHT=22)(output reg done=0);
 reg [WIDTH-1:0] value;
 integer i,n,m,level,height,checks=0;
 reg [WIDTH-1:0] magnitude;
 audio_goertzel_osd #(.STW(WIDTH),.LOG_OFF(OFFSET),.HMAX(MAX_HEIGHT)) dut(
  .clk(1'b0),.rst(1'b1),.vs(1'b0),.pcm_valid(1'b0),.pcm_left(24'd0),.pcm_right(24'd0),
  .play_run(1'b0),.paused(1'b0),.stream_restart(1'b0),.heights());
 task verify;
  begin
   magnitude=value[WIDTH-1] ? (~value+1'b1):value;level=0;
   for(m=0;m<WIDTH;m=m+1)if(magnitude[m])level=m;
   height=level>OFFSET ? 2*(level-OFFSET):0;if(height>MAX_HEIGHT)height=MAX_HEIGHT;
   if(dut.signed_height(value)!==height[4:0])$fatal(1,"height WIDTH=%0d value=%h got=%0d expected=%0d",WIDTH,value,dut.signed_height(value),height);
   checks=checks+1;
  end
 endtask
 initial begin
  value=0;verify;value={1'b1,{(WIDTH-1){1'b0}}};verify;
  for(i=0;i<WIDTH-1;i=i+1)begin
   value=(1<<i)-1;verify;value=1<<i;verify;value=(1<<i)+1;verify;
   value=-((1<<i)-1);verify;value=-(1<<i);verify;value=-((1<<i)+1);verify;
  end
  for(n=0;n<20000;n=n+1)begin value=$random;verify;end
  done=1;
 end
endmodule
