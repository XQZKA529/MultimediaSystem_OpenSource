`timescale 1ns/1ps
module tb_audio_sink;
    reg clk=0,vc=0,rst=1,live=1,start=0,stop=0,pause=0,freeze=0,eof=0,push=0;
    always #5 clk=~clk;always #6.667 vc=~vc;
    reg [31:0] id=1,total=12,base=0,pcm=0;
    wire ready,av,playing,fb;wire [23:0] left,right;wire [31:0] epoch,pos,fbpos;wire [2:0] flags;
    integer heard=0,ticks=0;reg check=1;reg [15:0] next_sample=1;
    db_audio_sink #(.PIX_HZ(480000),.PREFILL(4)) dut(
        .clk(clk),.rst(rst),.video_clk(vc),.video_rst(rst),.link_up(live),.begin_stream(start),
        .stream_id(id),.total_frames(total),.base_frame(base),.initial_pause(pause),.stop(stop),
        .paused(pause),.frozen(freeze),.eof(eof),.push(push),.pcm(pcm),.packet_ready(ready),
        .epoch_v(epoch),.position_v(pos),.playing_v(playing),.audio_valid(av),.audio_left(left),.audio_right(right),
        .feedback(fb),.feedback_position(fbpos),.feedback_flags(flags));
    always @(negedge vc) if(av && !rst) begin
        ticks=ticks+1;
        if(left!=0) begin
            if(check && (left!=={next_sample,8'd0} || right!=={next_sample,8'd0}))
                $fatal(1,"PCM lost/order %h expected %h",left,{next_sample,8'd0});
            next_sample=next_sample+1'b1;heard=heard+1;
        end
    end
    task begin_audio;begin @(negedge clk);start=1;@(negedge clk);start=0;wait(ready);repeat(3) @(posedge clk);end endtask
    task sample;input [15:0] x;begin @(negedge clk);push=1;pcm={x,x};@(negedge clk);push=0;end endtask
    task end_audio;begin @(negedge clk);eof=1;@(negedge clk);eof=0;end endtask
    integer i,saved,n;
    initial begin
        #100;rst=0;repeat(10) @(posedge clk);begin_audio();
        for(i=1;i<=12;i=i+1) sample(i);end_audio();wait(heard==3);
        @(negedge clk);pause=1;repeat(12) @(posedge vc);saved=heard;
        repeat(100) @(posedge vc);if(heard!=saved || pos!=saved) $fatal(1,"pause advanced/lost position");
        @(negedge clk);pause=0;wait(heard==8);@(negedge clk);freeze=1;
        wait(fb && flags[2]);saved=heard;if(fbpos!=saved) $fatal(1,"freeze feedback mismatch");
        repeat(80) @(posedge vc);if(heard!=saved || pos!=saved) $fatal(1,"freeze advanced");
        repeat(2) begin
            wait(!fb);wait(fb);
            if(!flags[2] || fbpos!=saved) $fatal(1,"periodic feedback lost frozen acknowledgement");
        end
        @(negedge clk);freeze=0;wait(heard==12);repeat(25) @(posedge vc);
        if(pos!=12 || playing) $fatal(1,"EOF accounting");
        @(negedge clk);stop=1;@(negedge clk);stop=0;repeat(30) @(posedge vc);
        if(playing) $fatal(1,"STOP left playing set");
        id=2;total=1003;base=1000;next_sample=101;begin_audio();
        for(i=101;i<=103;i=i+1) sample(i);end_audio();wait(heard==15);repeat(25) @(posedge vc);
        if(epoch!=2 || pos!=1003) $fatal(1,"new epoch/short EOF");
        n=ticks;@(negedge clk);live=0;repeat(100) @(posedge vc);
        if(ticks-n!=10 || left!=0 || playing) $fatal(1,"disconnect silence lost 48k cadence");
        $display("*** PASS *** audio: ordered PCM, pause hold, frozen position, STOP, epoch, short EOF, continuous silence");$finish;
    end
    initial begin #5000000;$display("audio timeout cfg=%d/%d pos=%d heard=%d",dut.cfg_state,dut.cfg_state_bus,pos,heard);$fatal(1,"audio timeout");end
endmodule
