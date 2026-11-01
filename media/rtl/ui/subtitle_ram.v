// One explicit 32K BRAM, 2048 x 16. Both ports are synchronous.
module subtitle_ram(input wire clk, input wire wr_en,input wire [10:0] addr_a,
 input wire [15:0] data_a,output wire [15:0] q_a,
 input wire rd_clk,input wire [10:0] addr_b,output wire [15:0] q_b);
`ifdef DB_BEHAVIORAL_RAM
 reg [15:0] mem[0:2047];reg [15:0] qa,qb;
 always @(posedge clk) begin if(wr_en) mem[addr_a]<=data_a;qa<=mem[addr_a];end
 always @(posedge rd_clk) qb<=mem[addr_b];
 assign q_a=qa;assign q_b=qb;
`else
 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG")) u_ram(
 .clka(clk),.addra(addr_a),.dia(data_a),.doa(q_a),.bytea(1'b0),.bytewea(1'b0),
 .csa(1'b1),.wea(wr_en),.rsta(1'b0),.ocea(1'b1),
 .clkb(rd_clk),.addrb(addr_b),.dib(16'd0),.dob(q_b),.byteb(1'b0),.byteweb(1'b0),
 .csb(1'b1),.web(1'b0),.rstb(1'b0),.oceb(1'b1));
`endif
endmodule
