`timescale 1ns/1ps
module fifo_case #(parameter AW=10)(output reg done=0);
    reg clk=0,rst=1,clear=0,push=0,ready=0;reg [31:0] din=0;
    wire [AW:0] free_words,used_words;wire used_ge_256,overflow,valid,empty;wire [31:0] dout;
    integer cycle,head=0,tail=0,count=0,consumed=0,last_consume=0;
    reg expected_overflow=0;reg [31:0] queue[0:100000];reg [31:0] rng=32'h93de12+AW;
    always #5 clk=~clk;
    db_stream_fifo #(.AW(AW)) dut(.clk(clk),.rst(rst),.clear(clear),.push(push),.din(din),
        .free_words(free_words),.used_words(used_words),.used_ge_256(used_ge_256),.overflow(overflow),
        .valid(valid),.dout(dout),.ready(ready),.empty(empty));
    always @(posedge clk or posedge rst) begin
        if(rst || clear) begin head=0;tail=0;count=0;expected_overflow=0;last_consume=0;end
        else begin
            if(valid && ready) begin
                if(count==0 || dout!==queue[head]) $fatal(1,"AW%0d order got %h expected %h",AW,dout,queue[head]);
                if(cycle>=1200 && cycle<4500 && last_consume!=0 && cycle-last_consume>3)
                    $fatal(1,"AW%0d throughput gap %0d",AW,cycle-last_consume);
                last_consume=cycle;head=head+1;count=count-1;consumed=consumed+1;
            end
            if(push) begin
                if(free_words!=0) begin queue[tail]=din;tail=tail+1;count=count+1;end
                else expected_overflow=1;
            end
        end
    end
    initial begin
        repeat(5) @(negedge clk);rst=0;
        for(cycle=0;cycle<80000;cycle=cycle+1) begin
            @(negedge clk);
            if(free_words!==(1<<AW)-count || used_words!==count || used_ge_256!==(count>=256) ||
               overflow!==expected_overflow || empty!==(count==0))
                $fatal(1,"AW%0d occupancy/overflow cycle %0d free%0d count%0d ge256%b overflow%b expected%b",AW,cycle,free_words,count,used_ge_256,overflow,expected_overflow);
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
            din=32'ha1000000+cycle;
            clear=cycle>=5000 && cycle%997==0;
            rst=cycle>=5000 && cycle%4093==0;
            if(cycle<1200) begin push=1;ready=0;end
            else if(cycle<4500) begin push=0;ready=1;end
            else begin push=rng[0] || rng[2];ready=rng[1];end
            if(cycle>=5000 && cycle%2047==0) begin #1;rst=1;#1;rst=0;end
        end
        push=0;ready=1;rst=0;clear=0;
        repeat(4000) @(negedge clk);
        if(count!=0 || valid || consumed<5000) $fatal(1,"AW%0d drain",AW);
        done=1;
    end
endmodule
module tb_stream_fifo;
    wire d9,d10;
    fifo_case #(.AW(9)) a(d9);fifo_case #(.AW(10)) b(d10);
    initial begin wait(d9 && d10);$display("*** PASS *** stream FIFO contract: depths512/1024, full/empty, order, occupancy including prefetch, backpressure, clear/reset, throughput");$finish;end
    initial begin #2000000;$fatal(1,"FIFO timeout");end
endmodule
