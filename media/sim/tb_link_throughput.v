`timescale 1ns/1ps
`include "pkg/board_link.vh"
// Diagnostic-only: measures the sustained image-channel (ch2) throughput of the
// production reliable link at the current 50 MHz bus clock. Sends PACKETS
// full-size 1024-byte packets and reports words/cycle and MB/s.
module tb_link_throughput #(parameter integer PACKETS=64, parameter integer CLK_HALF=10);
    reg clk=0,t0=0,t1=0,rst=1,phy=1;
    always #(CLK_HALF) clk=~clk;      // 50 MHz
    always #4 t0=~t0;                 // 125 MHz MAC TX clock
    always #4.01 t1=~t1;
    wire up0,up1,reset0,reset1;
    wire [7:0] md0,md1;wire mv0,mv1,ma0,ma1;
    wire [7:0] rd0,rd1;wire rv0,rv1,rg0,rg1;
    reg meta=0,dv=0,last=0;
    reg [7:0] channel=2,op=`DB_IMG_DATA;
    reg [15:0] length=1024;
    reg [31:0] data=0;
    wire metardy,dr;
    wire rmeta,rdvalid,rlast;wire [31:0] rdata,robj,roff;
    wire [7:0] rchan,rop;wire [15:0] rlen;
    reg accept=1;
    db_link #(.HEARTBEAT_CYCLES(50000),.TIMEOUT_CYCLES(1500000),.RETRY_CYCLES(100000)) a(
        .clk(clk),.rst(rst),.phy_ok(phy),.link_up(up0),.session_reset(reset0),
        .tx_meta_valid(meta),.tx_meta_ready(metardy),.tx_channel(channel),.tx_opcode(op),
        .tx_object(32'd42),.tx_offset(32'd256),.tx_length(length),
        .tx_valid(dv),.tx_ready(dr),.tx_data(data),.tx_last(last),
        .rx_meta_valid(),.rx_meta_ready(1'b1),.rx_channel(),.rx_opcode(),.rx_object(),.rx_offset(),
        .rx_length(),.rx_valid(),.rx_ready(1'b1),.rx_data(),.rx_last(),
        .mac_tx_clk(t0),.mac_tx_data(md0),.mac_tx_valid(mv0),.mac_tx_ack(ma0),
        .mac_rx_clk(t1),.mac_rx_data(rd0),.mac_rx_valid(rv0),.mac_rx_good(rg0),.mac_rx_bad(1'b0),
        .retry_count(),.crc_errors(),.rx_drops());
    db_link #(.ROLE(2),.LOCAL_MAC(`DB_MAC_RENDER),.PEER_MAC(`DB_MAC_MEDIA),
        .HEARTBEAT_CYCLES(50000),.TIMEOUT_CYCLES(1500000),.RETRY_CYCLES(100000)) b(
        .clk(clk),.rst(rst),.phy_ok(phy),.link_up(up1),.session_reset(reset1),
        .tx_meta_valid(1'b0),.tx_meta_ready(),.tx_channel(8'd0),.tx_opcode(8'd0),
        .tx_object(32'd0),.tx_offset(32'd0),.tx_length(16'd0),
        .tx_valid(1'b0),.tx_ready(),.tx_data(32'd0),.tx_last(1'b0),
        .rx_meta_valid(rmeta),.rx_meta_ready(accept),.rx_channel(rchan),.rx_opcode(rop),
        .rx_object(robj),.rx_offset(roff),.rx_length(rlen),
        .rx_valid(rdvalid),.rx_ready(accept),.rx_data(rdata),.rx_last(rlast),
        .mac_tx_clk(t1),.mac_tx_data(md1),.mac_tx_valid(mv1),.mac_tx_ack(ma1),
        .mac_rx_clk(t0),.mac_rx_data(rd1),.mac_rx_valid(rv1),.mac_rx_good(rg1),.mac_rx_bad(1'b0),
        .retry_count(),.crc_errors(),.rx_drops());
    tb_mac_client_pipe forward(.clk(t0),.rst(rst),.din(md0),.valid(mv0),.ack(ma0),
        .drop_next(1'b0),.corrupt_next(1'b0),.dout(rd1),.dv(rv1),.good(rg1),.packets());
    tb_mac_client_pipe backward(.clk(t1),.rst(rst),.din(md1),.valid(mv1),.ack(ma1),
        .drop_next(1'b0),.corrupt_next(1'b0),.dout(rd0),.dv(rv0),.good(rg0),.packets());

    integer words=0,completed=0;
    time t_first=0,t_last=0;
    reg seen_first=0;
    always @(posedge clk) if(!rst) begin
        if(rmeta && accept && !seen_first) begin t_first=$time;seen_first=1;end
        if(rdvalid && accept) begin
            words=words+1;t_last=$time;
            if(rlast) completed=completed+1;
        end
    end
    task packet;
        integer n;
        begin
            @(negedge clk);meta=1;
            while(!metardy) @(negedge clk);
            @(negedge clk);meta=0;
            for(n=0;n<256;n=n+1) begin
                dv=1;data=32'h12340000+n;last=n==255;
                while(!dr) @(negedge clk);
                @(negedge clk);
            end
            dv=0;last=0;
        end
    endtask
    integer i;
    time t0_start;
    initial begin
        #100;rst=0;wait(up0 && up1);#2000;
        t0_start=$time;
        for(i=0;i<PACKETS;i=i+1) packet;
        wait(completed==PACKETS);
        #(200*CLK_HALF);
        $display("*** PASS *** link throughput: %0d packets / %0d words",completed,words);
        $display("  elapsed = %0d ns", t_last-t0_start);
        $display("  word rate = %0d words/s, payload = %0d.%03d MB/s",
            (words*1000000000)/(t_last-t0_start),
            (words*4*1000000000)/(t_last-t0_start)/1000000,
            ((words*4*1000000000)/(t_last-t0_start)/1000)%1000);
        $display("  cycles/word = %0d.%03d", (t_last-t0_start)/2/words,
            (((t_last-t0_start)/2*1000)/words)%1000);
        $finish;
    end
    initial begin #(PACKETS*20_000_000+10_000_000);$display("TIMEOUT words=%0d completed=%0d",words,completed);$finish;end
endmodule
