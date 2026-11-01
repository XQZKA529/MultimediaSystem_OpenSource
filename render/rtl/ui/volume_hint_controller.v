// Wall-clock timeout; visibility and digits only change between video frames.
module volume_hint_controller #(parameter CLK_HZ=75000000,parameter SECONDS=2)(
    input wire clk,rst,vs,trigger,suppress,input wire [4:0] level,
    output reg show,output reg [4:0] display_level
);
    localparam CYCLES=CLK_HZ*SECONDS;
    reg [$clog2(CYCLES+1)-1:0] remaining;
    reg vs_d;
    always @(posedge clk or posedge rst) begin
        if(rst) begin remaining<=0;show<=0;display_level<=20;vs_d<=0;end
        else begin
            vs_d<=vs;
            if(suppress) remaining<=0;
            else if(trigger) remaining<=CYCLES;
            else if(remaining!=0) remaining<=remaining-1'b1;
            if(vs && !vs_d) begin
                show<=!suppress && (trigger || remaining>1);
                display_level<=level;
            end
        end
    end
endmodule
