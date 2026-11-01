`timescale 1ns/1ps
module tb_sdram_read_contract;
    reg clk=0,rst=1,req=0,we=0;
    reg [20:0] wa=0;
    always #4 clk=~clk;
    wire init,refv,busy,en,ret,ack,done,owner,rb;
    wire [20:0] addr;wire [31:0] data;
    integer issued=0,returned=0,busy_during=0,cycles=0,first_cycle=0,last_cycle=0,k;
    sdram memory(.Clk(clk),.Clk_sft(~clk),.Rst(rst),.Sdr_init_done(init),
        .Sdr_init_ref_vld(refv),.Sdr_busy(busy),.App_wr_en(we),.App_wr_addr(wa),
        .App_wr_dm(4'd0),.App_wr_din(32'h51000000+wa),.App_rd_en(en),.App_rd_addr(addr),
        .Sdr_rd_en(ret),.Sdr_rd_dout(data));
    frame_fifo_read_dual reader(.rst(rst),.mem_clk(clk),.Sdr_init_done(init),
        .Sdr_init_ref_vld(refv),.Sdr_busy(busy),.App_rd_en(en),.App_rd_addr(addr),
        .Sdr_rd_en(ret),.read_req(req),.read_req_ack(ack),.read_finish(done),
        .read_selected_index(),.read_handoff_toggle(),.read_addr_0(21'd0),
        .read_addr_1(21'd691200),.read_addr_2(21'd0),.read_addr_3(21'd0),
        .read_addr_index(2'd0),.read_len(21'd256),.read_addr_lane1(21'd691200),
        .read_index_lane1(2'd1),.read_lane1_en(1'b0),.App_wr_busy(1'b0),
        .fifo_aclr0(),.fifo_aclr1(),.lane0_lane1_sel(owner),.wrusedw0(10'd0),
        .wrusedw1(10'd0),.read_ready(),.read_urgent(),.read_dual_active(),.O_rd_busy(rb));
    always @(posedge clk) if(!rst) begin
        cycles=cycles+1;
        if(en) begin if(issued==0) first_cycle=cycles;issued=issued+1;end
        if(ret) begin
            // TD's EG_PHY_SDRAM_2M_32 simulation file is an empty primitive;
            // DQ is undriven. This test verifies the real controller's timing
            // and return-valid contract, not physical memory data storage.
            returned=returned+1;last_cycle=cycles;
        end
        if(rb && busy) busy_during=busy_during+1;
    end
    initial begin
        repeat(10) @(negedge clk);rst=0;wait(init);
        wait(!busy && !refv);
        for(k=0;k<256;k=k+1) begin @(negedge clk);we=1;wa=k;end
        @(negedge clk);we=0;repeat(20) @(negedge clk);wait(!busy && !refv);
        @(negedge clk);req=1;wait(ack);@(negedge clk);req=0;
        wait(done);
        $display("SDRAM contract issued=%0d returned=%0d busy_during=%0d cycles=%0d",issued,returned,busy_during,last_cycle-first_cycle+1);
        if(issued!=256 || returned!=256) $fatal(1,"SDRAM request/return mismatch");
        if(last_cycle-first_cycle+1>300) $fatal(1,"SDRAM streaming burst throttled by busy");
        $display("*** PASS *** actual vendor SDRAM read request contract");$finish;
    end
    initial begin #3000000;
        $fatal(1,"SDRAM watchdog init=%b busy=%b read_busy=%b issued=%0d returned=%0d",init,busy,rb,issued,returned);
    end
endmodule
