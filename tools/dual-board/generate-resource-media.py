"""Independent media candidates; preserve protocol widths and pending requests."""
from pathlib import Path
import re
from resource_experiment import snapshot

ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'build/resource-v1';BASE=OUT/'base/media'

def candidate(name):
    dest=OUT/name/'media'
    if not dest.exists():snapshot(BASE,dest)
    return dest

fat=(BASE/'rtl/fat/fat32_ro.v').read_text(encoding='utf-8-sig')

# Directory operations own the existing sector BRAM until parsing completes.
# Fetch metadata and name bytes from that RAM instead of copying 32 bytes to FFs.
s=fat
start=s.index('// Directory entries arrive');end=s.index('reg [4:0] entry_load_count;',start)
s=s[:start]+'''// Directory parsing retains ownership of sector_buf for the entire entry.
// Only metadata needed concurrently is captured; names use its synchronous port.
reg [7:0] entry_first,entry_attr,entry_ntres,entry_checksum,lfn_low;
reg [31:0] entry_cluster,entry_size;
reg entry_ext_nonblank;
localparam S_LFN_WAIT1=8'd64,S_LFN_WAIT2=8'd65,S_LFN_WAIT3=8'd66,S_LFN_WAIT4=8'd67,
           S_CSUM_WAIT1=8'd68,S_CSUM_WAIT2=8'd69,S_BUILD_WAIT1=8'd70,S_BUILD_WAIT2=8'd71;
'''+s[end:]
s=s.replace('reg entry_write;','').replace('if(entry_write) entry_shift<={sector_q,entry_shift[255:8]};','')
s=s.replace('entry_write<=0;','').replace('        entry_write<=state_hot[S_DIR_LOAD_WAIT] || (state_hot[S_DIR_LOAD] && entry_load_count!=31);','')
for name in ['entry_le16','entry_le32','entry_lfn_char','entry_sfn_char']:
    s=re.sub(r'function \[[^\]]+\] '+name+r';.*?endfunction\n','',s,flags=re.S)
offset='''function [4:0] lfn_offset;
 input [3:0] n;
 begin case(n)
  0:lfn_offset=1;1:lfn_offset=3;2:lfn_offset=5;3:lfn_offset=7;4:lfn_offset=9;
  5:lfn_offset=14;6:lfn_offset=16;7:lfn_offset=18;8:lfn_offset=20;9:lfn_offset=22;
  10:lfn_offset=24;11:lfn_offset=28;default:lfn_offset=30;
 endcase end
endfunction
'''
s=s.replace('function [7:0] spc_to_shift;',offset+'function [7:0] spc_to_shift;')
a=s.index('      state_hot[S_DIR_ENTRY]: begin');b=s.index('      state_hot[S_DIR_DECODE]: begin',a)
s=s[:a]+'''      state_hot[S_DIR_ENTRY]: begin
        sector_addr<=entry_off;entry_load_count<=0;entry_ext_nonblank<=0;
        state_hot<=72'b1<<S_DIR_LOAD_WAIT;
      end
      state_hot[S_DIR_LOAD_WAIT]: begin state_hot<=72'b1<<S_DIR_LOAD;end
      state_hot[S_DIR_LOAD]: begin
        case(entry_load_count)
          0:entry_first<=sector_q;11:entry_attr<=sector_q;
          12:entry_ntres<=sector_q;13:entry_checksum<=sector_q;
          8,9,10:entry_ext_nonblank<=entry_ext_nonblank || sector_q!=8'h20;
          20:entry_cluster[23:16]<=sector_q;21:entry_cluster[31:24]<=sector_q;
          26:entry_cluster[7:0]<=sector_q;27:entry_cluster[15:8]<=sector_q;
          28:entry_size[7:0]<=sector_q;29:entry_size[15:8]<=sector_q;
          30:entry_size[23:16]<=sector_q;31:entry_size[31:24]<=sector_q;
        endcase
        if(entry_load_count==31) state_hot<=72'b1<<S_DIR_DECODE;
        else begin entry_load_count<=entry_load_count+1'b1;sector_addr<=sector_addr+1'b1;
          state_hot<=72'b1<<S_DIR_LOAD_WAIT;end
      end
'''+s[b:]
s=s.replace('entry_le16(26)','entry_cluster[15:0]').replace('entry_le32(28)','entry_size')
s=s.replace('{entry_buf[21],entry_buf[20],entry_buf[27],entry_buf[26]}','entry_cluster')
s=s.replace("((entry_buf[8]!=8'h20)||(entry_buf[9]!=8'h20)||(entry_buf[10]!=8'h20))",'entry_ext_nonblank')
a=s.index('      state_hot[S_LFN_CHAR]: begin');b=s.index('      state_hot[S_LFN_WRITE]: begin',a)
s=s[:a]+'''      state_hot[S_LFN_CHAR]: begin
        sector_addr<=entry_off+{4'd0,lfn_offset(lfn_char_no)};
        lfn_write_index<=lfn_base+lfn_char_no;state_hot<=72'b1<<S_LFN_WAIT1;
      end
      state_hot[S_LFN_WAIT1]:state_hot<=72'b1<<S_LFN_WAIT2;
      state_hot[S_LFN_WAIT2]:begin lfn_low<=sector_q;sector_addr<=sector_addr+1'b1;state_hot<=72'b1<<S_LFN_WAIT3;end
      state_hot[S_LFN_WAIT3]:state_hot<=72'b1<<S_LFN_WAIT4;
      state_hot[S_LFN_WAIT4]:begin lfn_char_value<={sector_q,lfn_low};state_hot<=72'b1<<S_LFN_WRITE;end
'''+s[b:]
a=s.index('      state_hot[S_SFN_CSUM]: begin');b=s.index('      state_hot[S_SFN_CSUM_EVAL]: begin',a)
s=s[:a]+'''      state_hot[S_SFN_CSUM]: begin
        sector_addr<=entry_off+{5'd0,sfn_pos};state_hot<=72'b1<<S_CSUM_WAIT1;
      end
      state_hot[S_CSUM_WAIT1]:state_hot<=72'b1<<S_CSUM_WAIT2;
      state_hot[S_CSUM_WAIT2]:begin
        sfn_checksum<={sfn_checksum[0],sfn_checksum[7:1]}+sector_q;
        if(sfn_pos==10) state_hot<=72'b1<<S_SFN_CSUM_EVAL;
        else begin sfn_pos<=sfn_pos+1'b1;state_hot<=72'b1<<S_SFN_CSUM;end
      end
'''+s[b:]
a=s.index('      state_hot[S_SFN_BUILD]: begin');b=s.index('      state_hot[S_SFN_PREP]: begin',a)
s=s[:a]+'''      state_hot[S_SFN_BUILD]: begin
        if(sfn_pos==8) begin
          sfn_raw_char<=8'h2e;sfn_build_lower<=0;sfn_build_extmark<=1;
          sfn_build_last<=0;sfn_next_pos<=9;state_hot<=72'b1<<S_SFN_PREP;
        end else begin
          sector_addr<=entry_off+{5'd0,sfn_pos}-(sfn_pos>8 ? 9'd1:9'd0);
          sfn_build_lower<=sfn_pos<8 ? sfn_ntres[3]:sfn_ntres[4];
          sfn_build_extmark<=0;sfn_build_last<=sfn_pos==11;sfn_next_pos<=sfn_pos+1'b1;
          state_hot<=72'b1<<S_BUILD_WAIT1;
        end
      end
      state_hot[S_BUILD_WAIT1]:state_hot<=72'b1<<S_BUILD_WAIT2;
      state_hot[S_BUILD_WAIT2]:begin sfn_raw_char<=sector_q;state_hot<=72'b1<<S_SFN_PREP;end
'''+s[b:]
for index,name in [(0,'entry_first'),(11,'entry_attr'),(12,'entry_ntres'),(13,'entry_checksum')]:s=s.replace(f'entry_buf[{index}]',name)
s=s.replace('reg [63:0] state_hot,rd_return_hot;','reg [71:0] state_hot,rd_return_hot;').replace("64'b1","72'b1")
s=s.replace('state_number<64','state_number<72')
if any(x in s for x in ['entry_buf[','entry_shift','entry_sfn_char(','entry_lfn_char(']):raise RuntimeError('Incomplete directory replacement')
(candidate('media_directory')/'rtl/fat/fat32_ro.v').write_text(s,encoding='utf-8')

