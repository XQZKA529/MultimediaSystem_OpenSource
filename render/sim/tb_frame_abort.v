`timescale 1ns/1ps
module tb_frame_abort;
    reg clk=0,rst=1,request=0,abort=0,mem_busy=0,read_urgent=0;
    always #5 clk=~clk;
    wire ack,abort_ack,finish,enable,clear;
    integer words=0;
    frame_fifo_write #(.ADDR_BITS(21),.BURST_BITS(3),.BURST_SIZE(4),.FIFO_ADDR_BITS(10),
        .WRITE_V_FLIP(1),.FRAME_WIDTH(4),.FRAME_HEIGHT(2)) dut(
        .rst(rst),.mem_clk(clk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(mem_busy),
        .App_rd_busy(1'b0),.read_urgent(read_urgent),.O_wr_busy(),.App_wr_en(enable),.App_wr_addr(),.write_req(request),
        .write_abort(abort),.write_abort_ack(abort_ack),.write_req_ack(ack),.write_finish(finish),
        .write_addr_0(21'd100),.write_addr_1(21'd200),.write_addr_2(21'd300),.write_addr_3(21'd400),
        .write_addr_index(2'd0),.write_len(21'd8),.fifo_aclr(clear),.rdusedw(10'd8));
    always @(posedge clk) if(enable)words=words+1;
    task start;
        begin @(negedge clk);request=1;wait(ack);@(negedge clk);request=0;end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;start;
        wait(words==1);@(negedge clk);mem_busy=1;abort=1;
        wait(words==4);repeat(8)@(negedge clk);
        if(abort_ack || finish || words!=4) $fatal(1,"abort truncated burst or reset FIFO before SDRAM drained");
        mem_busy=0;wait(abort_ack);
        if(!clear || words!=4) $fatal(1,"abort must reset FIFO after draining one complete burst");
        repeat(5)@(negedge clk);if(!abort_ack) $fatal(1,"abort ACK not held");
        abort=0;wait(!abort_ack);repeat(5)@(negedge clk);
        if(clear) $fatal(1,"FIFO reset not released");
        start;wait(finish);
        if(words!=12) $fatal(1,"next complete frame failed after abort");
        $display("*** PASS *** frame writer: abort drains in-flight burst, waits SDRAM idle, resets FIFO, next frame succeeds");$finish;
    end
    initial begin #10000;$fatal(1,"frame abort watchdog");end
endmodule
