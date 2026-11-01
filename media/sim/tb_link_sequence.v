`timescale 1ns/1ps
// Exercise the carry lookahead through real packet admission, including
// consecutive zero-length packets, stalls and simultaneous session clear.
module tb_link_sequence;
    reg clk=0,rst=1,clear=0,valid=0;
    reg [7:0] channel=0;
    always #5 clk=~clk;
    db_link #(.ROLE(1)) dut(.clk(clk),.rst(rst),.phy_ok(1'b1),
        .tx_meta_valid(valid),.tx_channel(channel),
        .tx_opcode(8'd0),.tx_object(32'd0),.tx_offset(32'd0),.tx_length(16'd0),
        .tx_valid(1'b0),.tx_data(32'd0),.tx_last(1'b0),.rx_meta_ready(1'b0),.rx_ready(1'b0),
        .mac_tx_clk(clk),.mac_tx_ack(1'b0),.mac_rx_clk(clk),.mac_rx_data(8'd0),
        .mac_rx_valid(1'b0),.mac_rx_good(1'b0),.mac_rx_bad(1'b0));
    reg [31:0] expected[0:2];
    integer i,c,checks=0;
    task check;
      begin
        if(dut.next_seq[0]!==expected[0] || dut.next_seq[1]!==expected[1] || dut.next_seq[2]!==expected[2])
          $fatal(1,"sequence mismatch at %0d: %h %h %h expected %h %h %h",checks,
            dut.next_seq[0],dut.next_seq[1],dut.next_seq[2],expected[0],expected[1],expected[2]);
        checks=checks+1;
      end
    endtask
    initial begin
        force dut.tx_meta_ready=1'b1;
        force dut.sequence_clear=clear;
        expected[0]=0;expected[1]=0;expected[2]=0;
        repeat(4) @(negedge clk);
        rst=0;
        // All three channels cross the 18-bit carry boundary, twice.
        for(i=0;i<1800000;i=i+1) begin
            @(negedge clk);
            valid=(i%13!=0);channel=i%3;
            @(posedge clk);
            if(valid) expected[channel]=expected[channel]+32'd1;
            #1;check;
        end
        // Clear wins even on an admitted packet. Restart lookahead at zero.
        @(negedge clk);clear=1;valid=1;
        @(posedge clk);expected[0]=0;expected[1]=0;expected[2]=0;#1;check;
        @(negedge clk);clear=0;
        repeat(20) begin
            @(posedge clk);expected[channel]=expected[channel]+32'd1;#1;check;
        end
        $display("*** PASS *** sequence carry: %0d comparisons, consecutive packets, stalls, two carry boundaries per channel, session clear",checks);
        $finish;
    end
    initial begin #20000000;$fatal(1,"timeout");end
endmodule
