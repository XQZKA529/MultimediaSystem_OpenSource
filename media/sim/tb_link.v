`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_link;
    reg clk=0,t0=0,t1=0,rst=1,phy=1;
    always #5 clk=~clk;
    always #4 t0=~t0;
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
    reg accept=1;reg [31:0] retries0,errors1;
    wire [31:0] ret0,err1;
    reg drop_next=0,corrupt_next=0;
    wire [31:0] packet_count;
    db_link #(.HEARTBEAT_CYCLES(5000),.TIMEOUT_CYCLES(150000),.RETRY_CYCLES(10000)) a(
        .clk(clk),.rst(rst),.phy_ok(phy),.link_up(up0),.session_reset(reset0),
        .tx_meta_valid(meta),.tx_meta_ready(metardy),.tx_channel(channel),.tx_opcode(op),
        .tx_object(32'd42),.tx_offset(32'd256),.tx_length(length),
        .tx_valid(dv),.tx_ready(dr),.tx_data(data),.tx_last(last),
        .rx_meta_valid(),.rx_meta_ready(1'b1),.rx_channel(),.rx_opcode(),.rx_object(),.rx_offset(),
        .rx_length(),.rx_valid(),.rx_ready(1'b1),.rx_data(),.rx_last(),
        .mac_tx_clk(t0),.mac_tx_data(md0),.mac_tx_valid(mv0),.mac_tx_ack(ma0),
        .mac_rx_clk(t1),.mac_rx_data(rd0),.mac_rx_valid(rv0),.mac_rx_good(rg0),.mac_rx_bad(1'b0),
        .retry_count(ret0),.crc_errors(),.rx_drops());
    db_link #(.ROLE(2),.LOCAL_MAC(`DB_MAC_RENDER),.PEER_MAC(`DB_MAC_MEDIA),
        .HEARTBEAT_CYCLES(5000),.TIMEOUT_CYCLES(150000),.RETRY_CYCLES(10000)) b(
        .clk(clk),.rst(rst),.phy_ok(phy),.link_up(up1),.session_reset(reset1),
        .tx_meta_valid(1'b0),.tx_meta_ready(),.tx_channel(8'd0),.tx_opcode(8'd0),
        .tx_object(32'd0),.tx_offset(32'd0),.tx_length(16'd0),
        .tx_valid(1'b0),.tx_ready(),.tx_data(32'd0),.tx_last(1'b0),
        .rx_meta_valid(rmeta),.rx_meta_ready(accept),.rx_channel(rchan),.rx_opcode(rop),
        .rx_object(robj),.rx_offset(roff),.rx_length(rlen),
        .rx_valid(rdvalid),.rx_ready(accept),.rx_data(rdata),.rx_last(rlast),
        .mac_tx_clk(t1),.mac_tx_data(md1),.mac_tx_valid(mv1),.mac_tx_ack(ma1),
        .mac_rx_clk(t0),.mac_rx_data(rd1),.mac_rx_valid(rv1),.mac_rx_good(rg1),.mac_rx_bad(1'b0),
        .retry_count(),.crc_errors(err1),.rx_drops());
    tb_mac_client_pipe forward(.clk(t0),.rst(rst),.din(md0),.valid(mv0),.ack(ma0),
        .drop_next(drop_next),.corrupt_next(corrupt_next),.dout(rd1),.dv(rv1),.good(rg1),.packets(packet_count));
    tb_mac_client_pipe backward(.clk(t1),.rst(rst),.din(md1),.valid(mv1),.ack(ma1),
        .drop_next(1'b0),.corrupt_next(1'b0),.dout(rd0),.dv(rv0),.good(rg0),.packets());
    integer received=0,words=0,completed=0;
    reg [31:0] held;
    reg held_valid=0;
    always @(posedge clk) if(!rst) begin
        if(rmeta && accept) begin
            if(robj!=42 || roff!=256 || rlen!=1024 || rchan!=2) fail("metadata");
            received=received+1;words=0;
        end
        if(rdvalid && accept) begin
            if(rdata!==32'h12340000+words) fail("payload byte order / corruption / RAM prefetch");
            words=words+1;
            if(rlast) begin if(words!=256) fail("packet length");completed=completed+1;end
        end
        if(held_valid && rdvalid && !accept && held!==rdata) fail("stalled word changed");
        held=rdata;held_valid=rdvalid && !accept;
    end
    task fail;
        input [511:0] message;
        begin $display("FAIL %0s at %0t",message,$time);$finish;end
    endtask
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
    initial begin
        #100;rst=0;wait(up0 && up1);#1000;
        // Multiple outstanding packets exhaust the image window while receiver stalls.
        accept=0;packet;packet;packet;packet;
        #5000;if(metardy) fail("credit overcommit");accept=1;
        wait(completed==4);#50000;
        drop_next=1;packet;wait(forward.active && forward.drop_frame);wait(!forward.active);drop_next=0;
        wait(completed==5);#50000;
        corrupt_next=1;packet;wait(forward.active && forward.corrupt_frame);wait(!forward.active);corrupt_next=0;
        wait(completed==6);#50000;
        if(ret0==0 || err1==0) fail("retry / CRC rejection not exercised");
        if(received!=6) fail("duplicate delivered");
        phy=0;#2000;if(up0 || up1) fail("link down");
        phy=1;wait(up0 && up1);#1000;packet;wait(completed==7);
        #50000;
        @(negedge clk);a.sequence_bank[2].transmit_dsp.u_tx.held=32'hfffffff8;b.sequence_bank[2].u_rx.held=32'hfffffff8;
        repeat(20) packet;
        wait(completed==27);repeat(10) @(posedge clk);
        if(b.expect_seq[2]!=12) fail("wire sequence did not wrap modulo 32 bits");
        #50000;retries0=ret0;
        drop_next=1;packet;wait(!up0);
        if(ret0-retries0!=3) fail("retry limit is not exactly three retransmissions");
        drop_next=0;wait(up0 && up1);#1000;packet;wait(completed==28);
        $display("*** PASS *** link: window/stall/retry/CRC/session recovery/sequence wrap, retries=%0d",ret0);$finish;
    end
    initial begin #10000000;fail("watchdog");end
endmodule

// Models the TEMAC CLIENT contract: first-byte ack followed by an unbroken frame.
// Physical FCS checking remains a separate vendor-IP/hardware validation.
module tb_mac_client_pipe(
    input wire clk,rst,input wire [7:0] din,input wire valid,output wire ack,
    input wire drop_next,corrupt_next,output reg [7:0] dout,output reg dv,good,
    output reg [31:0] packets
);
    reg active,drop_frame,corrupt_frame;
    reg [11:0] bytes;
    assign ack=valid && !active;
    always @(posedge clk or posedge rst) begin
        if(rst) begin active<=0;drop_frame<=0;corrupt_frame<=0;bytes<=0;dout<=0;dv<=0;good<=0;packets<=0;end
        else begin
            good<=0;dv<=0;
            if(valid) begin
                active<=1;bytes<=active ? bytes+1'b1:1;
                if(!active) begin drop_frame<=drop_next;corrupt_frame<=corrupt_next;end
                dout<=din ^ ((active && corrupt_frame && bytes==62) ? 8'h01:8'h00);
                dv<=!(active ? drop_frame:drop_next);
            end else if(active) begin
                active<=0;good<=!drop_frame;packets<=packets+1'b1;
            end
        end
    end
endmodule
