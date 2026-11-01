`timescale 1ns/1ps
//=============================================================================
// tb_mix_alpha — α 推进器验证（阶段 2）
//
// 覆盖：
//   * 启动：start 后 α 保持 0（启动帧本身仍是纯旧图），busy 拉高。
//   * 推进：每个 vs 帧边界推进一档，序列必须精确等于 round(256*k/30)。
//   * 端点：第 30 个帧边界到达 α=256，之后 busy 落低、done 出单拍脉冲。
//   * 终止：fail 脉冲立即清零 α、清 busy。
//   * 复位：rst 清零全部状态。
//=============================================================================
module tb_mix_alpha;
    reg clk=0, rst=1;
    reg vs=0, start=0, fail=0;
    wire [8:0] alpha;
    wire busy, done;
    integer errors=0, k;
    integer exp_alpha [0:31];

    always #5 clk=~clk;

    mix_alpha_ctrl dut (
        .clk(clk), .rst(rst), .vs(vs), .start(start), .fail(fail),
        .alpha(alpha), .busy(busy), .done(done)
    );

    // 期望序列：round(256*k/30)
    initial begin
        for (k=0;k<=30;k=k+1) exp_alpha[k] = (256*k + 15) / 30;
    end

    task check(input cond, input [8*80-1:0] msg);
        begin if (!cond) begin $display("[FAIL] %0s (alpha=%0d k)", msg, alpha); errors=errors+1; end end
    endtask

    // 驱动一个帧边界（vs 上升沿）
    task frame_edge;
        begin
            @(negedge clk); vs=1;
            @(negedge clk); vs=0;
        end
    endtask

    initial begin
        repeat(4) @(posedge clk);
        rst=0;
        @(negedge clk);
        check(alpha===9'd0 && busy===1'b0, "idle after reset");

        // ---- 启动：start 后本帧仍 α=0 ----
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        check(busy===1'b1, "busy asserted after start");
        check(alpha===9'd0, "alpha stays 0 on the start frame");

        // ---- 30 个帧边界推进 ----
        for (k=1;k<=30;k=k+1) begin
            frame_edge;
            #1;
            check(alpha === exp_alpha[k], "alpha follows round(256*k/30)");
        end

        // ---- 第 30 档后 busy 落低，done 脉冲 ----
        frame_edge;
        #1;
        check(busy===1'b0, "busy deasserts after full ramp");

        // ---- fail 立即终止 ----
        @(negedge clk); start=1; @(negedge clk); start=0;
        frame_edge; frame_edge; #1;
        check(alpha===exp_alpha[2], "ramping before fail");
        @(negedge clk); fail=1; @(negedge clk); fail=0;
        #1;
        check(alpha===9'd0, "fail resets alpha to 0");
        check(busy===1'b0, "fail clears busy");

        // ---- 复位 ----
        @(negedge clk); rst=1; @(negedge clk); rst=0; #1;
        check(alpha===9'd0 && busy===1'b0, "reset clears");

        if (errors==0) $display("*** PASS *** mix alpha: start, 30-step ramp, endpoint, fail, reset");
        else $display("*** FAIL *** %0d errors", errors);
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end
endmodule
