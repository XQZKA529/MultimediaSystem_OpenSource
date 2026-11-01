`timescale 1ns/1ps
module tb_frame_vflip;
    reg clk=0,rst=1,write_req=0;
    wire ack,finish,app_en,busy;
    wire [20:0] app_addr;
    wire fifo_aclr;
    integer n=0,errors=0,i;
    reg [20:0] seen[0:7];
    always #5 clk=~clk;

    frame_fifo_write #(
      .ADDR_BITS(21),.BURST_BITS(3),.BURST_SIZE(4),.FIFO_ADDR_BITS(10),
      .WRITE_V_FLIP(1),.FRAME_WIDTH(4),.FRAME_HEIGHT(2)
    ) dut(
      .rst(rst),.mem_clk(clk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),
      .Sdr_busy(1'b0),.App_rd_busy(1'b0),.read_urgent(1'b0),.O_wr_busy(busy),
      .App_wr_en(app_en),.App_wr_addr(app_addr),
      .write_req(write_req),.write_req_ack(ack),.write_finish(finish),.write_abort(1'b0),.write_abort_ack(),
      .write_addr_0(21'd100),.write_addr_1(21'd200),
      .write_addr_2(21'd300),.write_addr_3(21'd400),
      .write_addr_index(2'd0),.write_len(21'd8),
      .fifo_aclr(fifo_aclr),.rdusedw(10'd8));
    always @(posedge clk) if(app_en) begin seen[n]=app_addr;n=n+1;end
    task check(input cond,input [8*64-1:0] msg);
      begin if(!cond)begin $display("[FAIL] %0s",msg);errors=errors+1;end
            else $display("[OK] %0s",msg);end
    endtask
    initial begin
      repeat(4)@(posedge clk);rst=0;write_req=1;
      wait(ack);@(posedge clk);write_req=0;
      wait(finish);@(posedge clk);
      check(n==8,"exact write length emitted");
      for(i=0;i<4;i=i+1) check(seen[i]==104+i,"first BMP row maps to last memory row");
      for(i=0;i<4;i=i+1) check(seen[i+4]==100+i,"second BMP row maps to first memory row");
      check((21'h0A8C00+21'd691200-1)==21'h1517ff,"buffer 1 ends at 0x1517ff");
      check(22'h151800<22'h200000,"reserved SDRAM starts inside 8 MiB range");
      if(errors==0)$display("RESULT: *** PASS ***");
      else $display("RESULT: *** FAIL *** %0d",errors);
      $finish;
    end
    initial begin #10000;$display("TIMEOUT");$finish;end
endmodule
