`include "../pkg/board_link.vh"
// Reliable L2 endpoint. Local interface: a stable metadata handshake followed
// by exactly length/4 words. An ACK frees retained storage only after delivery.
// Fixed per-channel grants: control 2, PCM 2, image 4 x 1024-byte packets.
module db_link #(
    parameter integer ROLE=1,
    parameter integer CLK_HZ=100_000_000,
    // HELLO keepalive every 20ms (CLK_HZ/50); peer timeout 100ms (CLK_HZ/10),
    // per protocol-v1. Timeout is 5x the keepalive period. Do NOT shrink this
    // below the keepalive period or the session rebuilds every cycle.
    parameter integer HEARTBEAT_CYCLES=CLK_HZ/50,
    parameter integer TIMEOUT_CYCLES=CLK_HZ/10,
    parameter integer RETRY_CYCLES=CLK_HZ/200,
    parameter [47:0] LOCAL_MAC=`DB_MAC_MEDIA,
    parameter [47:0] PEER_MAC=`DB_MAC_RENDER
)(
    input wire clk,input wire rst,input wire phy_ok,
    output reg link_up,output reg session_reset,
    input wire tx_meta_valid,output wire tx_meta_ready,
    input wire [7:0] tx_channel,tx_opcode,input wire [31:0] tx_object,tx_offset,
    input wire [15:0] tx_length,input wire tx_valid,output wire tx_ready,
    input wire [31:0] tx_data,input wire tx_last,
    output wire rx_meta_valid,input wire rx_meta_ready,
    output wire rx_required,
    output wire [7:0] rx_channel,rx_opcode,output wire [31:0] rx_object,rx_offset,
    output wire [15:0] rx_length,output wire rx_valid,input wire rx_ready,
    output wire [31:0] rx_data,output wire rx_last,
    input wire mac_tx_clk,output wire [7:0] mac_tx_data,
    output wire mac_tx_valid,input wire mac_tx_ack,
    input wire mac_rx_clk,input wire [7:0] mac_rx_data,
    input wire mac_rx_valid,mac_rx_good,mac_rx_bad,
    output reg [31:0] retry_count,output wire [31:0] crc_errors,rx_drops,
    output reg retry_seen,output wire error_seen,drop_seen
);
    `include "db_crc.vh"
    reg [23:0] boot_counter=24'd1;
    always @(posedge clk) boot_counter<=boot_counter+1'b1;
    reg [55:0] session_nonce;
    reg session_nonce_ready; // Captured atomically with the nonce, not a wide TX enable path.
    wire [63:0] session={ROLE[7:0],session_nonce};
    reg [63:0] peer_session;
    reg [7:0] occupied,sent;
    // A slot retains only the low byte. Its distance from next_seq is <= window
    // (4), so modulo comparisons are unambiguous; wire sequences remain 32-bit.
    reg [7:0] slot_seq[0:7];
    function [7:0] slot_channel;
        input [2:0] slot;
        begin slot_channel=slot<4 ? 2:slot<6 ? 1:0;end
    endfunction
    // Signed modulo ordering without an 8-bit subtract/carry chain. The
    // serial-number distance between live slots stays within half the range.
    function seq_before;
        input [7:0] a;
        input [7:0] b;
        begin
            seq_before = (a[7] != b[7]) ? a[7] : (a[6:0] < b[6:0]);
        end
    endfunction
    wire [31:0] next_seq[0:2],expect_seq[0:2];
    localparam AGE_BITS=$clog2(2*RETRY_CYCLES+1);
    reg [AGE_BITS-1:0] retry_clock;
    reg [7:0] expired;
    reg ack_busy;
    reg [2:0] ack_slot;
    reg [7:0] ack_ch;
    reg [31:0] ack_seq;
    reg ack_release;
    reg [1:0] retries[0:7];
    reg collecting;
    reg [2:0] send_state;
    reg [2:0] send_slot;
    reg [2:0] fill_slot;
    reg [8:0] fill_word,fill_count;
    // Half-rate retry clock: 25000 ticks of a 2-cycle divider give the same
    // 1 ms timeout while keeping the age counter 16 bits wide, which is the
    // width that places cleanly on this device.
    reg retry_phase;
    reg [2:0] free_slot;
    reg free_found;
    integer find_i;
    always @* begin
        case(tx_channel)
            2:free_slot={1'b0,next_seq[2][1:0]};
            1:free_slot={2'b10,next_seq[1][0]};
            default:free_slot={2'b11,next_seq[0][0]};
        endcase
        free_found=tx_channel<=2 && !occupied[free_slot] && !(send_state!=0 && free_slot==send_slot);
    end
    reg req_toggle;
    reg mac_busy_clear,mac_done;
    (* async_reg="true" *) reg done1,done2;
    wire mac_busy=(req_toggle!=done2);
    assign tx_meta_ready=link_up && !collecting && free_found && !mac_busy_clear &&
                         tx_length<=1024 && tx_length[1:0]==0;
    assign tx_ready=collecting && link_up && send_state!=1 && send_state!=6 && send_state!=7;
    wire [31:0] crc_q;
    reg [10:0] crc_address;
    wire bus_write=tx_valid && tx_ready;
    // Stage the accepted word beside the packet BRAM. Its slot becomes
    // eligible after collection; arbitration and the header CRC precede any
    // payload read. Thus the final staged write retires before transmission.
    // CRC owns the A port in states 1/6/7 and blocks fresh word acceptance;
    // a preceding staged write can overlap only the header portion of CRC.
    reg packet_write;
    reg [10:0] packet_address;
    reg [31:0] packet_data;
    always @(posedge clk or posedge rst) begin
        if(rst) begin packet_write<=0;packet_address<=0;packet_data<=0;end
        else begin
            packet_write<=bus_write;
            if(bus_write) begin packet_address<={fill_slot,fill_word[7:0]};packet_data<=tx_data;end
        end
    end
    wire [10:0] bus_address=packet_write ? packet_address:crc_address;
    wire [31:0] tx_ram_q;
    wire [10:0] mac_ram_address;
    db_packet_ram u_packet_ram(.aclk(clk),.awe(packet_write),.aaddr(bus_address),.adata(packet_data),.aq(crc_q),
        .bclk(mac_tx_clk),.baddr(mac_ram_address),.bq(tx_ram_q));
    wire p_valid,p_ready,p_dv,p_dr,p_last,m_valid;
    wire [255:0] p_hdr;
    wire [127:0] m_hdr;
    // The management descriptor stays owned until classification completes.
    // Register 64-bit session and 32-bit ACK comparisons before fanout to
    // transaction resets/counters; FIFO ready advances only on the next cycle.
    reg m_prepared,m_checked,m_hello,m_current,m_change,m_ack_valid;
    reg [31:0] management_next_seq;
    wire m_ready=m_checked && !ack_busy;
    wire hello_accept=m_valid && m_ready && m_hello && phy_ok;
    // Only a HELLO that actually changes the peer session tears the session
    // down. While link_up is already set and the peer keeps the same session,
    // a keepalive HELLO must NOT trigger session_reset (that rebuild loop is
    // what made LINK DOWN/WAIT DATA flicker). A missing slot means the peer
    // re-handshaked, so peer_session differs and m_change forces the re-init.
    wire peer_change=hello_accept && (!link_up || m_change);
    always @(posedge clk or posedge rst) begin
        if(rst) begin m_prepared<=0;m_checked<=0;m_hello<=0;m_current<=0;m_change<=0;m_ack_valid<=0;management_next_seq<=0;end
        else if(!m_valid || m_ready) begin m_prepared<=0;m_checked<=0;end
        // The descriptor remains held across both classification stages.
        // Select the channel's sequence before the signed 32-bit comparison.
        else if(!m_prepared) begin
            m_prepared<=1;
            management_next_seq<=m_hdr[31:24]<=2 ? next_seq[m_hdr[31:24]]:32'd0;
        end
        else if(!m_checked) begin
            m_checked<=1;
            m_hello<=m_hdr[23:16]==`DB_HELLO && m_hdr[15:8]!=ROLE[7:0] &&
                (m_hdr[15:8]==1 || m_hdr[15:8]==2) && m_hdr[0];
            m_current<=m_hdr[127:64]==peer_session;
            // Compare against the session id actually held in hardware, not the
            // registered copy: peer_session updates on the same edge a change is
            // applied, so using the next value keeps this decisive and avoids a
            // spurious second reset.
            m_change<=m_hdr[127:64]!=peer_session;
            m_ack_valid<=m_hdr[23:16]==`DB_ACK && m_hdr[31:24]<=2 &&
                $signed(m_hdr[63:32]-management_next_seq)<=0;
        end
    end
    wire [31:0] p_data;
    db_mac_rx #(.LOCAL_MAC(LOCAL_MAC),.PEER_MAC(PEER_MAC)) u_receive(
        .rst(rst),.rx_clk(mac_rx_clk),.rx_data(mac_rx_data),.rx_valid(mac_rx_valid),
        .rx_good(mac_rx_good),.rx_bad(mac_rx_bad),.bus_clk(clk),
        .pkt_valid(p_valid),.pkt_header(p_hdr),.pkt_ready(p_ready),
        .data_valid(p_dv),.data(p_data),.data_ready(p_dr),.data_last(p_last),
        .mgmt_valid(m_valid),.mgmt_header(m_hdr),.mgmt_ready(m_ready),
        .crc_errors(crc_errors),.rx_drops(rx_drops),.error_seen(error_seen),.drop_seen(drop_seen));
    wire [7:0] p_ch=p_hdr[47:40];
    wire p_current=link_up && p_hdr[255:248]==`DB_MAJOR &&
                   p_hdr[223:160]==peer_session && p_ch<=2;
    wire p_order=p_current && p_hdr[159:128]==expect_seq[p_ch];
    reg checked,current_r,order_r;
    always @(posedge clk or posedge rst) begin
        if(rst) begin checked<=0;current_r<=0;order_r<=0;end
        else if(session_reset || !link_up || !p_valid) checked<=0;
        else if(!checked) begin checked<=1;current_r<=p_current;order_r<=p_order;end
        else if(p_ready) checked<=0;
    end
    reg delivering,discarding;
    reg [7:0] delivery_ch;
    reg [31:0] delivery_next_seq;
    // Capture handshake events before sequence/ACK/timer updates. Business
    // readiness can include FIFO credits and offset checks; it must not feed
    // those update muxes in the same cycle. RX descriptor fetch takes >14 cycles
    // between packets, so the sequence is advanced before the next order check.
    reg receive_ack,receive_advance,receive_alive;
    assign rx_meta_valid=p_valid && checked && order_r && !delivering && !discarding;
    assign p_ready=p_valid && checked && !delivering && !discarding && (!order_r || rx_meta_ready);
    assign rx_channel=p_ch;assign rx_opcode=p_hdr[39:32];
    assign rx_required=p_hdr[224];
    assign rx_object=p_hdr[127:96];assign rx_offset=p_hdr[95:64];
    assign rx_length=p_hdr[63:48];
    assign rx_valid=p_dv && delivering;
    assign rx_data=p_data;assign rx_last=p_last;
    assign p_dr=discarding || (delivering && rx_ready);
    reg [2:0] ack_pending;
    reg hello_pending;
    reg [$clog2(HEARTBEAT_CYCLES+1)-1:0] hb_age;
    reg [$clog2(TIMEOUT_CYCLES+1)-1:0] peer_age;
    reg peer_expired;
    reg [31:0] send_seq;
    // Capture the selected sequence before reconstructing its high bytes.
    // State 4 is an existing header preparation cycle before CRC starts.
    reg [23:0] send_seq_high;
    reg [7:0] send_seq_low;
    reg send_seq_borrow;
    reg [63:0] header_session;
    reg [31:0] header_crc;
    reg send_hello;
    wire [255:0] send_header;
    reg send_management;
    // Keep each retry counter's writeback local to its slot. A variable-index
    // read/modify/write creates a cross-slot feedback mux on this 16-bit bank.
    genvar retry_slot;
    generate for(retry_slot=0;retry_slot<8;retry_slot=retry_slot+1)begin:g_retry_counter
        wire retry_send=send_state==2 && !send_management && send_slot==retry_slot &&
                        occupied[retry_slot] && sent[retry_slot];
        wire retry_new=tx_meta_valid && tx_meta_ready && free_slot==retry_slot;
        always @(posedge clk or posedge rst) begin
            if(rst) retries[retry_slot]<=0;
            else if(retry_new) retries[retry_slot]<=0;
            else if(retry_send && retries[retry_slot]!=3)
                retries[retry_slot]<=retries[retry_slot]+1'b1;
        end
    end endgenerate
    reg [7:0] send_channel;
    reg [10:0] crc_byte_index;
    reg [31:0] crc_acc;
    reg [7:0] crc_byte_r;
    reg [2:0] selected_slot,scan_slot;
    reg selected_valid;
    reg selected_exhausted;
    reg [7:0] selected_seq;
    reg [7:0] selected_channel;
    reg arb_ready;
    wire [95:0] header_ram_q;
    // 2026-10-30：描述符 RAM 的读出口再打一拍（header_q），send_header 一律用
    // 寄存后的副本。原因：布线后 66 个 setup 违例端点的最差路径全部是
    // "u_descriptors/u_ram.clkb -> crc_address/m_ack_valid/send_state 的 CE"，
    // Data Path 15.78 ns 里 net 占 10.13 ns（fanout 只有 8）——BRAM 与消费者被
    // 摆到芯片两端，组合锥无法收敛。打一拍后该锥变成 "BRAM->FF 单跳" +
    // "FF->逻辑"，FF 可随消费者摆放。
    // 周期影响：无。状态 0->4->5->1 中，状态 4 本来就是选槽后的准备拍，在此拍
    // 采样时 BRAM 输出已是本槽数据；管理包（0->1）走 management_fields 分支，
    // 不使用 header_q。header_q 只在进入状态 4 时更新，发送期间（状态 1/6/2/3
    // 与 mac_busy 期间）保持不变，MAC 侧 tx_hdr 的"保持到整帧完成"前提不变。
    reg [95:0] header_q;
    db_packet_ram #(.AW(3),.DW(96)) u_descriptors(
        .aclk(clk),.awe(tx_meta_valid && tx_meta_ready),.aaddr(free_slot),
        .adata({tx_object,tx_offset,5'd0,tx_length[10:2],2'd0,6'd0,tx_channel[1:0],tx_opcode}),.aq(),.bclk(clk),
        .baddr(send_state!=0 || mac_busy || mac_busy_clear ? send_slot:selected_slot),.bq(header_ram_q));
    // A data slot cannot be rewritten while send_state holds it. Following
    // session cancellation mac_busy_clear excludes all new slot writers until
    // the old MAC transaction ends. Keep the RAM read address pinned as well.
    wire [95:0] management_fields=send_hello ?
        {ROLE[7:0],24'h000103,32'h04020205,16'd0,8'd0,`DB_HELLO}:
        {32'd0,32'd0,16'd0,send_channel,`DB_ACK};
    assign send_header={`DB_MAJOR,`DB_MINOR,(send_management ? 8'd0:8'd1),
        (send_management ? 8'd0:8'd1),header_session,send_seq,
        (send_management ? management_fields:header_q),header_crc};
    wire eligible=occupied[scan_slot] && (!sent[scan_slot] || expired[scan_slot]);
    wire [AGE_BITS-1:0] stamp_q;
    wire stamp_write=send_state==2 && !send_management && occupied[send_slot];
    reg [2:0] stamp_slot,stamp_previous_slot;
    reg stamp_previous_write;
    reg age_expired;
    reg [2:0] age_slot;
    db_packet_ram #(.AW(3),.DW(AGE_BITS)) u_timestamps(
        .aclk(clk),.awe(stamp_write),.aaddr(send_slot),.adata(retry_clock),.aq(),
        .bclk(clk),.baddr(scan_slot),.bq(stamp_q));
    // One-cycle synchronous read matches stamp_slot. Suppress read/write
    // collision results; the eight-cycle scan revisits the fresh timestamp.
    wire [AGE_BITS-1:0] elapsed=retry_clock-stamp_q;
    // Eight registered comparisons replace a long combinational arbitration chain.
    always @(posedge clk or posedge rst) begin
        if(rst) begin selected_slot<=0;selected_valid<=0;selected_exhausted<=0;selected_seq<=0;selected_channel<=0;scan_slot<=0;arb_ready<=0;end
        else begin
            arb_ready<=scan_slot==7;scan_slot<=scan_slot+1'b1;
            if(scan_slot==0) selected_valid<=eligible;
            if(eligible && (scan_slot==0 || !selected_valid || slot_channel(scan_slot)<selected_channel ||
                (slot_channel(scan_slot)==selected_channel && seq_before(slot_seq[scan_slot],selected_seq)))) begin
                selected_valid<=1;selected_slot<=scan_slot;selected_channel<=slot_channel(scan_slot);
                selected_seq<=slot_seq[scan_slot];
                selected_exhausted<=sent[scan_slot] && retries[scan_slot]==3;
            end
        end
    end
    wire [7:0] crc_byte=crc_byte_index<28 ?
        send_header[255-{crc_byte_index[4:0],3'b000} -: 8] :
        crc_q[31-{crc_byte_index[1:0],3'b000} -: 8];
    integer i;
    reg [255:0] management_header;
    reg [7:0] ack_channel;
    always @* begin
        ack_channel=ack_pending[0] ? 0 : ack_pending[1] ? 1 : 2;
        management_header={`DB_MAJOR,`DB_MINOR,8'd0,8'd0,session,
            32'd0,32'd0,32'd0,16'd0,8'd0,`DB_HELLO,32'd0};
        if(hello_pending) begin
            management_header[127:96]={ROLE[7:0],24'h000103};
            management_header[95:64]=32'h04020205; // windows, PHY 1000/full
        end else begin
            management_header[39:32]=`DB_ACK;
            management_header[47:40]=ack_channel;
            management_header[159:128]=expect_seq[ack_channel];
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            link_up<=0;session_reset<=1;session_nonce<=0;session_nonce_ready<=0;peer_session<=0;
            occupied<=0;sent<=0;collecting<=0;fill_slot<=0;fill_word<=0;fill_count<=0;
            delivering<=0;discarding<=0;delivery_ch<=0;delivery_next_seq<=0;
            receive_ack<=0;receive_advance<=0;receive_alive<=0;
            ack_pending<=0;hello_pending<=1;hb_age<=0;peer_age<=0;peer_expired<=TIMEOUT_CYCLES==0;
            req_toggle<=0;done1<=0;done2<=0;mac_busy_clear<=0;
            send_state<=0;send_slot<=0;send_seq<=0;header_session<=0;header_crc<=0;send_hello<=0;send_management<=0;send_channel<=0;
            crc_byte_index<=0;crc_acc<=32'hffffffff;crc_address<=0;crc_byte_r<=0;
            header_q<=0;
            retry_count<=0;retry_seen<=0;
            retry_clock<=0;expired<=0;retry_phase<=0;ack_busy<=0;ack_slot<=0;ack_ch<=0;ack_seq<=0;ack_release<=0;
            stamp_slot<=0;stamp_previous_slot<=0;stamp_previous_write<=0;
            age_expired<=0;age_slot<=0;
            for(i=0;i<8;i=i+1) slot_seq[i]<=0;
            
        end else begin
            session_reset<=0;done1<=mac_done;done2<=done1;
            if(mac_busy_clear && !mac_busy) mac_busy_clear<=0;
            if(!session_nonce_ready) begin session_nonce<=boot_counter;session_nonce_ready<=boot_counter!=0;end
            receive_ack<=0;receive_advance<=0;receive_alive<=0;
            if(hb_age>=HEARTBEAT_CYCLES) begin hb_age<=0;hello_pending<=1;end
            else hb_age<=hb_age+1'b1;
            if(peer_age<TIMEOUT_CYCLES) begin
                peer_age<=peer_age+1'b1;peer_expired<=peer_age>=TIMEOUT_CYCLES-1;
            end
            if(receive_alive && !session_reset) begin peer_age<=0;peer_expired<=TIMEOUT_CYCLES==0;end
            
            retry_phase<=~retry_phase;
            if(retry_phase) retry_clock<=retry_clock+1'b1;
            stamp_slot<=scan_slot;stamp_previous_slot<=send_slot;stamp_previous_write<=stamp_write;
            age_slot<=stamp_slot;
            age_expired<=elapsed>=RETRY_CYCLES && !(stamp_write && stamp_slot==send_slot) &&
                !(stamp_previous_write && stamp_slot==stamp_previous_slot);
            if(occupied[age_slot] && sent[age_slot] && age_expired &&
                !(stamp_write && age_slot==send_slot) &&
                !(stamp_previous_write && age_slot==stamp_previous_slot)) expired[age_slot]<=1;
            if(ack_busy) begin
                if(ack_release) begin occupied[ack_slot]<=0;sent[ack_slot]<=0;end
                if(ack_slot==7) begin ack_busy<=0;ack_release<=0;end
                else begin
                    ack_slot<=ack_slot+1'b1;
                    ack_release<=occupied[ack_slot+1'b1] && sent[ack_slot+1'b1] &&
                        slot_channel(ack_slot+1'b1)==ack_ch &&
                        $signed(slot_seq[ack_slot+1'b1]-ack_seq[7:0])<0;
                end
            end
            if(tx_meta_valid && tx_meta_ready) begin
                fill_slot<=free_slot;fill_word<=0;fill_count<=tx_length>>2;
                slot_seq[free_slot]<=next_seq[tx_channel][7:0];
                
                if(tx_length==0) occupied[free_slot]<=1;else collecting<=1;
                // A new slot is unsent, so !sent already makes it eligible;
                // expired is cleared on its first send. Avoid a second dynamic
                // bit write from free-slot selection into the retry flags.
                sent[free_slot]<=0;
            end
            if(tx_valid && tx_ready) begin
                fill_word<=fill_word+1'b1;
                if(fill_word+1'b1==fill_count) begin collecting<=0;occupied[fill_slot]<=1;end
                // A malformed local packet terminates the session, never hangs a slot.
                if(tx_last!=(fill_word+1'b1==fill_count)) begin peer_age<=TIMEOUT_CYCLES;peer_expired<=1;end
            end
            if(p_valid && p_ready) begin
                receive_alive<=current_r;
                delivery_ch<=p_ch;delivery_next_seq<=p_hdr[159:128]+32'd1;
                if(p_hdr[63:48]!=0) begin
                    delivering<=order_r;discarding<=!order_r;
                end else if(order_r) begin
                    receive_advance<=1;receive_ack<=1;
                end
                if(current_r && !order_r) receive_ack<=1;
            end
            if(p_dv && p_dr && p_last) begin
                if(delivering) begin
                    receive_advance<=1;receive_ack<=1;
                end
                delivering<=0;discarding<=0;
            end
            if(m_valid && m_ready) begin
                if(hello_accept) begin
                    peer_age<=0;peer_expired<=TIMEOUT_CYCLES==0;link_up<=1;
                    if(!link_up || m_change) begin
                        peer_session<=m_hdr[127:64];session_reset<=1;
                        occupied<=0;sent<=0;collecting<=0;
                        delivering<=0;discarding<=delivering || discarding || p_dv || (p_valid && p_ready && p_hdr[63:48]!=0);ack_pending<=0;
                        mac_busy_clear<=mac_busy;send_state<=0;
                        ack_busy<=0;ack_release<=0;expired<=0;
                        receive_ack<=0;receive_advance<=0;receive_alive<=0;
                        
                    end
                end else if(link_up && m_current) begin
                    peer_age<=0;peer_expired<=TIMEOUT_CYCLES==0;
                    if(m_ack_valid)
                        begin
                            ack_busy<=1;ack_slot<=0;ack_ch<=m_hdr[31:24];ack_seq<=m_hdr[63:32];
                            ack_release<=occupied[0] && sent[0] && slot_channel(3'd0)==m_hdr[31:24] &&
                                $signed(slot_seq[0]-m_hdr[39:32])<0;
                        end
                end
            end
            case(send_state)
                0: if(!mac_busy && !mac_busy_clear && phy_ok && session_nonce_ready) begin
                    if(hello_pending || ack_pending!=0) begin
                        header_session<=session;header_crc<=0;send_hello<=hello_pending;
                        send_seq<=management_header[159:128];send_channel<=management_header[47:40];send_management<=1;send_slot<=0;
                        send_state<=1;crc_byte_index<=0;crc_acc<=32'hffffffff;
                        if(hello_pending) hello_pending<=0;else ack_pending[ack_channel]<=0;
                    end else if(link_up && arb_ready && selected_valid && occupied[selected_slot] && slot_seq[selected_slot]==selected_seq) begin
                      if(selected_exhausted) begin
                        peer_age<=TIMEOUT_CYCLES;peer_expired<=1;
                      end else begin
                        send_management<=0;header_session<=session;header_crc<=0;
                        send_slot<=selected_slot;
                        send_seq_high<=next_seq[selected_channel][31:8];
                        send_seq_low<=selected_seq;
                        send_seq_borrow<=selected_seq>=next_seq[selected_channel][7:0];
                        send_channel<=selected_channel;
                        send_state<=4;crc_byte_index<=0;crc_acc<=32'hffffffff;
                        crc_address<={selected_slot[2:0],8'd0};
                      end
                    end
                end
                4:begin
                    // 本拍 BRAM 输出已是 send_slot 的描述符，锁存后供 CRC/MAC 使用。
                    header_q<=header_ram_q;
                    send_seq<={send_seq_high-{23'd0,send_seq_borrow},send_seq_low};
                    send_state<=5;
                end
                5:begin send_state<=1;end
                // Separate BRAM byte selection from the CRC feedback path.
                1:begin crc_byte_r<=crc_byte;send_state<=6;end
                6:begin
                    crc_acc<=db_crc_byte(crc_acc,crc_byte_r);
                    if(crc_byte_index==27+send_header[63:48]) send_state<=2;
                    else begin
                        crc_byte_index<=crc_byte_index+1'b1;send_state<=7;
                        if(crc_byte_index>=28 && crc_byte_index[1:0]==3)
                            crc_address<=crc_address+1'b1;
                    end
                end
                // Allow the synchronous packet RAM to settle after word advance.
                7:send_state<=1;
                2: begin
                    header_crc<=~crc_acc;
                    req_toggle<=~req_toggle;send_state<=3;
                    if(!send_management && occupied[send_slot]) begin
                        sent[send_slot]<=1;expired[send_slot]<=0;
                        if(sent[send_slot]) begin retry_count<=retry_count+1'b1;retry_seen<=1;end
                    end
                end
                3: if(!mac_busy) send_state<=0;
                default:send_state<=0;
            endcase
            // Preserve a newly advanced cumulative ACK even if an older ACK
            // for this channel starts transmission on the same edge.
            if(receive_ack && !session_reset && !peer_change) ack_pending[delivery_ch]<=1;
            if(!phy_ok || (link_up && peer_expired)) begin
                if(link_up) begin
                    session_reset<=1;session_nonce<=boot_counter;session_nonce_ready<=boot_counter!=0;hello_pending<=1;
                end
                receive_ack<=0;receive_advance<=0;receive_alive<=0;
                link_up<=0;occupied<=0;sent<=0;collecting<=0;ack_pending<=0;
                ack_busy<=0;ack_release<=0;expired<=0;
                delivering<=0;discarding<=delivering || discarding || p_dv || (p_valid && p_ready && p_hdr[63:48]!=0);mac_busy_clear<=mac_busy;
                send_state<=0;
                
            end
        end
    end
    // TX mailbox remains stable until the MAC has consumed the complete frame.
    // TEMAC acknowledges the FIRST byte, then requires uninterrupted valid/data.
    (* async_reg="true" *) reg req1,req2;
    (* async_reg="true" *) reg [1:0] tx_release;
    always @(posedge mac_tx_clk or posedge rst)
        if(rst) tx_release<=0;else tx_release<={tx_release[0],1'b1};
    wire tx_rst=~(&tx_release);
    // The same held header serves CRC and MAC. req/done ownership prevents
    // modification until the entire frame has crossed the clock boundary.
    wire [255:0] tx_hdr=send_header;
    reg [2:0] tx_slot;
    reg [11:0] byte_count,total_bytes,last_byte_count;
    reg [2:0] tx_state;
    reg [31:0] tx_word;
    reg tx_payload_region,tx_word_boundary,tx_header_region;
    reg [31:0] tx_header_word;
    reg [2:0] tx_header_word_index;
    // Co-registered indices remove subtractors from the 125 MHz byte path.
    reg [4:0] header_index;
    reg [7:0] payload_read_word;
    reg payload_short;reg [5:0] short_payload_end;
    reg [7:0] tx_byte;
    reg [7:0] tx_byte_registered;
    always @* begin
        if(byte_count<6) tx_byte=PEER_MAC[47-{byte_count[2:0],3'b000} -: 8];
        else if(byte_count<12) tx_byte=LOCAL_MAC[47-{(byte_count[3:0]-4'd6),3'b000} -: 8];
        else if(byte_count==12) tx_byte=8'h88;
        else if(byte_count==13) tx_byte=8'hb5;
        else if(tx_header_region) tx_byte=tx_header_word[31-{header_index[1:0],3'b000} -: 8];
        else if(!payload_short || byte_count[5:0]<short_payload_end) tx_byte=tx_word[31-{header_index[1:0],3'b000} -: 8];
        else tx_byte=0;
    end
    assign mac_ram_address={tx_slot,payload_read_word};
    assign mac_tx_data=tx_byte_registered;
    assign mac_tx_valid=(tx_state==2 || tx_state==3 || tx_state==5);
    always @(posedge mac_tx_clk or posedge tx_rst) begin
        if(tx_rst) begin req1<=0;req2<=0;mac_done<=0;tx_slot<=0;byte_count<=0;total_bytes<=0;last_byte_count<=0;tx_state<=0;tx_word<=0;tx_payload_region<=0;tx_word_boundary<=0;tx_header_region<=0;tx_header_word<=0;tx_header_word_index<=0;tx_byte_registered<=0;header_index<=18;payload_read_word<=0;payload_short<=1;short_payload_end<=46;end
        else begin
            req1<=req_toggle;req2<=req1;
            case(tx_state)
                0: if(req2!=mac_done) begin
                    tx_slot<=send_slot;tx_payload_region<=0;tx_word_boundary<=0;tx_header_region<=0;tx_header_word<=0;tx_header_word_index<=0;byte_count<=0;header_index<=18;payload_read_word<=0;
                    payload_short<=send_header[63:48]<14;short_payload_end<={2'd0,send_header[51:48]}+6'd46;
                    if(send_header[63:48]+32'd46<32'd60) begin
                        total_bytes<=12'd60;last_byte_count<=12'd59;
                    end else begin
                        total_bytes<=send_header[63:48]+32'd46;
                        last_byte_count<=send_header[63:48]+32'd45;
                    end
                    tx_state<=1;
                end
                1:begin tx_byte_registered<=tx_byte;byte_count<=1;header_index<=19;tx_state<=2;end
                2:if(mac_tx_ack) begin tx_byte_registered<=tx_byte;byte_count<=2;header_index<=20;tx_state<=3;end
                3:begin
                    tx_byte_registered<=tx_byte;
                    // Prefetch one 32-bit header word before its first byte.
                    // Separate the eight-word selection from byte serialization.
                    if(byte_count==13 || (tx_header_region && header_index[1:0]==3)) begin
                        tx_header_word<=tx_hdr[255-{tx_header_word_index,5'd0} -: 32];
                        tx_header_word_index<=tx_header_word_index+1'b1;
                    end
                    if(byte_count==13) tx_header_region<=1;
                    if(byte_count==45) tx_header_region<=0;
                    if(tx_word_boundary) tx_word<=tx_ram_q;
                    tx_word_boundary<=byte_count==44 || (tx_payload_region && header_index[1:0]==2);
                    if(byte_count==45) tx_payload_region<=1;
                    if(tx_word_boundary) payload_read_word<=payload_read_word+1'b1;
                    if(byte_count==last_byte_count) tx_state<=5;
                    else begin byte_count<=byte_count+1'b1;header_index<=header_index+1'b1;end
                  end
                5:tx_state<=4;
                4:begin mac_done<=req2;tx_state<=0;end
                default:tx_state<=0;
            endcase
        end
    end

    wire sequence_clear=(!phy_ok || (link_up && peer_expired)) ||
      (m_valid && m_ready && hello_accept && (!link_up || m_change));
    genvar sequence_channel;
    generate for(sequence_channel=0;sequence_channel<3;sequence_channel=sequence_channel+1)begin:sequence_bank
      wire tx_advance=tx_meta_valid && tx_meta_ready && tx_channel==sequence_channel;
      wire rx_advance=receive_advance && !session_reset && delivery_ch==sequence_channel;
      // Cache the carry predicates for the next accepted sequence number.
      // Each byte increment is then independent before the DSP hold input.
      reg carry8,carry16,carry24;
      always @(posedge clk or posedge rst) begin
        if(rst) begin carry8<=0;carry16<=0;carry24<=0;end
        else if(sequence_clear) begin carry8<=0;carry16<=0;carry24<=0;end
        else if(tx_advance) begin
          carry8<=next_seq[sequence_channel][7:0]==8'hfe;
          carry16<=next_seq[sequence_channel][15:0]==16'hfffe;
          carry24<=next_seq[sequence_channel][23:0]==24'hfffffe;
        end
      end
      wire [7:0] n0=next_seq[sequence_channel][7:0]+8'd1;
      wire [7:0] n1=next_seq[sequence_channel][15:8]+{7'd0,carry8};
      wire [7:0] n2=next_seq[sequence_channel][23:16]+{7'd0,carry16};
      wire [7:0] n3=next_seq[sequence_channel][31:24]+{7'd0,carry24};
      wire [31:0] tx_next={n3,n2,n1,n0};
      wire [31:0] rx_next=delivery_next_seq;
      if(ROLE==1)begin:transmit_dsp
        db_sequence_hold u_tx(.clk(clk),.rst(rst),.clear(sequence_clear),.enable(sequence_clear || tx_advance),
          .din(tx_next),.q(next_seq[sequence_channel]));
      end else begin:transmit_ff
        reg [31:0] held;
        always @(posedge clk or posedge rst)
          if(rst)held<=0;else if(sequence_clear)held<=0;else if(tx_advance)held<=tx_next;
        assign next_seq[sequence_channel]=held;
      end
      db_sequence_hold u_rx(.clk(clk),.rst(rst),.clear(sequence_clear),.enable(sequence_clear || rx_advance),
        .din(rx_next),.q(expect_seq[sequence_channel]));
    end endgenerate
endmodule

module db_sequence_hold(input wire clk,rst,clear,enable,input wire [31:0] din,output wire [31:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [31:0] held;
 always @(posedge clk or posedge rst)if(rst)held<=0;else if(enable)held<=clear ? 32'd0:din;
 assign q=held;
`else
 wire [35:0] low,high;
 assign q={high[13:0],low[17:0]};
 EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("ENABLE"),
  .SRMODE("ASYNC"),.MODE("MULT18X18C")) u_low(
  .clk(clk),.a(din[17:0]),.b({17'd0,!clear}),.acin(18'd0),.bcin(18'd0),
  .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
  .cea(1'b0),.ceb(1'b0),.cepd(enable),.rstan(1'b1),.rstbn(1'b1),.rstpdn(!rst),.acout(),.bcout(),.p(low));
 EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("ENABLE"),
  .SRMODE("ASYNC"),.MODE("MULT18X18C")) u_high(
  .clk(clk),.a({4'd0,din[31:18]}),.b({17'd0,!clear}),.acin(18'd0),.bcin(18'd0),
  .sourcea(1'b1),.sourceb(1'b1),.signeda(1'b0),.signedb(1'b0),
  .cea(1'b0),.ceb(1'b0),.cepd(enable),.rstan(1'b1),.rstbn(1'b1),.rstpdn(!rst),.acout(),.bcout(),.p(high));
`endif
endmodule
