module board_reset #(parameter HOLD_CYCLES=1_000_000)(
    input wire clk,input wire rst_n,input wire locked,output wire rst
);
    reg [19:0] count=0;
    reg held=1;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) begin count<=0;held<=1;end
        else if(!locked) begin count<=0;held<=1;end
        else if(count<HOLD_CYCLES) begin count<=count+1'b1;held<=1;end
        else held<=0;
    assign rst=held || !rst_n || !locked;
endmodule
