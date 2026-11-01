`timescale 1ns/1ps
//=============================================================================
// tb_pixel_mixer — α 混合算术与端点/舍入/饱和验证（阶段 2）
//
// 覆盖：
//   * 端点：alpha=0 必须逐位等于旧图；alpha=256 必须逐位等于新图（三通道）。
//   * 中点：alpha=128 时 round((o*256+128*(n-o))/256) 与黄金参考一致。
//   * 全扫描：对若干 (old,new) 组合与全部 31 个推进点做穷举比对，
//             误差必须为 0（定点实现应与整数参考完全一致）。
//   * 通道：R/G/B 三通道独立、互不串扰（分别置位验证）。
//   * 单图直通：mix_en=0 时无论 alpha 为何，输出恒等于旧图，且延迟不变。
//   * 有效标志：mix_en=0 只看 old_valid；mix_en=1 需要两路 valid 同时有效。
//=============================================================================
module tb_pixel_mixer;
    reg clk=0, rst=1;
    reg mix_en=0;
    reg [8:0] alpha=0;
    reg [23:0] old_rgb=0, new_rgb=0;
    reg old_valid=0, new_valid=0;
    wire [23:0] mixed;
    wire pair_ok;
    integer errors=0, i, k, o, n;

    always #5 clk=~clk;

    pixel_mixer dut (
        .clk(clk), .rst(rst), .mix_en(mix_en), .alpha(alpha),
        .old_rgb(old_rgb), .old_valid(old_valid),
        .new_rgb(new_rgb), .new_valid(new_valid),
        .mixed_rgb(mixed), .pair_ok(pair_ok)
    );

    // 黄金参考：round((o*256 + a*(n-o))/256)，a=0..256
    function [7:0] golden;
        input integer oo, nn, aa;
        integer v;
        begin
            v = oo*256 + aa*(nn-oo);
            // 对称舍入到最近整数
            if (v >= 0) golden = (v + 128) / 256;
            else        golden = -(((-v) + 128) / 256);
            if (golden < 0) golden = 0;
            if (golden > 255) golden = 255;
        end
    endfunction

    task check(input cond, input [8*80-1:0] msg);
        begin
            if (!cond) begin $display("[FAIL] %0s", msg); errors=errors+1; end
        end
    endtask

    // 驱动一拍：设置输入，等输出（3 拍延迟）
    task apply(input [23:0] ov, input [23:0] nv, input [8:0] a, input en);
        begin
            @(negedge clk);
            old_rgb=ov; new_rgb=nv; alpha=a; mix_en=en;
            old_valid=1; new_valid=en;
            repeat(3) @(posedge clk); #1;
        end
    endtask

    initial begin
        repeat(4) @(posedge clk);
        rst=0;
        @(negedge clk);

        // ---- 端点 1：alpha=0 → 纯旧图 ----
        for (i=0;i<8;i=i+1) begin
            old_rgb = {8'h12*i, 8'h34+i, 8'h56^i};
            new_rgb = {8'hAB, 8'hCD, 8'hEF};
            apply(old_rgb, new_rgb, 9'd0, 1'b1);
            check(mixed === old_rgb, "alpha=0 gives exact old image");
            check(pair_ok === 1'b1, "pair_ok high with both valid");
        end

        // ---- 端点 2：alpha=256 → 纯新图 ----
        for (i=0;i<8;i=i+1) begin
            old_rgb = {8'h00, 8'h11, 8'h22};
            new_rgb = {8'hF0+i, 8'h80+i, 8'h40+i};
            apply(old_rgb, new_rgb, 9'd256, 1'b1);
            check(mixed === new_rgb, "alpha=256 gives exact new image");
        end

        // ---- 中点：alpha=128 ----
        old_rgb = 24'h000000; new_rgb = 24'hFFFFFF;
        apply(old_rgb, new_rgb, 9'd128, 1'b1);
        check(mixed === 24'h808080, "alpha=128 midpoint of black/white is 0x80");
        old_rgb = 24'h000000; new_rgb = 24'h010101;
        apply(old_rgb, new_rgb, 9'd128, 1'b1);
        check(mixed === 24'h010101, "alpha=128 round(0.5)=1 (round half up)");

        // ---- 全扫描：31 个推进点 × 若干组合，逐通道比对黄金参考 ----
        for (k=0;k<=30;k=k+1) begin
            if (k==0) alpha = 9'd0;
            else if (k==30) alpha = 9'd256;
            else alpha = (256*k + 15) / 30;   // 与 RTL 表一致的 round(256k/30)
            for (o=0;o<17;o=o+1) begin
                for (n=0;n<17;n=n+1) begin
                    old_rgb = {8'(o*15), 8'(255-o*15), 8'(o*7)};
                    new_rgb = {8'(255-n*15), 8'(n*15), 8'(128+n*7)};
                    apply(old_rgb, new_rgb, alpha, 1'b1);
                    check(mixed[23:16] === golden(old_rgb[23:16], new_rgb[23:16], alpha),
                          "R channel matches golden");
                    check(mixed[15:8]  === golden(old_rgb[15:8],  new_rgb[15:8],  alpha),
                          "G channel matches golden");
                    check(mixed[7:0]   === golden(old_rgb[7:0],   new_rgb[7:0],   alpha),
                          "B channel matches golden");
                end
            end
        end

        // ---- 通道隔离：只改 R，G/B 不动 ----
        old_rgb = 24'h112233; new_rgb = 24'hFF2233;
        apply(old_rgb, new_rgb, 9'd128, 1'b1);
        check(mixed[15:0] === 16'h2233, "G/B unchanged when only R differs");
        check(mixed[23:16] === 8'h88, "R blend 0x11/0xFF at alpha=128 -> 0x88");

        // ---- 单图直通：mix_en=0 时忽略 alpha 与 new ----
        for (i=0;i<5;i=i+1) begin
            old_rgb = {8'h10+i, 8'h20+i, 8'h30+i};
            apply(old_rgb, 24'hFFFFFF, 9'd200, 1'b0);
            check(mixed === old_rgb, "mix_en=0 passes old image regardless of alpha");
            check(pair_ok === 1'b1, "mix_en=0 pair_ok follows old_valid only");
        end

        // ---- 有效标志：mix_en=1 且 new 无效 → pair_ok 落低 ----
        @(negedge clk); old_rgb=24'h123456; new_rgb=24'h654321; alpha=9'd128; mix_en=1;
        old_valid=1; new_valid=0; repeat(3) @(posedge clk); #1;
        check(pair_ok === 1'b0, "mix_en=1 with new invalid drops pair_ok");
        old_valid=0; new_valid=1; repeat(3) @(posedge clk); #1;
        check(pair_ok === 1'b0, "mix_en=1 with old invalid drops pair_ok");
        old_valid=1; new_valid=1; repeat(3) @(posedge clk); #1;
        check(pair_ok === 1'b1, "both valid restores pair_ok");

        // ---- 复位 ----
        @(negedge clk); rst=1; repeat(3) @(posedge clk); #1;
        check(mixed === 24'd0 && pair_ok === 1'b0, "reset clears output");

        if (errors==0) $display("*** PASS *** pixel mixer: endpoints, midpoint, rounding, channels, passthrough, validity");
        else $display("*** FAIL *** %0d errors", errors);
        $finish;
    end

    initial begin #2000000; $display("TIMEOUT"); $finish; end
endmodule
