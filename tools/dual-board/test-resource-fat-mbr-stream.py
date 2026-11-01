"""Stress first-partition ownership with real 512-byte MBR/DBR streams."""
import argparse,re
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True)
p.add_argument('--bps-probe',action='store_true')
p.add_argument('--tag',default='mbr-stream-equivalence');a=p.parse_args()
b=a.candidate.resolve();r=a.reference.resolve();w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
s=(r/'rtl/fat/fat32_ro.v').read_text(encoding='utf-8-sig')
ref=w/'reference.v';ref.write_text(s.replace('module fat32_ro #(', 'module reference_fat #(').replace('resource_fat_dsp_hold','reference_fat_dsp_hold'),encoding='utf-8')
header=re.sub(r'//[^\n]*','',s[:s.index('\n);')])
ports=re.findall(r'\b(input|output)\s+(?:wire|reg)\s*(\[[^]]+\])?\s*(\w+)',header)
tb='''module tb;
reg clk=0,rst=1;always #5 clk=~clk;
reg mount_start=0,blk_grant=0,blk_data_valid=0,blk_end=0,blk_error=0;
reg [7:0] blk_data=0;
reg [7:0] disk[0:1023];reg busy=0;integer pos=0,base=0,cycles=0;
wire blk_req,mount_done,mount_ok;wire [31:0] blk_lba;
integer seed=32'h5bad1234,n,j,k,t,checks=0,selected_checks=0,reset_tests=0;
reg found;reg [31:0] lba,size,expected_lba,expected_size;
reg [7:0] kind;integer reset_point;
'''
driven={'clk','rst','mount_start','blk_grant','blk_data','blk_data_valid','blk_end','blk_error'}
used_outputs={'blk_req','blk_lba','mount_done','mount_ok'}
for module,instance in [('fat32_ro','dut'),('reference_fat','ref')]:
 tb+=module+' #(.IO_TIMEOUT_CYCLES(10000)) '+instance+'('+','.join(
    f'.{name}({name if name in driven else "32\'d0"})' if direction=='input' else
    f'.{name}({name})' if instance=='dut' and name in used_outputs else f'.{name}()'
    for direction,width,name in ports)+');\n'
tb+='always @(posedge clk)begin #1;if(!rst)begin checks=checks+1;\n'
for direction,width,name in ports:
 if direction=='output':tb+=f'if(dut.{name}!==ref.{name})$fatal(1,"MBR public mismatch {name} case %0d",n);\n'
