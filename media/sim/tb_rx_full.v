`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_rx_full;
    `include "db_crc.vh"
    reg rx_clk=0,clk=0,rst=1,valid=0,good=0,accept=0;
    reg [7:0] din=0;
    always #4 rx_clk=~rx_clk;
    always #5 clk=~clk;
    wire pv,dv,last;wire [255:0] hdr;wire [31:0] data,drops,errors;
    db_mac_rx #(.LOCAL_MAC(`DB_MAC_RENDER),.PEER_MAC(`DB_MAC_MEDIA)) dut(
        .rst(rst),.rx_clk(rx_clk),.rx_data(din),.rx_valid(valid),.rx_good(good),.rx_bad(1'b0),
        .bus_clk(clk),.pkt_valid(pv),.pkt_header(hdr),.pkt_ready(accept),
        .data_valid(dv),.data(data),.data_ready(accept),.data_last(last),
        .mgmt_valid(),.mgmt_header(),.mgmt_ready(1'b1),.crc_errors(errors),.rx_drops(drops));
    integer packets=0,words=0;
    reg [31:0] expected;
    always @(posedge clk) if(!rst) begin
        if(pv && accept) begin
            expected=packets<8 ? packets+1:11;
            if(hdr[127:96]!==expected) $fatal(1,"descriptor changed or dropped packet was published");
            packets=packets+1;
        end
        if(dv && accept) begin
            if(data!==32'ha5000000+expected || !last) $fatal(1,"full RX queue overwrote held payload");
            words=words+1;
        end
    end
    task send;
        input [31:0] id;
        reg [255:0] h;
        reg [31:0] c,payload;
        integer b;
        begin
            payload=32'ha5000000+id;
            h={`DB_MAJOR,`DB_MINOR,8'd1,8'd1,64'd123,id,id,32'd0,16'd4,8'd2,`DB_IMG_DATA,32'd0};
            c=32'hffffffff;
            for(b=0;b<28;b=b+1)c=db_crc_byte(c,h[255-b*8 -:8]);
            for(b=0;b<4;b=b+1)c=db_crc_byte(c,payload[31-b*8 -:8]);
            h[31:0]=~c;
            for(b=0;b<60;b=b+1) begin
                @(negedge rx_clk);valid=1;
                if(b<6) din=`DB_MAC_RENDER >> ((5-b)*8);
                else if(b<12)din=`DB_MAC_MEDIA >> ((11-b)*8);
                else if(b==12)din=8'h88;
                else if(b==13)din=8'hb5;
                else if(b<46)din=h[255-(b-14)*8 -:8];
                else if(b<50)din=payload[31-(b-46)*8 -:8];
                else din=0;
            end
            @(negedge rx_clk);valid=0;good=1;
            @(negedge rx_clk);good=0;
            repeat(14) @(negedge rx_clk);
        end
    endtask
    integer n;
    initial begin
        #100;rst=0;repeat(4)@(negedge rx_clk);
        for(n=1;n<=8;n=n+1)send(n);
        if(!dut.rx_full) $fatal(1,"queue not filled");
        send(9); // must not overwrite packet 1 while the consumer is stalled
        fork
            send(10);
            begin repeat(10)@(negedge rx_clk);accept=1;end
        join
        wait(words==8);send(11);wait(words==9);
        if(packets!=9 || drops!=2 || errors!=0) $fatal(1,"RX queue-full accounting");
        $display("*** PASS *** RX full: retained payload protected, mid-frame freed slot still discards, recovery");$finish;
    end
    initial begin #100000;$fatal(1,"RX full watchdog");end
endmodule
