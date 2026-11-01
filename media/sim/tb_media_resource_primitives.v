`timescale 1ns/1ps
// Run with native EG4 models as well as DB_BEHAVIORAL_RAM. Cache outputs
// during refill are private and intentionally unspecified; all read clocks
// and the DSP's input-register/output-enable boundary are checked.
module tb_media_resource_primitives;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1,write=0,enable=0;
    reg [6:0] write_address=0,read_address=0;
    reg [31:0] din=0;
    reg [63:0] geometry_in=0;
    wire [31:0] cache_q;
    wire [63:0] geometry_q;
    resource_fat_cache32 cache(.clk(clk),.write(write),
        .write_address(write_address),.read_address(read_address),.din(din),.q(cache_q));
    resource_fat_geometry_hold geometry(.clk(clk),.rst(rst),.enable(enable),
        .din(geometry_in),.q(geometry_q));
    reg [31:0] memory[0:127];
    reg [31:0] expected_read;
    reg [63:0] prefetched=0,held=0;
    reg [31:0] random_state=32'hd09a4517;
    integer i,checks=0;
    always @(posedge clk) begin
        if(write) memory[write_address]=din;
        else expected_read=memory[read_address];
    end
    always @(posedge clk or posedge rst)
        if(rst) begin prefetched<=0;held<=0;end
        else begin prefetched<=geometry_in;if(enable)held<=prefetched;end
    task check;
        begin
            @(posedge clk);#1;
            if(geometry_q!==held) $fatal(1,"geometry DSP pipeline/hold mismatch %0d",checks);
            if(!write && cache_q!==expected_read)
                $fatal(1,"cache read/bank mismatch at %0d got=%h expected=%h",read_address,cache_q,expected_read);
            checks=checks+1;
        end
    endtask
    initial begin
        // Let the vendor global reset finish before checking native RAM/DSP.
        repeat(30) @(negedge clk);
        rst=0;
        for(i=0;i<128;i=i+1) begin
            write=1;write_address=i;din={16'hca00+i[15:0],16'h3511^i[15:0]};
            check();@(negedge clk);
        end
        write=0;
        for(i=0;i<128;i=i+1) begin
            read_address=i;check();@(negedge clk);
        end
        for(i=0;i<4096;i=i+1) begin
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            write=random_state[3:0]==0;
            write_address=random_state[10:4];read_address=random_state[17:11];
            din=random_state;geometry_in={random_state,~random_state};
            enable=random_state[18];rst=(i==2048 || i==2049);
            check();@(negedge clk);
        end
        $display("*** PASS *** media native cache banks/read latency and geometry DSP prefetch/enable/reset: %0d checks",checks);
        $finish;
    end
    initial begin #100000;$fatal(1,"resource primitives watchdog");end
endmodule