tb+='''end end
always @(negedge clk)if(!rst && dut.control_state==dut.S_MOUNT_MBR && dut.mbr_found)begin
 if(!found || dut.mbr_sel_lba!==expected_lba || dut.mbr_sel_size!==expected_size)
  $fatal(1,"first valid partition changed case %0d",n);
 selected_checks=selected_checks+1;
end
always @(negedge clk)begin
 blk_grant=0;blk_data_valid=0;blk_end=0;blk_error=0;
 if(rst)begin busy=0;pos=0;end
 else if(!busy && blk_req)begin busy=1;pos=0;base=(blk_lba==0)?0:512;blk_grant=1;end
 else if(busy)begin
  if(pos==512)begin blk_end=1;busy=0;end
  else if(($random(seed)&3)!=0)begin blk_data=disk[base+pos];blk_data_valid=1;pos=pos+1;end
 end
end
task put32;input integer a;input [31:0] v;begin
 disk[a]=v[7:0];disk[a+1]=v[15:8];disk[a+2]=v[23:16];disk[a+3]=v[31:24];end endtask
initial begin
 for(j=0;j<1024;j=j+1)disk[j]=0;
 disk[523]=0;disk[524]=2;disk[525]=1;disk[526]=1;disk[528]=1;
 put32(544,1000);put32(548,8);put32(556,2);disk[1022]=8'h55;disk[1023]=8'haa;
 repeat(4)@(negedge clk);#1;rst=0;
 for(n=0;n<1024;n=n+1)begin
  for(j=0;j<512;j=j+1)disk[j]=0;
  disk[510]=(n%17==0)?0:8'h55;disk[511]=(n%19==0)?0:8'haa;
  found=0;expected_lba=0;expected_size=0;
  for(k=0;k<4;k=k+1)begin
   case($random(seed)&7)
    0:kind=8'h0b;1:kind=8'h0c;2:kind=8'h1b;3:kind=8'h1c;default:kind=$random(seed);
   endcase
   if(n<256 && k==0)kind=n;
   lba=$random(seed);size=$random(seed);
   case((n+k)%13)0:lba=0;1:lba=1;2:lba=32'hffffffff;3:lba=32'h80000000;endcase
   case((n+k)%11)0:size=0;1:size=1;2:size=32'hffffffff;3:size=32'h80000000;endcase
   disk[450+k*16]=kind;put32(454+k*16,lba);put32(458+k*16,size);
   if(!found && lba!=0 && (kind==8'h0b || kind==8'h0c || kind==8'h1b || kind==8'h1c))begin
    found=1;expected_lba=lba;expected_size=size;
   end
  end
  @(negedge clk);#1;mount_start=1;@(negedge clk);#1;mount_start=0;
  if(n%31==0)begin
   reset_point=446+(n%64);
   wait(dut.rd_index>=reset_point && dut.control_state==dut.S_RD_WAIT);
   @(negedge clk);#1;rst=1;repeat(2)@(negedge clk);#1;rst=0;
   @(negedge clk);#1;mount_start=1;@(negedge clk);#1;mount_start=0;
   reset_tests=reset_tests+1;
  end
  t=0;
  while(!mount_done && t<10000)begin @(negedge clk);#1;t=t+1;end
  if(t>=10000)$fatal(1,"mount deadline exceeded case %0d",n);
  repeat(4)@(negedge clk);
 end
 $display("PASS 1024 MBR/DBR mounts, all 256 type bytes, 32-bit LBA/size boundaries, first-slot locking, %0d selected checks, %0d mid-entry resets, %0d public cycles",selected_checks,reset_tests,checks);$finish;
end
initial begin #200000000;$fatal(1,"MBR stress timeout");end
endmodule
'''
if a.bps_probe:
 tb=tb.replace('  found=0;expected_lba=0;expected_size=0;', '''
  if(n<512)begin
    disk[510]=8'h55;disk[511]=8'haa;
    disk[523]=(n<256)?n:0;disk[524]=(n<256)?2:n-256;
  end else begin disk[523]=0;disk[524]=2;end
  found=0;expected_lba=0;expected_size=0;''')
 tb=tb.replace('   if(n<256 && k==0)kind=n;', '   if(n>=512 && n<768 && k==0)kind=n-512;')
 tb=tb.replace('   disk[450+k*16]=kind;', "   if(n<512 && k==0)begin kind=8'h0b;lba=10;size=32'hffffffff;end\n   disk[450+k*16]=kind;")
 tb=tb.replace('  repeat(4)@(negedge clk);', '''
  if(n<512)begin
    if(disk[523]==0 && disk[524]==2)begin
      if(!mount_ok)$fatal(1,"legal 512-byte BPS rejected");
    end else if(mount_ok || dut.fat_error_code!==`FAT_E_BPS)
      $fatal(1,"BPS byte validation/priority differs at %0d",n);
  end
  repeat(4)@(negedge clk);''')
 tb=tb.replace('PASS 1024 MBR/DBR mounts,', 'PASS 512 exhaustive BPS byte mutations + 512 MBR/DBR mounts,')
test=w/'tb.v';test.write_text(tb,encoding='utf-8')
for native in (False,True):
 simulate(w/('native' if native else 'behavioral'),'tb',[ref,b/'rtl/fat/fat32_ro.v',test],
    includes=[b/'rtl',b/'rtl/pkg',b/'rtl/fat'],defines=[] if native else ['DB_BEHAVIORAL_RAM'],native=native)
