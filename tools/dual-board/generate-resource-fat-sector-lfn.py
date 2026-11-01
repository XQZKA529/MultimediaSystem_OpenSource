"""Use the directory sector BRAM's spare addresses/write-port read for LFN.

The 512 directory bytes retain their read port and capacity. Addresses 512..543
store all 32 eight-bit ordinal products. The write port reads that ROM while
idle; entry byte zero settles many clocks before DIR_DECODE. No added stages,
BRAMs, altered CRC, arithmetic precision or pending-operation storage.
"""
import argparse
from pathlib import Path
import re
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args();snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
old='reg [7:0] sector_buf [0:511] /* fehdl force_ram=1, ram_style="bram" */;'
assert s.count(old)==1
s=s.replace(old,'wire [7:0] lfn_ordinal_product;')
s=s.replace('reg [7:0] sector_q;', 'wire [7:0] sector_q;')
assert s.count('    sector_q <= sector_buf[sector_addr];')==1
s=s.replace('    sector_q <= sector_buf[sector_addr];','')
assert s.count('sector_buf[rd_index]<=blk_data_i;')==1
s=s.replace('sector_buf[rd_index]<=blk_data_i;', 'begin /* Dedicated synchronous sector RAM captures at this same edge. */ end')
function=re.search(r'function \[7:0\] lfn_ordinal_base;.*?endfunction',s,re.S)[0]
s=s.replace(function,'')
s=s.replace("lfn_base<=lfn_ordinal_base(entry_first&8'h1f);", "lfn_base<=(entry_first[4:0]>=1 && entry_first[4:0]<=19) ? lfn_ordinal_product-8'd13:8'd247;")
s=s.replace("lfn_len<=((entry_first&8'h1f)==20)?8'd255:((entry_first&8'h1f)*13);", "lfn_len<=entry_first[4:0]==20 ? 8'd255:lfn_ordinal_product;")
assert 'lfn_ordinal_base(' not in s and "((entry_first&8'h1f)*13)" not in s
instance='''
 // Exact original RD_DIR write predicate, including reset and abort priority.
 wire sector_write=!rst && control_state==S_RD_WAIT && blk_data_valid_i &&
  rd_kind==RD_DIR && rd_index<512 && !(file_abort_i && active_op==OP_FILE &&
  control_state!=S_IDLE && control_state!=S_FAIL);
 resource_sector_lfn_ram u_sector(.clk(clk),.write(sector_write),
  .write_addr(rd_index[8:0]),.din(blk_data_i),.read_addr(sector_addr),.q(sector_q),
  .ordinal(entry_first[4:0]),.product(lfn_ordinal_product));
'''
s=s.replace('\nendmodule',instance+'\nendmodule',1)
helper='''
module resource_sector_lfn_ram(input wire clk,write,input wire [8:0] write_addr,
 input wire [7:0] din,input wire [8:0] read_addr,output wire [7:0] q,
 input wire [4:0] ordinal,output wire [7:0] product);
 wire [9:0] a=write ? {1'b0,write_addr}:{1'b1,4'd0,ordinal};
`ifdef DB_BEHAVIORAL_RAM
 reg [7:0] mem[0:1023];reg [7:0] qa,qb;integer n;
 initial for(n=0;n<32;n=n+1)mem[512+n]=(n*13)&255;
 always @(posedge clk)begin
  if(write)mem[a]<=din;
  qa<=mem[a];qb<=mem[{1'b0,read_addr}];
 end
 assign q=qb;assign product=qa;
`else
 wire [8:0] qa,qb;assign q=qb[7:0];assign product=qa[7:0];
 EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),.GSR("DISABLE"),
'''
words=[0]*1024
for n in range(32):words[512+n]=(n*13)&255
for bank in range(32):
    bits=sum(words[bank*32+n]<<(8*n) for n in range(32))
    helper+=f" .INIT_{bank:02X}(256'h{bits:064x})"+(',\n' if bank<31 else ') u_ram(\n')
helper+=''' // Native 9-bit writes use low address pins as write enables.
 // Match the address suffix in TD's exported 512x8 sector RAM.
 .clka(clk),.cea(1'b1),.ocea(1'b1),.rsta(1'b0),.wea(write),.csa(3'b111),.addra({a,3'b111}),.dia({1'b0,din}),.doa(qa),
 .clkb(clk),.ceb(1'b1),.oceb(1'b1),.rstb(1'b0),.web(1'b0),.csb(3'b111),.addrb({1'b0,read_addr,3'b111}),.dib(9'd0),.dob(qb));
`endif
endmodule
'''
f.write_text(s+helper,encoding='utf-8')
w=a.destination.parent/'sector-lfn-generation';w.mkdir()
(w/'original_base.v').write_text(function,encoding='utf-8')