# Independent encoding experiment, no state sequencing or precedence changes.
s=fat
a=s.index('reg [63:0] state_hot');b=s.index('reg [1:0] active_op;',a)
s=s[:a]+"reg [5:0] state_encoded,rd_return_encoded;\nwire [7:0] state={2'd0,state_encoded};\n\n"+s[b:]
s=re.sub(r"\(?64'b1\s*<<\s*(S_\w+)\)?",r'\1',s)
s=s.replace("64'b1<<ret",'ret[5:0]')
s=re.sub(r'state_hot\[(S_\w+)\](\s*:)',r'\1\2',s)
s=re.sub(r'state_hot\[(S_\w+)\]',r'(state_encoded==\1)',s)
s=s.replace('case (1\'b1)','case (state_encoded)').replace("case(1'b1)",'case(state_encoded)')
s=s.replace('rd_return_hot','rd_return_encoded').replace('state_hot','state_encoded')
(candidate('media_fat_encoding')/'rtl/fat/fat32_ro.v').write_text(s,encoding='utf-8')

# BMP header lane is an index of the 54 header bytes; 54 is a sticky terminal.
s=(BASE/'rtl/image/bmp_header_parser.v').read_text()
s=s.replace('reg [53:0] lane;','reg [5:0] lane;').replace("lane<=54'd1","lane<=6'd0")
s=re.sub(r'lane\[(\d+)\]',r"(lane==6'd\1)",s)
s=s.replace("lane<={lane[52:0],1'b0};", "if(lane<54) lane<=lane+1'b1;")
(candidate('media_header_index')/'rtl/image/bmp_header_parser.v').write_text(s)

# Setup-only product sharing; capture the second operands on the start edge.
s=(BASE/'rtl/image/image_scale_geometry.v').read_text()
s=s.replace('    reg wide;','''    reg wide;
    reg [12:0] second_src;reg [15:0] second_dst;
    wire [12:0] mul_src=start ? src_w:second_src;
    wire [15:0] mul_dst=start ? dst_h:second_dst;
    wire [28:0] product=mul_src*mul_dst;''')
s=s.replace('cross_w<=src_w*dst_h;cross_h<=src_h*dst_w;state<=1;', 'cross_w<=product;second_src<=src_h;second_dst<=dst_w;state<=1;')
s=re.sub(r'(?m)^(\s*)([1-6]):',lambda m:m[1]+str(int(m[2])+1)+':',s)
s=re.sub(r'state<=([2-6]);',lambda m:'state<='+str(int(m[1])+1)+';',s)
s=s.replace('        end else case(state)','        end else case(state)\n            1:begin cross_h<=product;state<=2;end')
(candidate('media_geometry_tdm')/'rtl/image/image_scale_geometry.v').write_text(s)
