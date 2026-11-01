"""Stream the compact RX header into its owned RAM slot without wide shifts."""
from pathlib import Path
from resource_experiment import snapshot

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'build/resource-v1'
for board in ('media','render'):
    base=OUT/'base'/board;dest=OUT/'rx_stream'/board
    if not dest.exists():snapshot(base,dest)
    p=dest/'rtl/link/db_mac_rx.v';s=(base/'rtl/link/db_mac_rx.v').read_text(encoding='utf-8-sig')
    s=s.replace('    reg [223:0] header_store;', '''    reg header_write;
    reg [5:0] header_address;
    reg [31:0] header_word;
    reg [23:0] header_partial;
    reg dst_match,src_match,eth_match;
    reg [7:0] major,packet_type,channel,opcode,peer_role;
    reg [63:0] header_session;
    reg [31:0] header_sequence,received_crc;
    reg [15:0] length;
    reg capability_ok;
    // Complete words are written while their slot is exclusively owned by RX.
    // Publication still waits for length, link CRC and delayed MAC FCS checks.
    always @(posedge rx_clk or posedge rx_rst) begin
        if(rx_rst) begin header_write<=0;header_address<=0;header_word<=0;header_partial<=0;end
        else begin
            header_write<=0;
            if(active && rx_valid) begin
                if(count==14) header_partial[23:16]<=rx_data;
                if(count==17) header_partial[15:8]<=rx_data;
                if(count==18) header_partial[7:0]<=rx_data;
                if(count>=20 && count<40) header_partial<={header_partial[15:0],rx_data};
                if(!frame_discard) case(count)
                    19:begin header_write<=1;header_address<={wp[2:0],3'd0};header_word<={header_partial,rx_data};end
                    23:begin header_write<=1;header_address<={wp[2:0],3'd1};header_word<={header_partial,rx_data};end
                    27:begin header_write<=1;header_address<={wp[2:0],3'd2};header_word<={header_partial,rx_data};end
                    31:begin header_write<=1;header_address<={wp[2:0],3'd3};header_word<={header_partial,rx_data};end
                    35:begin header_write<=1;header_address<={wp[2:0],3'd4};header_word<={header_partial,rx_data};end
                    39:begin header_write<=1;header_address<={wp[2:0],3'd5};header_word<={header_partial,rx_data};end
                    41:begin header_write<=1;header_address<={wp[2:0],3'd6};header_word<={channel,rx_data,16'd0};end
                    default:header_write<=0;
                endcase
            end
        end
    end''')
    s=s.replace('.awe(header_busy),.aaddr({wp[2:0],header_wi})', '.awe(header_write),.aaddr(header_address)')
    s=s.replace('.adata(header_store[223:192])', '.adata(header_word)')
    s=s.replace('    reg [47:0] dst,src;\n    reg [15:0] eth;\n    reg [255:0] hdr;','')
    s=s.replace('    wire [15:0] length=hdr[63:48];','')
    s=s.replace('count<=0;dst<=0;src<=0;eth<=0;', 'count<=0;dst_match<=0;src_match<=0;eth_match<=0;')
    s=s.replace('hdr<=0;crc<=', 'major<=0;packet_type<=0;header_session<=0;header_sequence<=0;received_crc<=0;\n            length<=0;channel<=0;opcode<=0;peer_role<=0;capability_ok<=0;crc<=')
    s=s.replace('header_store<=0;', '')
    s=s.replace('                header_store<=header_store<<32;\n','')
    s=s.replace('count<=1;dst<={40\'d0,rx_data};src<=0;eth<=0;hdr<=0;', '''count<=1;dst_match<=rx_data==LOCAL_MAC[47:40];src_match<=1;eth_match<=1;
                    major<=0;packet_type<=0;header_session<=0;header_sequence<=0;received_crc<=0;
                    length<=0;channel<=0;opcode<=0;peer_role<=0;capability_ok<=1;''')
    s=s.replace('''                    if(count<6) dst<={dst[39:0],rx_data};
                    else if(count<12) src<={src[39:0],rx_data};
                    else if(count<14) eth<={eth[7:0],rx_data};
                    else if(count<46) hdr<={hdr[247:0],rx_data};''', '''                    if(count<6) dst_match<=dst_match && rx_data==LOCAL_MAC[47-(count[2:0]*8) -: 8];
                    else if(count<12) src_match<=src_match && rx_data==PEER_MAC[47-((count-12'd6)*8) -: 8];
                    else if(count==12) eth_match<=rx_data==`DB_ETHERTYPE[15:8];
                    else if(count==13) eth_match<=eth_match && rx_data==`DB_ETHERTYPE[7:0];
                    if(count==14) major<=rx_data;
                    if(count==16) packet_type<=rx_data;
                    if(count>=18 && count<26) header_session<={header_session[55:0],rx_data};
                    if(count>=26 && count<30) header_sequence<={header_sequence[23:0],rx_data};
                    if(count==30) peer_role<=rx_data;
                    if(count>=31 && count<38) case(count)
                        31:capability_ok<=capability_ok && rx_data==0;
                        32:capability_ok<=capability_ok && rx_data==1;
                        33:capability_ok<=capability_ok && rx_data==3;
                        34:capability_ok<=capability_ok && rx_data==4;
                        35,36:capability_ok<=capability_ok && rx_data==2;
                        37:capability_ok<=capability_ok && rx_data==5;
                    endcase
                    if(count==38) length[15:8]<=rx_data;
                    if(count==39) length[7:0]<=rx_data;
                    if(count==40) channel<=rx_data;
                    if(count==41) opcode<=rx_data;
                    if(count>=42 && count<46) received_crc<={received_crc[23:0],rx_data};''')
    # A constant expression macro cannot be indexed directly in Verilog-2001.
    s=s.replace('    `include "db_crc.vh"','    `include "db_crc.vh"\n    localparam [15:0] ETHERTYPE=`DB_ETHERTYPE;')
    s=s.replace('`DB_ETHERTYPE[','ETHERTYPE[')
    s=s.replace("hdr[55:40]<=1024 ? 11'd46+hdr[50:40]", "length<=1024 ? 11'd46+length[10:0]")
    s=s.replace('dst==LOCAL_MAC && src==PEER_MAC && eth==`DB_ETHERTYPE', 'dst_match && src_match && eth_match')
    s=s.replace('(~crc)==hdr[31:0]', '(~crc)==received_crc')
    s=s.replace("hdr[239:232]==0 && length==0 && hdr[255:248]==`DB_MAJOR", "packet_type==0 && length==0 && major==`DB_MAJOR")
    s=s.replace('''mg_data<={hdr[223:160],hdr[159:128],hdr[47:40],hdr[39:32],hdr[127:120],7'd0,
                                (hdr[119:96]==24'h000103 && hdr[95:64]==32'h04020205)}''', "mg_data<={header_session,header_sequence,channel,opcode,peer_role,7'd0,capability_ok}")
    s=s.replace('hdr[239:232]==1', 'packet_type==1')
    s=s.replace("header_store<={hdr[255:248],hdr[231:224],hdr[223:32],16'd0};", '')
    import re
    code=re.sub(r'//[^\n]*','',s)
    start=s.index('    // Complete words are written')
    end=s.index('    reg header_busy;',start)
    writer=s[start:end];s=s[:start]+s[end:]
    s=s.replace('    // Register the completed word',writer+'    // Register the completed word')
    if 'hdr[' in code or 'header_store' in code or 'dst<=' in code:raise RuntimeError('Incomplete header replacement')
    p.write_text(s,encoding='utf-8')
