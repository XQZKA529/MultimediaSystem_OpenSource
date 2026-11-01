`timescale 1ns/1ps
module tb_audio_volume_gain;
    reg clk=0,rst=1,valid=0,unity=0;reg [4:0] level=20;
    reg [23:0] left=0,right=0;wire ov;wire [23:0] ol,orr;
    integer gain=32768,target,delta,n,i,checks=0;
    reg prev_valid=0;reg [23:0] expected_left=0,expected_right=0;
    reg delayed_valid=0;reg [23:0] delayed_left=0,delayed_right=0;
    reg check_valid;reg [23:0] check_left,check_right;
    reg signed [63:0] pl,pr;
    always #5 clk=~clk;
    audio_volume_gain dut(.clk(clk),.rst(rst),.level(level),.unity(unity),.in_valid(valid),.in_left(left),.in_right(right),
        .out_valid(ov),.out_left(ol),.out_right(orr));
    function [23:0] reference;
        input signed [63:0] value;
        begin reference=value<0 ? -((-value+16384)/32768):((value+16384)/32768);end
    endfunction
    always @(posedge clk) begin
        if(rst) begin gain=32768;prev_valid=0;delayed_valid=0;end
        else begin
            check_valid=delayed_valid;check_left=delayed_left;check_right=delayed_right;
            delayed_valid=prev_valid;delayed_left=expected_left;delayed_right=expected_right;
            if(valid) begin
                target=level<=20 ? (level*32768+10)/20:32768;
                delta=target-gain;if(delta>69) delta=69;if(delta< -69) delta=-69;gain=gain+delta;
                pl=$signed(left);pr=$signed(right);pl=pl*(unity ? 32768:gain);pr=pr*(unity ? 32768:gain);
                expected_left=reference(pl);expected_right=reference(pr);
            end
            prev_valid=valid;
            #1;
            if(ov!==check_valid) $fatal(1,"PCM valid latency");
            if(ov) begin
                if(ol!==check_left || orr!==check_right) $fatal(1,"Signed gain/rounding/slew level %d gain %d got %h/%h expected %h/%h",level,gain,ol,orr,check_left,check_right);
                checks=checks+1;
            end
        end
    end
    initial begin
        repeat(3) @(negedge clk);rst=0;
        for(n=0;n<22;n=n+1) begin
            level=n;
            for(i=0;i<560;i=i+1) begin
                @(negedge clk);valid=(i%7!=0);
                case(i%8)
                    0:left=24'h800000;1:left=24'h7fffff;2:left=0;3:left=1;
                    4:left=24'hffffff;5:left=24'h800001;default:left=$random;
                endcase
                right=~left;
            end
            if(gain!=(n<=20 ? (n*32768+10)/20:32768)) $fatal(1,"Gain failed to converge");
        end
        level=0;valid=1;left=24'h7fffff;right=24'h800000;
        repeat(500) @(negedge clk);
        if(gain!=0) $fatal(1,"normal mute not settled");
        unity=1;repeat(20) @(negedge clk);
        if(gain!=0) $fatal(1,"emergency unity changed saved gain");
        unity=0;repeat(5) @(negedge clk);
        if(ol!=0 || orr!=0) $fatal(1,"normal mute not restored immediately");
        @(negedge clk);valid=0;repeat(3) @(negedge clk);
        $display("*** PASS *** %d stereo PCM samples: 21 gains, extremes, signed rounding, slew, unity, mute, invalid fallback, three-clock valid",checks);$finish;
    end
    initial begin #1000000;$fatal(1,"Gain watchdog");end
endmodule
