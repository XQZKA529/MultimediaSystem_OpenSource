`timescale 1ns/1ps
module tb_mix_transition;
    reg clk=0,rst=1,vs=0,req=0,fail=0,handoff=0,reader_dual=0;
    reg restore=0;wire restored;
    reg [1:0] new_idx=1,reader_idx=0;
    wire ack,active,lane1,start,done,failed,valid,ab,ad;
    wire [1:0] laneidx,display_idx;
    wire [8:0] alpha;
    always #6.667 clk=~clk;
    mix_alpha_ctrl ramp(.clk(clk),.rst(rst),.vs(vs),.start(start),.fail(fail),.alpha(alpha),.busy(ab),.done(ad));
    mix_transition_ctrl dut(.clk(clk),.rst(rst),.vs(vs),.transition_req(req),.restore_req(restore),.restore_valid(1'b1),.restore_index(2'd1),.restore_done(restored),
        .req_new_idx(new_idx),.req_cur_idx(display_idx),.req_ack(ack),
        .mix_active(active),.lane1_en(lane1),.lane1_idx(laneidx),.alpha_start(start),
        .alpha(alpha),.alpha_busy(ab),.alpha_done(ad),.mix_fail_in(fail),
        .read_handoff(handoff),.read_index(reader_idx),.read_dual_active(reader_dual),
        .disp_index_out(display_idx),.disp_valid_out(valid),.transition_done(done),.transition_failed(failed));
    task frame;
        begin
            @(negedge clk);vs=1;repeat(3) @(negedge clk);vs=0;
            repeat(3) @(negedge clk);
            reader_idx=display_idx;reader_dual=lane1;handoff=~handoff;
            repeat(10) @(negedge clk);
        end
    endtask
    integer k;
    initial begin
        repeat(4) @(negedge clk);rst=0;req=1;
        repeat(3) @(negedge clk);if(!ack || active) $fatal(1,"request acceptance");
        for(k=0;k<35 && !done;k=k+1) frame;
        if(!done || !valid || display_idx!=1 || reader_dual) $fatal(1,"success/retirement");
        repeat(20) @(negedge clk);
        if(!done || !ack) $fatal(1,"completion must survive slow CDC sampling");
        req=0;repeat(4) @(negedge clk);
        if(done || ack) $fatal(1,"mailbox return to idle");
        // Second transaction must preserve the first committed image on failure.
        new_idx=0;req=1;repeat(3) @(negedge clk);frame;
        if(!lane1) $fatal(1,"second request");
        fail=1;@(negedge clk);fail=0;repeat(5) @(negedge clk);
        if(failed || !active) $fatal(1,"failure released old dual reader early");
        frame;repeat(4) @(negedge clk);
        if(!failed || done || display_idx!=1 || !valid || reader_dual) $fatal(1,"failure retention");
        repeat(10) @(negedge clk);if(!failed) $fatal(1,"held failure feedback");
        req=0;repeat(4) @(negedge clk);
        // Third transaction verifies no stale result/retrigger.
        req=1;repeat(3) @(negedge clk);
        for(k=0;k<35 && !done;k=k+1) frame;
        if(!done || display_idx!=0 || failed) $fatal(1,"third transaction");
        restore=1;req=0;repeat(5) @(negedge clk);frame;
        if(display_idx!=1 || !restored || reader_dual) $fatal(1,"saved frame restore/reader barrier");
        restore=0;repeat(5) @(negedge clk);if(restored) $fatal(1,"restore mailbox retirement");
        $display("*** PASS *** saved frame restoration plus held CDC result, actual reader retirement, repeated transactions and failure retention");$finish;
    end
    initial begin #1000000;$fatal(1,"transition watchdog");end
endmodule
