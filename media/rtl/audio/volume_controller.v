// Single owner of the user's volume. Inputs are semantic actions, not key codes.
module volume_controller(
    input wire clk,rst,increase,decrease,shortcut,
    output reg [4:0] level,output reg changed,hint,
    output reg [31:0] revision
);
    wire inc=increase && !decrease;
    wire dec=decrease && !increase;
    wire change_level=(inc && level<20) || (dec && level>0);
    always @(posedge clk or posedge rst) begin
        if(rst) begin level<=20;changed<=0;hint<=0;revision<=0;end
        else begin
            changed<=0;hint<=0;
            if(change_level || (shortcut && (inc || dec))) begin
                if(inc && level<20) level<=level+1'b1;
                else if(dec && level>0) level<=level-1'b1;
                revision<=revision+1'b1;changed<=1;hint<=shortcut;
            end
        end
    end
endmodule
