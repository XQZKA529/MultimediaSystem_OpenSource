"""Keep descriptor RAM ownership through TX; avoid another 96-bit snapshot.

Session, sequence, management kind and CRC remain held registers. Both MAC
mailbox timing and the descriptor-slot exclusion retain their original rules.
"""
from pathlib import Path
from resource_experiment import snapshot
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'build/resource-v1'
for board in ('media','render'):
    src=OUT/'rx_management'/board;dest=OUT/'tx_descriptor'/board
    if not dest.exists():snapshot(src,dest)
    p=dest/'rtl/link/db_link.v';s=(src/'rtl/link/db_link.v').read_text(encoding='utf-8-sig')
    s=s.replace('    reg [255:0] send_header;', '''    reg [63:0] header_session;
    reg [31:0] header_crc;
    reg send_hello;
    wire [255:0] send_header;''')
    s=s.replace('.adata({tx_object,tx_offset,tx_length,tx_channel,tx_opcode})', ".adata({tx_object,tx_offset,5'd0,tx_length[10:2],2'd0,6'd0,tx_channel[1:0],tx_opcode})")
    s=s.replace('.baddr(send_state==4 || send_state==5 ? send_slot:selected_slot)', '.baddr(send_state!=0 || mac_busy || mac_busy_clear ? send_slot:selected_slot)')
    pos=s.index('    wire eligible=')
    s=s[:pos]+'''    // A data slot cannot be rewritten while send_state holds it. Following
    // session cancellation mac_busy_clear excludes all new slot writers until
    // the old MAC transaction ends. Keep the RAM read address pinned as well.
    wire [95:0] management_fields=send_hello ?
        {ROLE[7:0],24'h000103,32'h04020205,16'd0,8'd0,`DB_HELLO}:
        {32'd0,32'd0,16'd0,send_channel,`DB_ACK};
    assign send_header={`DB_MAJOR,`DB_MINOR,(send_management ? 8'd0:8'd1),
        (send_management ? 8'd0:8'd1),header_session,send_seq,
        (send_management ? management_fields:header_ram_q),header_crc};
'''+s[pos:]
    s=s.replace('send_seq<=0;send_header<=0;', 'send_seq<=0;header_session<=0;header_crc<=0;send_hello<=0;')
    s=s.replace('send_header<=management_header;send_management<=1;', '''header_session<=session;header_crc<=0;send_hello<=hello_pending;
                        send_seq<=management_header[159:128];send_channel<=management_header[47:40];send_management<=1;''')
    s=s.replace('                        send_management<=0;', '                        send_management<=0;header_session<=session;header_crc<=0;')
    s=s.replace("5:begin send_header<={`DB_MAJOR,`DB_MINOR,8'd1,8'd1,session,send_seq,header_ram_q,32'd0};send_state<=1;end", '5:begin send_state<=1;end')
    s=s.replace('send_header[31:0]<=~crc_acc;', 'header_crc<=~crc_acc;')
    if 'send_header<=' in s or 'send_header[31:0]<=' in s:raise RuntimeError('Incomplete TX replacement')
    p.write_text(s,encoding='utf-8')

src=OUT/'render_goertzel/render';dest=OUT/'render_shared_multiplier/render'
if not dest.exists():snapshot(src,dest)
p=dest/'rtl/fft/audio_fft_osd.v';s=(src/'rtl/fft/audio_fft_osd.v').read_text(encoding='utf-8-sig')
marker='    wire signed [STW-1:0] p14 = prod_r[STW+13 : 14];'
shared='''    // Select operands before the multiply, not only its result register.
    // Window and recurrence phases are mutually exclusive; latency is unchanged.
    localparam integer MUL_AW=(STW>16) ? STW:16;
    wire signed [MUL_AW-1:0] multiply_a=(ph==P_IDLE) ? $signed(mono16):$signed(s1q);
    wire signed [15:0] multiply_b=(ph==P_IDLE) ? w_tri:coef_r;
    wire signed [MUL_AW+15:0] shared_product=multiply_a*multiply_b;
'''
s=s.replace(marker,shared+marker).replace('prod_r <= mono16 * w_tri;', 'prod_r <= shared_product;').replace('prod_r <= coef_r * s1q;', 'prod_r <= shared_product;')
p.write_text(s,encoding='utf-8')
