`timescale 1ns/1ps
module tb_volume_view_cdc;
    reg clk=0,vc=0,rst=1,vr=1,vs=0,valid=0,hint=0,cancel=0;
    reg [4:0] cfg=20;wire [4:0] level;wire ev;
    integer hints=0;
    always #5 clk=~clk;always #7 vc=~vc;
    volume_view_cdc dut(.clk(clk),.rst(rst),.cfg_valid(valid),.cfg_level(cfg),.cfg_hint(hint),.cancel(cancel),
        .video_clk(vc),.video_rst(vr),.vs(vs),.level(level),.hint_event(ev));
    always @(negedge vc) if(ev) hints=hints+1;
    task frame;begin repeat(15) @(negedge vc);vs=1;repeat(3) @(negedge vc);vs=0;repeat(15) @(negedge vc);end endtask
    task publish;input [4:0] n;input h;begin @(negedge clk);cfg=n;hint=h;valid=1;@(negedge clk);valid=0;end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;vr=0;frame;
        publish(7,1);repeat(20) @(negedge vc);
        if(level!=20 || hints!=0) $fatal(1,"Configuration changed outside VS");
        frame;if(level!=7 || hints!=1) $fatal(1,"Atomic level/hint commit");
        publish(6,1);repeat(10) @(negedge vc);publish(5,1);publish(4,0);
        frame;frame;if(level!=4 || hints!=2) $fatal(1,"Mailbox hold/coalescing");
        // A reset pulse shorter than a bus clock must still reset transport.
        #1;vr=1;#2;vr=0;frame;
        if(level!=4 || hints!=2) $fatal(1,"Video reset lost level/replayed hint");
        publish(0,0);frame;if(level!=0 || hints!=2) $fatal(1,"Mute publish");
        cancel=1;frame;cancel=0;frame;if(level!=0 || hints!=2) $fatal(1,"Cancel replay");
        rst=1;repeat(3) @(negedge clk);rst=0;frame;
        if(level!=20 || hints!=2) $fatal(1,"Producer reset");
        $display("*** PASS *** volume CDC: atomic VS, latest coalescing, stable mailbox, short independent reset, mute, no replay hint");$finish;
    end
    initial begin #100000;$fatal(1,"CDC watchdog");end
endmodule
