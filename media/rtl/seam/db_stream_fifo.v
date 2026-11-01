module db_stream_fifo #(parameter AW=10)(
    input wire clk,rst,clear,input wire push,input wire [31:0] din,
    output wire [AW:0] free_words,output wire [AW:0] used_words,output reg used_ge_256,output reg overflow,
    output wire valid,output wire [31:0] dout,input wire ready,output reg empty
);
    reg [31:0] mem[0:(1<<AW)-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [AW:0] wp,rp;
    reg [AW:0] used_count;
    reg [31:0] q,hold;
    reg hv,pending;
    wire not_full=used_count!=(1<<AW);
    // Keep occupancy in a counter rather than subtracting the read and write
    // pointers on the FIFO credit path. This register is updated for accepted
    // pushes and consumed output words, including simultaneous push/pop.
    assign used_words=used_count;
    assign free_words=(1<<AW)-used_words;
    assign valid=hv;assign dout=hold;
    always @(posedge clk) begin
        if(push && not_full && !clear) mem[wp[AW-1:0]]<=din;
        q<=mem[rp[AW-1:0]];
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin wp<=0;rp<=0;used_count<=0;used_ge_256<=0;hv<=0;pending<=0;overflow<=0;hold<=0;empty<=1;end
        else if(clear) begin wp<=0;rp<=0;used_count<=0;used_ge_256<=0;hv<=0;pending<=0;overflow<=0;empty<=1;end
        else begin
            // Exact post-edge occupancy, including simultaneous push/pop.
            // The packet arbiter need not decode pointer equality on its
            // priority/object selection path.
            if(push && not_full) begin
                if(!(hv && ready)) empty<=0;
            end else if(hv && ready) empty<=wp==rp+1'b1;
            if(push) begin if(not_full) wp<=wp+1'b1;else overflow<=1;end
            case ({push && not_full,hv && ready})
                2'b10: begin
                    used_count<=used_count+1'b1;
                    used_ge_256<=used_count>=((1<<8)-1);
                end
                2'b01: begin
                    used_count<=used_count-1'b1;
                    used_ge_256<=used_count>(1<<8);
                end
                default: used_count<=used_count;
            endcase
            if(hv && ready) begin hv<=0;rp<=rp+1'b1;end
            if(!hv && !pending && wp!=rp) pending<=1;
            else if(pending) begin hold<=q;hv<=1;pending<=0;end
        end
    end
endmodule
