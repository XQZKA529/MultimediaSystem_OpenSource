`timescale 1ns/1ps
// Independent directory fixture/scoreboard. No private directory datapath
// signals are used: names and metadata are checked at the public interface.
module tb_fat32_directory;
reg clk=0,rst=1;always #5 clk=~clk;
reg mount_start=0,dir_start=0;
wire blk_req;wire [31:0] blk_lba;wire [15:0] blk_count;
reg blk_grant=0,blk_data_valid=0,blk_end=0;
reg [7:0] blk_data=0;
wire mount_done,mount_ok,dir_done,dir_ok;
wire entry_start,name_valid,entry_end,is_dir,is_lfn;
wire [7:0] name_char,name_index,name_len,attr,error_code,state;
wire [31:0] first_cluster,file_bytes;
fat32_ro dut(.clk(clk),.rst(rst),.blk_req(blk_req),.blk_lba(blk_lba),.blk_count(blk_count),
 .blk_grant(blk_grant),.blk_data(blk_data),.blk_data_valid(blk_data_valid),
 .blk_end(blk_end),.blk_error(1'b0),.mount_start(mount_start),.mount_done(mount_done),
 .mount_ok(mount_ok),.fat_error_code(error_code),.dir_start(dir_start),
 .dir_entry_start(entry_start),.dir_name_valid(name_valid),.dir_name_char(name_char),
 .dir_name_index(name_index),.dir_entry_end(entry_end),.dir_entry_name_len(name_len),
 .dir_entry_first_cluster(first_cluster),.dir_entry_size(file_bytes),.dir_entry_attr(attr),
 .dir_entry_is_dir(is_dir),.dir_entry_is_lfn(is_lfn),.dir_done(dir_done),.dir_ok(dir_ok),
 .file_start(1'b0),.file_first_cluster(32'd0),.file_size(32'd0),.file_read_limit(32'd0),
 .file_read_ready(1'b1),.file_abort(1'b0),.map_start(1'b0),.map_first_cluster(32'd0),
 .map_size(32'd0),.map_abort(1'b0),.dbg_fat_state(state));
reg [7:0] disk[0:65535];
reg [2039:0] expected_name[0:63];
reg [7:0] expected_len[0:63],expected_attr[0:63];
reg [31:0] expected_cluster[0:63],expected_size[0:63];
reg expected_lfn[0:63];
integer slots=0,expected=0,seen=0,characters=0,cycles=0;
integer read_pos=0,read_base=0,read_size=0;
reg reading=0,entry_open=0;
integer i,j,k,rounds;reg [2039:0] long_name;reg [87:0] alias_name;

function integer slot_address;
 input integer slot;
 // Root clusters 2 -> 4 -> 6 ... deliberately skip one data cluster.
 begin slot_address=(19+2*(slot/16))*512+(slot%16)*32;end
endfunction
task put16;input integer a;input [15:0] v;begin disk[a]=v[7:0];disk[a+1]=v[15:8];end endtask
task put32;input integer a;input [31:0] v;begin
 disk[a]=v[7:0];disk[a+1]=v[15:8];disk[a+2]=v[23:16];disk[a+3]=v[31:24];end endtask
function [7:0] checksum;
 input [87:0] alias_bytes;integer n;reg [7:0] c;
 begin c=0;for(n=0;n<11;n=n+1)c={c[0],c[7:1]}+alias_bytes[(10-n)*8+:8];checksum=c;end
endfunction
task character16;input integer a,n;input [15:0] c;integer off;begin
 case(n)0:off=1;1:off=3;2:off=5;3:off=7;4:off=9;5:off=14;6:off=16;
 7:off=18;8:off=20;9:off=22;10:off=24;11:off=28;default:off=30;endcase
 put16(a+off,c);end endtask
task add_alias;
 input [87:0] alias_bytes;input [7:0] attributes,ntres;
 input [2039:0] text;input integer length;input use_lfn;
 integer a,n;
 begin
  a=slot_address(slots);slots=slots+1;
  for(n=0;n<11;n=n+1)disk[a+n]=alias_bytes[(10-n)*8+:8];
  disk[a+11]=attributes;disk[a+12]=ntres;
  put16(a+20,16'h0123);put16(a+26,16'h4567);put32(a+28,32'hfedcba98-expected);
  expected_name[expected]=text;expected_len[expected]=length;expected_attr[expected]=attributes;
  expected_cluster[expected]=32'h01234567;expected_size[expected]=32'hfedcba98-expected;
  expected_lfn[expected]=use_lfn;expected=expected+1;
 end
endtask
task add_long;
 input [2039:0] text;input integer length;input [87:0] alias_bytes;
 input integer damage; // 1 checksum, 2 ordinal, 3 type, 4 reserved cluster, 5 Unicode.
 input [2039:0] fallback;input integer fallback_length;
 integer a,ord,n,index,parts;reg [15:0] c;
 begin
  parts=(length+12)/13;
  for(ord=parts;ord>0;ord=ord-1)begin
   a=slot_address(slots);slots=slots+1;
   disk[a]=ord | ((ord==parts)?8'h40:0);disk[a+11]=8'h0f;
   disk[a+13]=checksum(alias_bytes)^((damage==1)?8'h01:8'h00);
   if(damage==2 && ord==1)disk[a]=3;
   if(damage==3)disk[a+12]=1;
   if(damage==4)put16(a+26,1);
   for(n=0;n<13;n=n+1)begin
    index=(ord-1)*13+n;
    if(index<length)c={8'd0,text[(length-1-index)*8+:8]};
    else if(index==length)c=0;else c=16'hffff;
    if(damage==5 && index==0)c=16'h4e2d;
    character16(a,n,c);
   end
  end
  if(damage>=1 && damage<=4)add_alias(alias_bytes,8'h20,0,fallback,fallback_length,0);
  else if(damage==5)begin
   long_name=text;long_name[(length-1)*8+:8]="?";
   add_alias(alias_bytes,8'h20,0,long_name,length,1);
  end else add_alias(alias_bytes,8'h20,0,text,length,1);
 end
endtask

initial begin
 for(i=0;i<65536;i=i+1)disk[i]=0;
 disk[510]=8'h55;disk[511]=8'haa;disk[450]=8'h0c;put32(454,10);put32(458,1000);
 put16(10*512+11,512);disk[10*512+13]=1;put16(10*512+14,1);disk[10*512+16]=1;
 put32(10*512+32,1000);put32(10*512+36,8);put32(10*512+44,2);
 disk[10*512+510]=8'h55;disk[10*512+511]=8'haa;
 put32(11*512,32'h0ffffff8);put32(11*512+4,32'h0fffffff);
 // Deleted entries and a volume label must never be emitted.
 for(i=0;i<14;i=i+1)begin disk[slot_address(slots)]=8'he5;slots=slots+1;end
 disk[slot_address(slots)]="V";disk[slot_address(slots)+11]=8'h08;slots=slots+1;
 // A maximum-length LFN crosses three fragmented root clusters.
 long_name=0;for(i=0;i<255;i=i+1)long_name[(254-i)*8+:8]="A"+(i%26);
 add_long(long_name,255,"MAXNAM~1TXT",0,0,0);
 add_alias("README     ",8'h20,8'h08,"readme",6,0);
 add_alias("PHOTO   BMP",8'h21,8'h18,"photo.bmp",9,0);
 add_alias("SUBDIR     ",8'h10,0,"SUBDIR",6,0);
 add_alias({8'h05,"ILE    TXT"},8'h20,0,{8'he5,"ILE.TXT"},8,0);
 add_long("Exactly13.TXT",13,"EXACTL~1TXT",0,0,0);
 add_long("mixed Case Long Name.TXT",24,"MIXEDC~1TXT",0,0,0);
 add_long("Unicode.TXT",11,"UNICOD~1TXT",5,0,0);
 for(k=1;k<=4;k=k+1)add_long("Rejected long name.TXT",22,"REJECT~1TXT",k,"REJECT~1.TXT",12);
 // Valid short name following a deleted LFN must not inherit its text.
 i=slot_address(slots);disk[i]=8'he5;disk[i+11]=8'h0f;slots=slots+1;
 add_alias("AFTER   WAV",8'h22,0,"AFTER.WAV",9,0);
 disk[slot_address(slots)]=0;
 for(i=0;i<=slots/16;i=i+1)
  put32(11*512+(2+2*i)*4,(i==slots/16)?32'h0fffffff:4+2*i);
 #40;@(negedge clk);rst=0;mount_start=1;@(negedge clk);mount_start=0;
 wait(mount_done);if(!mount_ok)$fatal(1,"mount rejected %0d",error_code);
 // Re-enumerate after idle to verify no stale character/read phase survives.
 for(rounds=0;rounds<2;rounds=rounds+1)begin
  seen=0;characters=0;entry_open=0;
  repeat(3)@(negedge clk);dir_start=1;@(negedge clk);dir_start=0;
  wait(dir_done);@(negedge clk);
  if(!dir_ok || seen!=expected || entry_open)$fatal(1,"directory completion seen=%0d expected=%0d",seen,expected);
 end
 $display("*** PASS *** directory metadata/SFN/VFAT255/fragmented cross-cluster/deleted/volume/Unicode/damaged LFN/re-enumeration (%0d entries twice)",expected);
 $finish;
end
always @(posedge clk)begin
 cycles<=cycles+1;blk_grant<=0;blk_data_valid<=0;blk_end<=0;
 if(blk_req && !reading)begin
  reading<=1;blk_grant<=1;read_base<=blk_lba*512;read_pos<=0;read_size<=blk_count*512;
 end else if(reading && cycles%5!=0)begin
  if(read_pos<read_size)begin blk_data<=disk[read_base+read_pos];blk_data_valid<=1;read_pos<=read_pos+1;end
  else begin reading<=0;blk_end<=1;end
 end
 if(!rst)begin
  if(entry_start)begin
   if(entry_open || seen>=expected)$fatal(1,"unexpected entry start");
   entry_open=1;characters=0;
   if(name_len!==expected_len[seen] || first_cluster!==expected_cluster[seen] ||
      file_bytes!==expected_size[seen] || attr!==expected_attr[seen] ||
      is_lfn!==expected_lfn[seen] || is_dir!==expected_attr[seen][4])
     $fatal(1,"metadata mismatch entry %0d len=%0d expected=%0d",seen,name_len,expected_len[seen]);
  end
  if(name_valid)begin
   if(!entry_open || name_index!=characters || characters>=expected_len[seen])$fatal(1,"character ordering");
   if(name_char!==expected_name[seen][(expected_len[seen]-1-characters)*8+:8])
     $fatal(1,"name mismatch entry %0d char %0d got=%h",seen,characters,name_char);
   characters=characters+1;
  end
  if(entry_end)begin
   if(!entry_open || characters!=expected_len[seen])$fatal(1,"entry end length");
   entry_open=0;seen=seen+1;
  end
 end
end
initial begin #3000000;$fatal(1,"directory timeout state=%0d seen=%0d",state,seen);end
endmodule
