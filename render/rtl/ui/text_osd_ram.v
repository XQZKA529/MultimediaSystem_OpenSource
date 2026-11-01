// Synchronous 16-bit dual-port words; text uses the low byte only.
// No RAM reset/initialization: lengths mask stale words after clear/reset.
module text_osd_ram(input wire wr_clk,wr_en,input wire [8:0] wr_addr,
    input wire [7:0] wr_data,input wire rd_clk,input wire [8:0] rd_addr,
    output wire [7:0] rd_data);
    wire [15:0] word_data;
    EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG")) u_ram(
        .clka(wr_clk),.addra({2'd0,wr_addr}),.dia({8'd0,wr_data}),.doa(),
        .bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(wr_en),.rsta(1'b0),.ocea(1'b1),
        .clkb(rd_clk),.addrb({2'd0,rd_addr}),.dib(16'd0),.dob(word_data),
        .byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(1'b0),.rstb(1'b0),.oceb(1'b1));
    assign rd_data=word_data[7:0];
endmodule
