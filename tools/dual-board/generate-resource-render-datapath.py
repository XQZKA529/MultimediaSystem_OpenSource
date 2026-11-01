from pathlib import Path
import re
from resource_experiment import snapshot
from resource_rom import rom

ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'build/resource-v1';BASE=OUT/'base/render'
def candidate(name):
    dest=OUT/name/'render'
    if not dest.exists():snapshot(BASE,dest)
    return dest

# Repad the exact AA font to 16x16 cells. Address concatenation replaces two
# 140*character / 10*row arithmetic networks; the valid mask remains unchanged.
old=(BASE/'rtl/ui/font_rom.v').read_text(encoding='utf-8-sig')
init=[int(v,16) for v in re.findall(r"\.INIT_[0-9A-F]+\(256'h([0-9a-f]+)\)",old)]
atlas=[]
for v in init:atlas.extend((v>>(16*j))&65535 for j in range(16))
words=[]
for code in range(128):
    for y in range(16):
        for half in range(2):
            value=0
            for j in range(8):
                x=half*8+j
                if 32<=code<=126 and x<10 and y<14:
                    pixel=(code-32)*140+y*10+x
                    value|=((atlas[pixel//8]>>((pixel%8)*2))&3)<<(2*j)
            words.append(value)
font='''// Exact original coverage, repadded to eliminate address multipliers/adders.
module font_rom #(parameter SECOND_PORT=0)(input wire clk,input wire [6:0] char_code,
 input wire [3:0] gx,gy,output wire [1:0] alpha,
 input wire [6:0] char_code_b,input wire [3:0] gx_b,gy_b,output wire [1:0] alpha_b);
 wire [15:0] qa,qb;reg [2:0] pa,pb;reg va,vb;
 always @(posedge clk) begin
  pa<=gx[2:0];pb<=gx_b[2:0];
  va<=char_code>=32 && char_code<=126 && gx<10 && gy<14;
  vb<=SECOND_PORT && char_code_b>=32 && char_code_b<=126 && gx_b<10 && gy_b<14;
 end
 resource_padded_font u_font(.clk(clk),.addr({char_code,gy,gx[3]}),
  .addr_b({char_code_b,gy_b,gx_b[3]}),.q(qa),.q_b(qb));
 assign alpha=va ? qa[{pa,1'b0} +: 2]:2'd0;
 assign alpha_b=vb ? qb[{pb,1'b0} +: 2]:2'd0;
endmodule
'''+rom('resource_padded_font',words,12)
(candidate('render_font_address')/'rtl/ui/font_rom.v').write_text(font,encoding='utf-8')

# Background glass and AA white have a finite, exact palette. Each channel has
# two synchronous ports, retaining both existing arithmetic pipeline stages.
words=[0]*2048
tints=[0,20,66,106,58,18,62]
for mode in range(7):
    for n in range(128):
        def bg(v):return v if mode==0 else ((3*v+20)//4 if mode==1 else (v+tints[mode])//2)
        words[mode*128+n]=bg(n*2)|(bg(n*2+1)<<8)
for alpha in range(4):
    for n in range(128):
        def white(v):return [v,(3*v+255)//4,(v+765)//4,255][alpha]
        words[1024+alpha*128+n]=white(n*2)|(white(n*2+1)<<8)
channel='''module resource_ui_channel(input wire clk,input wire [7:0] src,white_src,
 input wire [2:0] mode,input wire [1:0] alpha,output wire [7:0] background,white);
 wire [15:0] qa,qb;reg a_bit,b_bit;
 always @(posedge clk) begin a_bit<=src[0];b_bit<=white_src[0];end
 resource_ui_palette u_table(.clk(clk),.addr({1'b0,mode,src[7:1]}),
  .addr_b({2'b10,alpha,white_src[7:1]}),.q(qa),.q_b(qb));
 assign background=a_bit ? qa[15:8]:qa[7:0];assign white=b_bit ? qb[15:8]:qb[7:0];
endmodule
'''+rom('resource_ui_palette',words,11)
s=(BASE/'rtl/ui/ui_text_overlay.v').read_text(encoding='utf-8-sig')
a=s.index('    function [9:0] blend_sum;');b=s.index('    always @(posedge video_clk or posedge rst) begin',a)
s=s[:a]+'''    wire [7:0] br_3,bg_3,bb_3,cr_4,cg_4,cb_4;
    reg [2:0] palette_mode;
    always @(*) begin
        palette_mode=0;
        if(weight_2==3) palette_mode=1;
        else if(weight_2==2) case(tint_2)
            66:palette_mode=2;106:palette_mode=3;58:palette_mode=4;
            18:palette_mode=5;62:palette_mode=6;default:palette_mode=0;
        endcase
    end
    wire [1:0] white_alpha=solid_3 ? 2'd0:(text_3 ? coverage:2'd0);
    resource_ui_channel r_table(.clk(video_clk),.src(rgb_2[23:16]),.mode(palette_mode),
        .white_src(solid_3 ? tone_3:br_3),.alpha(white_alpha),.background(br_3),.white(cr_4));
    resource_ui_channel g_table(.clk(video_clk),.src(rgb_2[15:8]),.mode(palette_mode),
        .white_src(solid_3 ? tone_3:bg_3),.alpha(white_alpha),.background(bg_3),.white(cg_4));
    resource_ui_channel b_table(.clk(video_clk),.src(rgb_2[7:0]),.mode(palette_mode),
        .white_src(solid_3 ? tone_3:bb_3),.alpha(white_alpha),.background(bb_3),.white(cb_4));
    reg [1:0] palette_valid;
    always @(posedge video_clk or posedge rst)
        if(rst) palette_valid<=0;else palette_valid<={palette_valid[0],1'b1};
'''+s[b:]
s=s.replace('br_3<=0;bg_3<=0;bb_3<=0;cr_4<=0;cg_4<=0;cb_4<=0;','')
s=re.sub(r'            br_3<=blend_sum.*?;bb_3<=blend_sum.*?;\n','',s)
s=re.sub(r'            c[rg b]_4<=solid_3.*?;\n','',s)
# Explicit substitutions also cover the channel names without relying on regex.
s='\n'.join(l for l in s.splitlines() if not re.match(r'\s*c[rgb]_4<=solid_3',l))+'\n'
s=s.replace('pix_out<={cr_4[9:2],cg_4[9:2],cb_4[9:2]};',"pix_out<=palette_valid[1] ? {cr_4,cg_4,cb_4}:24'd0;")
(candidate('render_palette_rom')/'rtl/ui/ui_text_overlay.v').write_text(s+channel,encoding='utf-8')

# Formatting ROM occupies the original character register's stage. Production
# BCD values are frame-committed; the default keeps arbitrary standalone inputs.
words=[32]*2048
def digit(index):return 32768|index
date=[ord('2'),ord('0'),digit(0),digit(1),ord('-'),digit(2),digit(3),ord('-'),digit(4),digit(5)]
time=[digit(6),digit(7),ord(':'),digit(8),digit(9),ord(':'),digit(10),digit(11)]
for col,v in enumerate(date):words[col]=v
for col,v in enumerate(time):words[512+col]=v
labels=['CLOCK ','YEAR  ','MONTH ','DAY   ','HOUR  ','MINUTE','SECOND','APPLY ']
for row,label in enumerate(labels):
    for col,ch in enumerate(label,1):words[1024+row*32+col]=ord(ch)
    if row==1:
        words[1024+row*32+16]=ord('2');words[1024+row*32+17]=ord('0')
        words[1024+row*32+18]=digit(12);words[1024+row*32+19]=digit(13)
    elif 2<=row<=6:
        words[1024+row*32+16]=digit(12+(row-1)*2);words[1024+row*32+17]=digit(13+(row-1)*2)
help_line='2/8 MOVE 4/6 -/+ 5 APPLY # BACK '
for col,ch in enumerate(help_line):words[1024+8*32+col]=ord(ch)
s=(BASE/'rtl/ui/clock_overlay.v').read_text()
s=s.replace('module clock_overlay(', 'module clock_overlay #(parameter FRAME_DIGITS=0)(')
s=s.replace('    assign font_char=char_a;', '''    wire [15:0] character_descriptor;
    wire [1:0] character_kind=editor_text ? 2'd2:time_line ? 2'd1:2'd0;
    resource_clock_characters u_characters(.clk(clk),.addr({character_kind,row,col}),.addr_b(11'd0),.q(character_descriptor),.q_b());
    wire [95:0] calendar_digits={live_digits,draft_digits};
    wire [3:0] selected_digit=calendar_digits[95-{character_descriptor[4:0],2'b00} -: 4];
    wire [6:0] table_character=character_descriptor[15] ? 7'd48+selected_digit:character_descriptor[6:0];
    assign font_char=FRAME_DIGITS ? (request_a ? table_character:7'd32):char_a;''')
p=candidate('render_clock_format')/'rtl/ui/clock_overlay.v';p.write_text(s+rom('resource_clock_characters',words,11))
p=p.parent.parent/'render_core.v';s=p.read_text(encoding='utf-8-sig')
s=s.replace('clock_overlay u_clock_overlay','clock_overlay #(.FRAME_DIGITS(1)) u_clock_overlay')
p.write_text(s,encoding='utf-8')
