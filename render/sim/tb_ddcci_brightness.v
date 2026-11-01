`timescale 1ns/1ps
module tb_ddcci_brightness;
    reg clk=0,rst=1;
    reg [3:0] level=10;
    wire [1:0] mode;wire [3:0] rgb_level;
    tri1 scl,sda;
    wire scl_low,sda_low;
    assign scl=scl_low ? 1'b0:1'bz;
    assign sda=sda_low ? 1'b0:1'bz;
    reg slave_low=0,stretch_low=0;
    integer scenario=0,writes=0,reads=0,max_brightness=200,brightness=80;
    reg [7:0] addr,request[0:6],reply[0:10],checksum;
    integer i,n;
    assign sda=slave_low ? 1'b0:1'bz;
    assign scl=stretch_low ? 1'b0:1'bz;
    always #5 clk=~clk;
    ddcci_brightness #(.CLK_HZ(100000),.I2C_HZ(10000),.STARTUP_MS(1),.GAP_MS(1),.RETRY_MS(1),.REPROBE_MS(1000)) dut(
        .clk(clk),.rst(rst),.level(level),.mode(mode),.rgb_level(rgb_level),.scl_in(scl),.sda_in(sda),.scl_low(scl_low),.sda_low(sda_low));
    task receive_byte;output [7:0] value;integer k;
        begin value=0;for(k=0;k<8;k=k+1) begin @(posedge scl);value={value[6:0],sda};end @(negedge scl);end
    endtask
    task ack_byte;input ack;
        begin slave_low=ack;@(posedge scl);@(negedge scl);slave_low=0;end
    endtask
    task send_byte;input [7:0] value;integer k;
        begin for(k=7;k>=0;k=k-1) begin slave_low=!value[k];@(posedge scl);@(negedge scl);end
            slave_low=0;@(posedge scl);@(negedge scl);
        end
    endtask
    always @(negedge sda) if(!rst && scl===1'b1) begin
        receive_byte(addr);
        if(addr==8'h6e || addr==8'h6f) begin
            ack_byte(scenario!=1);
            if(scenario!=1) begin
                if(addr==8'h6e) begin
                    receive_byte(request[0]);ack_byte(1);
                    receive_byte(request[1]);ack_byte(1);
                    n=(request[1]&8'h7f)+3;
                    for(i=2;i<n;i=i+1) begin receive_byte(request[i]);ack_byte(1);end
                    checksum=8'h6e;
                    for(i=0;i<n;i=i+1) checksum=checksum^request[i];
                    if(checksum!=0 || request[0]!=8'h51 || request[3]!=8'h10) $fatal(1,"Bad DDC request");
                    if(request[2]==8'h03) begin
                        writes=writes+1;
                        if(scenario!=5) brightness={request[4],request[5]};
                    end
                end else begin
                    reads=reads+1;
                    reply[0]=8'h6e;reply[1]=8'h88;reply[2]=8'h02;reply[3]=(scenario==3) ? 1:0;
                    reply[4]=8'h10;reply[5]=0;reply[6]=max_brightness>>8;reply[7]=max_brightness;
                    reply[8]=brightness>>8;reply[9]=brightness;checksum=8'h50;
                    for(i=0;i<10;i=i+1) checksum=checksum^reply[i];
                    reply[10]=(scenario==2) ? checksum^8'h01:checksum;
                    for(i=0;i<11;i=i+1) send_byte(reply[i]);
                end
            end
        end
    end
    task await_mode;input [1:0] expected;integer t;
        begin t=0;while(mode!==expected && t<200000) begin @(negedge clk);t=t+1;end
            if(mode!==expected) $fatal(1,"Mode timeout scenario=%d",scenario);
        end
    endtask
    task restart;input integer fault;
        begin @(negedge clk);rst=1;scenario=fault;slave_low=0;stretch_low=0;brightness=80;level=5;
            repeat(5) @(negedge clk);rst=0;
        end
    endtask
    initial begin
        restart(0);await_mode(1);
        if(brightness!=100 || rgb_level!=10 || reads<2) $fatal(1,"DDC mapping or verification");
        level=1;wait(mode==0);await_mode(1);
        if(brightness!=20) $fatal(1,"DDC lower range");
        level=10;wait(mode==0);await_mode(1);
        if(brightness!=200) $fatal(1,"DDC upper range");
        // A user adjustment arriving while Set/readback is running is retained.
        level=4;wait(writes>=4);level=8;
        repeat(20000) @(negedge clk);
        if(mode!=1 || brightness!=160) $fatal(1,"Pending DDC adjustment lost");
        // Non-100, 16-bit monitor ranges must also map exactly.
        max_brightness=65535;restart(0);level=7;await_mode(1);
        if(brightness!=45875) $fatal(1,"16-bit range mapping");
        max_brightness=200;
        // A finite clock stretch must stall, then resume the same transaction.
        restart(0);
        fork
            begin @(negedge scl);stretch_low=1;repeat(50) @(negedge clk);stretch_low=0;end
            begin await_mode(1);end
        join
        restart(1);await_mode(2);if(rgb_level!=5) $fatal(1,"NACK fallback");
        level=3;repeat(3) @(negedge clk);if(rgb_level!=3) $fatal(1,"Fallback adjustment");
        scenario=0;await_mode(1);if(brightness!=60 || rgb_level!=10) $fatal(1,"DDC reprobe recovery");
        restart(2);await_mode(2); // checksum corruption
        restart(3);await_mode(2); // unsupported VCP
        restart(5);await_mode(2); // ACK without applying Set: must verify
        restart(4);stretch_low=1;await_mode(2);stretch_low=0;
        $display("*** PASS *** DDC query/set/readback/16-bit range/queued adjustment/NACK/checksum/unsupported/ignored-set/clock stretch/reprobe");$finish;
    end
    initial begin #5000000;$fatal(1,"DDC test watchdog");end
endmodule
