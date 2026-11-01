"""Generate native, initialized, synchronous dual-port BRAM32K ROMs."""
def rom(name, words, aw):
    words=words+[0]*((1<<aw)-len(words))
    banks=(len(words)+2047)//2048
    if banks not in (1,2):raise ValueError('Only one/two-bank tables are supported')
    text=f'\nmodule {name}(input wire clk,input wire [{aw-1}:0] addr,addr_b,output wire [15:0] q,q_b);\n'
    text+='`ifdef DB_BEHAVIORAL_RAM\n'
    text+=f'reg [15:0] mem[0:{len(words)-1}];reg [15:0] qa,qb;assign q=qa;assign q_b=qb;\ninitial begin\n'
    text+=''.join(f"mem[{i}]=16'h{w:04x};\n" for i,w in enumerate(words))
    text+='end\nalways @(posedge clk) begin qa<=mem[addr];qb<=mem[addr_b];end\n`else\n'
    for bank in range(banks):
        text+=f'wire [15:0] qa{bank},qb{bank};\nEG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),\n'
        part=words[bank*2048:(bank+1)*2048]+[0]*max(0,2048-len(words[bank*2048:(bank+1)*2048]))
        for i in range(128):
            value=sum(part[i*16+j]<<(16*j) for j in range(16))
            text+=f".INIT_{i:02X}(256'h{value:064x})"+(',\n' if i<127 else '\n')
        a='addr[10:0]' if aw>=11 else f"{{{11-aw}'d0,addr}}"
        b='addr_b[10:0]' if aw>=11 else f"{{{11-aw}'d0,addr_b}}"
        text+=f") u{bank}(.clka(clk),.addra({a}),.doa(qa{bank}),.dia(16'd0),.bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(1'b0),.rsta(1'b0),.ocea(1'b1),\n.clkb(clk),.addrb({b}),.dob(qb{bank}),.dib(16'd0),.byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(1'b0),.rstb(1'b0),.oceb(1'b1));\n"
    if banks==1:text+='assign q=qa0;assign q_b=qb0;\n'
    else:text+='reg ba,bb;always @(posedge clk) begin ba<=addr[11];bb<=addr_b[11];end\nassign q=ba ? qa1:qa0;assign q_b=bb ? qb1:qb0;\n'
    return text+'`endif\nendmodule\n'


def byte_rom9(name, words):
    """One synchronous 1024x8 ROM in a native BRAM9K, no output register."""
    if len(words)>1024 or any(not 0<=w<256 for w in words):
        raise ValueError('BRAM9K byte ROM requires at most 1024 byte values')
    words=words+[32]*(1024-len(words))
    text=f'\nmodule {name}(input wire clk,input wire [9:0] addr,output wire [7:0] q);\n'
    text+='`ifdef DB_BEHAVIORAL_RAM\nreg [7:0] mem[0:1023];reg [7:0] qr;assign q=qr;\ninitial begin\n'
    text+=''.join(f"mem[{i}]=8'd{w};\n" for i,w in enumerate(words))
    text+='end\nalways @(posedge clk) qr<=mem[addr];\n`else\nwire [8:0] qr;assign q=qr[7:0];\n'
    text+='EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),.GSR("DISABLE"),\n'
    for i in range(32):
        value=sum(words[i*32+j]<<(8*j) for j in range(32))
        text+=f".INIT_{i:02X}(256'h{value:064x})"+(',\n' if i<31 else ') u_rom(\n')
    text+=".clka(clk),.cea(1'b1),.ocea(1'b1),.rsta(1'b0),.wea(1'b0),.csa(3'b111),.addra({addr,3'b000}),.dia(9'd0),.doa(qr),\n"
    text+=".clkb(clk),.ceb(1'b0),.oceb(1'b0),.rstb(1'b0),.web(1'b0),.csb(3'b000),.addrb(13'd0),.dib(9'd0),.dob());\n`endif\nendmodule\n"
    return text


def byte_dual_rom9(name, words):
    """Two independent synchronous byte reads from one native BRAM9K."""
    if len(words)!=1024 or any(not 0<=w<256 for w in words):
        raise ValueError('Dual byte ROM requires exactly 1024 byte values')
    text=f'\nmodule {name}(input wire clk,input wire [9:0] a,b,output wire [7:0] qa,qb);\n'
    text+='`ifdef DB_BEHAVIORAL_RAM\nreg [7:0] mem[0:1023],ra,rb;assign qa=ra;assign qb=rb;\ninitial begin\n'
    text+=''.join(f"mem[{i}]=8'd{v};\n" for i,v in enumerate(words))
    text+='end\nalways @(posedge clk)begin ra<=mem[a];rb<=mem[b];end\n`else\n'
    text+='wire [8:0] ra,rb;assign qa=ra[7:0];assign qb=rb[7:0];\n'
    text+='EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),.GSR("DISABLE"),\n'
    for i in range(32):
        value=sum(words[i*32+j]<<(8*j) for j in range(32))
        text+=f".INIT_{i:02X}(256'h{value:064x})"+(',\n' if i<31 else ') u_rom(\n')
    text+=".clka(clk),.cea(1'b1),.ocea(1'b1),.rsta(1'b0),.wea(1'b0),.csa(3'b111),.addra({a,3'b000}),.dia(9'd0),.doa(ra),\n"
    text+=".clkb(clk),.ceb(1'b1),.oceb(1'b1),.rstb(1'b0),.web(1'b0),.csb(3'b111),.addrb({b,3'b000}),.dib(9'd0),.dob(rb));\n`endif\nendmodule\n"
    return text
