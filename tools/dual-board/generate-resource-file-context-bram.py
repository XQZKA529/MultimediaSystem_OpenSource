"""Keep pending and active file metadata in independent stages of three RAMs.

The input word holds each client's pending request. An independently enabled
BRAM output register captures that word on FAT acceptance and holds it while
new pending requests overwrite the input word. No queue capacity is removed.
"""
import argparse,re
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True);a=p.parse_args()
snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
s=s.replace("parameter [27:0] IO_TIMEOUT_CYCLES = 28'd5_000_000", "parameter [27:0] IO_TIMEOUT_CYCLES = 28'd5_000_000,\n    parameter EXTERNAL_FILE_CONTEXT=0")
s=s.replace('output reg [31:0]  dbg_dir_entry_count\n', 'output reg [31:0]  dbg_dir_entry_count,\n    output wire file_context_capture\n')
assert 'output wire file_context_capture' in s
s=s.replace('reg [31:0] captured_file_size,captured_read_limit;', 'wire [31:0] captured_file_size,captured_read_limit;')
logic='''
assign file_context_capture=!rst && state_encoded==S_IDLE && !mount_start && !dir_start_i && file_start;
generate if(EXTERNAL_FILE_CONTEXT)begin
 assign captured_file_size=file_size;assign captured_read_limit=file_read_limit;
end else begin
 reg [31:0] size_q,limit_q;
 always @(posedge clk)if(file_context_capture)begin size_q<=file_size;limit_q<=file_read_limit;end
 assign captured_file_size=size_q;assign captured_read_limit=limit_q;
end endgenerate
'''
i=s.index('\nendmodule');s=s[:i]+logic+s[i:]
old='captured_file_size<=file_size; captured_read_limit<=file_read_limit;'
assert s.count(old)==1;s=s.replace(old,'')
f.write_text(s,encoding='utf-8')
# Explicitly open the optional internal handshake on the wildcard unit fixture.
for f in (a.destination/'sim').glob('*.v'):
 s=f.read_text(encoding='utf-8-sig')
 if re.search(r'fat32_ro\s*(?:#\([^;]*?\))?\s+\w+\s*\(\.\*\)',s,re.S):
  s=re.sub(r'(fat32_ro\s*(?:#\([^;]*?\))?\s+\w+\s*\()\.\*',r'\1.file_context_capture(),.*',s,flags=re.S)
  f.write_text(s,encoding='utf-8')
f=a.destination/'rtl/storage/storage_service.v';s=f.read_text(encoding='utf-8-sig')
for name in ('bmp_size_q','bmp_limit_q','txt_size_q'):
 s=re.sub(r'\b'+name+r'\s*<=\s*[^;]+;','',s)
s=s.replace('bmp_cluster_q,bmp_size_q,bmp_limit_q,txt_cluster_q,txt_size_q,map_cluster_q,map_size_q', 'bmp_cluster_q,txt_cluster_q,map_cluster_q,map_size_q')
s=s.replace('wire [31:0] ro_size=owner==TXT ? txt_size_q:bmp_size_q;', '''wire ro_file_capture;
    wire [31:0] active_bmp_size,active_txt_size,active_bmp_limit;
    resource_file_context_ram u_bmp_size(.clk(clk),.rst(rst),.capture(file_start),.publish(ro_file_capture && owner==BMP),.din(file_size),.q(active_bmp_size));
    resource_file_context_ram u_txt_size(.clk(clk),.rst(rst),.capture(txt_file_start),.publish(ro_file_capture && owner==TXT),.din(txt_file_size),.q(active_txt_size));
    resource_file_context_ram u_bmp_limit(.clk(clk),.rst(rst),.capture(file_start),.publish(ro_file_capture && owner==BMP),.din(file_read_limit),.q(active_bmp_limit));
    wire [31:0] ro_size=owner==TXT ? active_txt_size:active_bmp_size;''')
s=s.replace("wire [31:0] ro_limit=owner==TXT ? 32'd110:bmp_limit_q;", "wire [31:0] ro_limit=owner==TXT ? 32'd110:active_bmp_limit;")
s=s.replace('fat32_ro #(.FILE_MAX_BURST(FILE_MAX_BURST))', 'fat32_ro #(.FILE_MAX_BURST(FILE_MAX_BURST),.EXTERNAL_FILE_CONTEXT(1))')
s=s.replace('.dbg_dir_entry_count(dbg_dir_count)', '.dbg_dir_entry_count(dbg_dir_count),.file_context_capture(ro_file_capture)')
assert not any(re.search(r'\b'+name+r'\b',s) for name in ('bmp_size_q','bmp_limit_q','txt_size_q'))
s+='''
// Pending RAM word and active output register have independent lifetimes.
module resource_file_context_ram(input wire clk,rst,capture,publish,
 input wire [31:0] din,output wire [31:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [31:0] pending=0,active;
 always @(posedge clk)begin
  if(!rst && capture)pending<=din;
  if(!rst && publish)active<=pending;
 end
 assign q=active;
`else
 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
  .REGMODE_A("OUTREG"),.REGMODE_B("OUTREG"),.WRITEMODE_A("WRITETHROUGH"),.WRITEMODE_B("WRITETHROUGH"),
  .SRMODE("ASYNC"),.INIT_00(256'd0)) u_context(
  .clka(clk),.addra(11'd0),.dia(din[15:0]),.doa(q[15:0]),.bytea(1'b0),.bytewea(1'b0),
  .csa(!rst),.wea(capture),.rsta(1'b0),.ocea(publish && !rst),
  .clkb(clk),.addrb(11'd1024),.dib(din[31:16]),.dob(q[31:16]),.byteb(1'b0),.byteweb(1'b0),
  .csb(!rst),.web(capture),.rstb(1'b0),.oceb(publish && !rst));
`endif
endmodule
'''
f.write_text(s,encoding='utf-8')
