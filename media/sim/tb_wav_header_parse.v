`timescale 1ns/1ps
module tb_wav_header_parse;
    reg clk=0,rst=1,start=0,valid=0;
    reg [7:0] byte_data=0;
    wire done,ok,payload,channels;
    wire [3:0] reject;
    wire [31:0] offset,length;
    integer count=0,done_count=0,checks=0;
    always #5 clk=~clk;
    wav_header_parse dut(.clk(clk),.rst(rst),.start_pulse(start),
        .byte_valid(valid),.byte_data(byte_data),.parse_done(done),.parse_ok(ok),
        .reject_code(reject),.data_byte_offset(offset),.data_byte_len(length),
        .channels(channels),.payload_start(payload));
    always @(negedge clk) if(done) begin
        done_count=done_count+1;
        if(!ok || !payload || reject!=0 || channels!=1 || length!=8 || offset!=count)
            $fatal(1,"Unexpected WAV result ok=%d offset=%d bytes=%d",ok,offset,count);
    end
    task put;input [7:0] value;begin
        @(negedge clk);valid=1;byte_data=value;count=count+1;
    end endtask
    task code;input [31:0] value;begin
        put(value[31:24]);put(value[23:16]);put(value[15:8]);put(value[7:0]);
    end endtask
    task size;input [31:0] value;begin
        put(value[7:0]);put(value[15:8]);put(value[23:16]);put(value[31:24]);
    end endtask
    task run;input [31:0] unknown_size;integer n,before_done;begin
        @(negedge clk);valid=0;start=1;count=0;before_done=done_count;
        @(negedge clk);start=0;
        code(32'h52494646);size(100);code(32'h57415645);
        code(32'h4a554e4b);size(unknown_size);
        if(unknown_size!=32'hffffffff)
            for(n=0;n<unknown_size+(unknown_size&1);n=n+1) put(8'ha5);
        code(32'h666d7420);size(16);
        put(1);put(0);put(2);put(0);size(48000);size(192000);
        put(4);put(0);put(16);put(0);
        code(32'h64617461);size(8);
        @(negedge clk);valid=0;
        repeat(3) @(negedge clk);
        if(done_count!=before_done+1) $fatal(1,"WAV boundary case failed size=%h",unknown_size);
        checks=checks+1;
    end endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        run(0);run(1);run(2);run(3);run(32'hffffffff);
        $display("*** PASS *** WAV unknown chunk zero/odd/even/pad/wrap boundaries %d",checks);
        $finish;
    end
    initial begin #100000; $fatal(1,"WAV parser timeout");end
endmodule
