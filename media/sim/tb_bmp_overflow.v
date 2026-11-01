`timescale 1ns/1ps
module tb_bmp_overflow;
    reg clk=0,rst=1,start=0,cancel=0,fv=0,fd=0,ready=0;
    always #5 clk=~clk;
    wire credit,pv,done,failed;wire [23:0] rgb;
    integer i,count=0;
    bmp_image_pipeline #(.DST_W(8),.DST_H(4)) dut(
        .clk(clk),.rst(rst),.start(start),.cancel(cancel),.src_w(13'd1),.src_h(13'd1),
        .pixel_offset(32'd0),.row_stride(32'd4),.scaled_w(16'd4),.scaled_h(16'd4),
        .left(16'd2),.bottom(16'd0),.file_data(8'd0),.file_valid(fv),.file_done(fd),.file_ok(1'b1),
        .burst_ready(credit),.pixel_valid(pv),.pixel_rgb(rgb),.pixel_ready(ready),
        .progress(),.done(done),.failed(failed));
    always @(posedge clk) if(pv && ready)begin
        if(rgb!==0)$fatal(1,"old data leaked into restarted image");count=count+1;
    end
    initial begin
        repeat(4)@(negedge clk);rst=0;start=1;@(negedge clk);start=0;
        // Deliberately violate non-preemptible burst credit to verify recovery.
        // The raw FIFO is 4 KiB, so inject more than its depth.
        fv=1;repeat(8192)@(negedge clk);fv=0;
        if(!failed || done)$fatal(1,"raw FIFO overflow was not rejected");
        cancel=1;@(negedge clk);cancel=0;start=1;@(negedge clk);start=0;
        if(failed)$fatal(1,"failure retained across restart");
        fv=1;repeat(4)@(negedge clk);fv=0;fd=1;@(negedge clk);fd=0;
        repeat(100)@(negedge clk);if(done)$fatal(1,"stalled output completed");
        ready=1;wait(done);if(count!=32)$fatal(1,"restart count");
        $display("*** PASS *** raw FIFO overflow rejection, cancel/reset and stable restart");$finish;
    end
    initial begin #1000000;$fatal(1,"overflow watchdog");end
endmodule
