// Source authority and bounded chronological groups. Bit 0=B0, 1=B1, 2=C.
module emergency_inputs #(parameter FILTER_CYCLES=100000)(
    input wire clk,rst,gpio_b0,gpio_b1,
    input wire key_down,key_online,key_cancel,input wire [3:0] key_id,
    input wire [32:0] clock_live,
    output reg [2:0] sources,output reg [8:0] groups,
    output reg [98:0] timestamps,
    output wire active
);
    localparam CW=(FILTER_CYCLES>1) ? $clog2(FILTER_CYCLES):1;
    (* async_reg="true" *) reg [1:0] gpio_sync1,gpio_sync2;
    reg [1:0] gpio_level;
    reg [CW-1:0] count0,count1;
    reg held,armed;
    reg [2:0] confirmed_sources;
    reg [32:0] confirmed_time;
    wire press=key_online && armed && key_down && !held && !key_cancel;
    wire accept0=gpio_sync2[0]!=gpio_level[0] && count0==FILTER_CYCLES-1;
    wire accept1=gpio_sync2[1]!=gpio_level[1] && count1==FILTER_CYCLES-1;
    wire [2:0] next_sources={confirmed_sources[2] ^ (press && key_id==11),
        accept1 ? gpio_sync2[1]:gpio_level[1],accept0 ? gpio_sync2[0]:gpio_level[0]};
    // Register confirmation before order compaction; avoid a counter-to-order path.
    wire [2:0] additions=confirmed_sources & ~sources;
    wire [2:0] kept0=groups[2:0] & confirmed_sources;
    wire [2:0] kept1=groups[5:3] & confirmed_sources;
    wire [2:0] kept2=groups[8:6] & confirmed_sources;
    wire [2:0] first=kept0!=0 ? kept0:(kept1!=0 ? kept1:kept2);
    wire [2:0] second=kept0!=0 ? (kept1!=0 ? kept1:kept2):(kept1!=0 ? kept2:3'd0);
    wire [2:0] third=(kept0!=0 && kept1!=0) ? kept2:3'd0;
    wire [8:0] next_groups={
        second==0 ? 3'd0:(third==0 ? additions:third),
        first==0 ? 3'd0:(second==0 ? additions:second),
        first==0 ? additions:first};
    assign active=|sources;
    always @(posedge clk or posedge rst) begin
        if(rst) begin gpio_sync1<=0;gpio_sync2<=0;gpio_level<=0;
            count0<=0;count1<=0;held<=0;armed<=0;confirmed_sources<=0;sources<=0;groups<=0;
            confirmed_time<=0;timestamps<=0;end
        else begin
            gpio_sync1<={gpio_b1,gpio_b0};gpio_sync2<=gpio_sync1;
            if(gpio_sync2[0]==gpio_level[0] || accept0) count0<=0;else count0<=count0+1'b1;
            if(gpio_sync2[1]==gpio_level[1] || accept1) count1<=0;else count1<=count1+1'b1;
            if(accept0) gpio_level[0]<=gpio_sync2[0];
            if(accept1) gpio_level[1]<=gpio_sync2[1];
            if(!key_online || key_cancel) begin held<=0;armed<=0;end
            else if(!key_down) begin held<=0;armed<=1;end
            else if(press) held<=1;
            confirmed_sources<=next_sources;sources<=confirmed_sources;groups<=next_groups;
            // Pre-edge calendar value, aligned with the confirmation pipeline.
            // Invalid slots stay intact internally for the recovery view.
            if(|(next_sources & ~confirmed_sources)) confirmed_time<=clock_live;
            if(additions[0]) timestamps[32:0]<=confirmed_time;
            if(additions[1]) timestamps[65:33]<=confirmed_time;
            if(additions[2]) timestamps[98:66]<=confirmed_time;
        end
    end
endmodule
