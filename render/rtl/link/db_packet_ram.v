// True two-port packet memory: one bus read/write port and one MAC read port.
// Explicit vendor primitive prevents inference from duplicating 8 KiB storage.
module db_packet_ram #(parameter AW=11,parameter DW=32)(
    input wire aclk,input wire awe,input wire [AW-1:0] aaddr,
    input wire [DW-1:0] adata,output wire [DW-1:0] aq,
    input wire bclk,input wire [AW-1:0] baddr,output wire [DW-1:0] bq
);
`ifdef DB_BEHAVIORAL_RAM
    reg [DW-1:0] mem[0:(1<<AW)-1];reg [DW-1:0] qa,qb;
    always @(posedge aclk) if(awe) mem[aaddr]<=adata;else qa<=mem[aaddr];
    always @(posedge bclk) qb<=mem[baddr];
    assign aq=qa;assign bq=qb;
`else
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(DW),.DATA_WIDTH_B(DW),
        .ADDR_WIDTH_A(AW),.ADDR_WIDTH_B(AW),.MODE("DP"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.IMPLEMENT("9K")) u_ram(
        .clka(aclk),.cea(1'b1),.ocea(1'b1),.rsta(1'b0),.wea(awe),.bea(1'b1),.addra(aaddr),.dia(adata),.doa(aq),
        .clkb(bclk),.ceb(1'b1),.oceb(1'b1),.rstb(1'b0),.web(1'b0),.beb(1'b1),.addrb(baddr),.dib({DW{1'b0}}),.dob(bq));
`endif
endmodule
