`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_image_commit;
    // Shrunk from the production CLK_HZ/2 (500 ms) so the expiry path can be
    // exercised without simulating half a second of 100 MHz clock.
    localparam DIAG_HOLD_CYCLES = 400;
    reg clk=0,vc=0,rst=1,vs=0,sreset=0;
    always #5 clk=~clk;always #6.667 vc=~vc;
    reg mv=0,dv=0,last=0;
    reg [7:0] ch=2,op=0;reg [31:0] obj=1,off=0,data=0;reg [15:0] len=0;
    wire mr,dr,wr,abort,we,tm;wire [7:0] to;
    wire [1:0] wi,di;wire valid;wire [3:0] diag;
    reg ack=0,abort_ack=0,finish=0,handoff=0,sector_ready=1;
    reg [1:0] selected=0;
    // ---- 视频域切换事务控制器模型（替代真实 mix_transition_ctrl）----
    // 收到 transition_req 后：延迟若干脆拍回 ack，随后回 done 并把"新图"设为
    // 当前显示（通过 selected/handoff 暴露给 DUT 的 I_PRESENT 判定）。
    reg t_ack=0,t_done=0,t_fail=0;
    reg [1:0] trans_new=0;
    reg [1:0] trans_state=0;   // 0 idle, 1 wait ack, 2 animating, 3 done
    integer anim_frames=0;
    wire t_req;wire [1:0] t_new,t_cur;
    integer ready_count=0,present_count=0,errors=0,writes=0;
    reg [31:0] expected=0;
    seam_render #(.FRAME_WORDS(64),.DIAG_HOLD_CYCLES(DIAG_HOLD_CYCLES)) dut(.keypad_valid(1'b0),.keypad_data(6'd0),.brightness_mode(2'd0),
        .clk(clk),.rst(rst),.link_up(1'b1),.session_reset(sreset),.video_clk(vc),.video_rst(rst),.vs(vs),
        .rx_meta_valid(mv),.rx_meta_ready(mr),.rx_required(1'b1),.rx_channel(ch),.rx_opcode(op),.rx_object(obj),.rx_offset(off),.rx_length(len),
        .rx_valid(dv),.rx_ready(dr),.rx_data(data),.rx_last(last),
        .tx_meta_valid(tm),.tx_meta_ready(1'b1),.tx_opcode(to),.tx_ready(1'b1),
        .write_req(wr),.write_req_ack(ack),.write_abort(abort),.write_abort_ack(abort_ack),
        .write_en(we),.write_data(),.write_full(1'b0),.write_sector_ready(sector_ready),.write_finish_toggle(finish),
        .read_selected_index(selected),.read_handoff_toggle(handoff),.write_index(wi),.display_index(di),.display_valid(valid),
        .transition_req(t_req),.transition_new_index(t_new),.transition_cur_index(t_cur),
        .transition_ack(t_ack),.transition_done(t_done),.transition_failed(t_fail),
        .ui_commit_seen(1'b0),.diag(diag),.audio_packet_ready(1'b1),.audio_feedback(1'b0),
        .feedback_epoch(32'd0),.feedback_position(32'd0),.feedback_flags(3'd0));
    // 事务控制器模型：req → 下一拍 ack；ack 后走 2 个帧界 → done，
    // done 之后把新图索引用 selected/handoff 送到 DUT（模拟真实 handoff）。
    always @(posedge clk) begin
        case(trans_state)
            0:if(t_req) begin trans_new<=t_new;t_ack<=1;trans_state<=1;anim_frames<=0;end
            1:if(anim_frames<2) anim_frames<=anim_frames+1;
              else begin t_done<=1;selected<=trans_new;handoff<=~handoff;trans_state<=2;end
            2:if(!t_req) begin t_ack<=0;t_done<=0;trans_state<=0;end
            default:trans_state<=0;
        endcase
    end

    always @(posedge clk) begin
        ack<=wr;abort_ack<=abort;
        if(tm) begin
            if(to==`DB_IMG_READY) ready_count=ready_count+1;
            if(to==`DB_IMG_PRESENTED) present_count=present_count+1;
            if(to==`DB_ERROR) errors=errors+1;
        end
        if(we) begin
            if(data!==expected) $fatal(1,"write order/data %h expected %h",data,expected);
            expected=expected+1;writes=writes+1;
        end
    end
    `include "../rtl/link/db_crc.vh"
    function [31:0] crcw;input [31:0] c,d;
        begin crcw=db_crc_byte(db_crc_byte(db_crc_byte(db_crc_byte(c,d[31:24]),d[23:16]),d[15:8]),d[7:0]);end
    endfunction
    task meta;input [7:0] code;input [31:0] id,offset;input [15:0] length;
        begin @(negedge clk);op=code;obj=id;off=offset;len=length;mv=1;
            @(posedge clk);while(!mr) @(posedge clk);@(negedge clk);mv=0;end
    endtask
    task word;input [31:0] d;input l;
        // Return immediately after acceptance so successive calls sustain one
        // word per clock, exercising the CRC feedback pipeline at full rate.
        begin @(negedge clk);data=d;last=l;dv=1;@(posedge clk);while(!dr) @(posedge clk);#1;dv=0;end
    endtask
    task framevs;begin @(negedge vc);vs=1;repeat(3) @(negedge vc);vs=0;repeat(12) @(posedge clk);end endtask
    integer i;reg [31:0] crc;
    initial begin
        #100;rst=0;repeat(10) @(posedge clk);
        if(diag!==13) $fatal(1,"reset must wait for peer STATUS");
        ch=0;meta(`DB_STATUS,0,5,0);repeat(4) @(posedge clk);
        if(diag!==5) $fatal(1,"peer diagnostic code not displayed");
        @(negedge clk);sreset=1;@(negedge clk);sreset=0;
        // A re-handshake must NOT blank a still-meaningful peer diagnostic back to
        // WAIT DATA (13) -- that flicker was the on-board defect.  The latch is
        // bounded by DIAG_HOLD_CYCLES, so it is held here but must still expire.
        if(diag!==5) $fatal(1,"re-handshake dropped a live peer diagnostic");
        // ...and it must expire rather than freeze on a dead peer: with the link
        // still nominally up, running past the hold window falls back to WAIT DATA.
        repeat(DIAG_HOLD_CYCLES+50) @(posedge clk);
        if(diag!==13) $fatal(1,"stale diagnostic latch never expired (diag=%0d)",diag);
        ch=0;meta(`DB_STATUS,0,5,0);repeat(4) @(posedge clk);
        if(diag!==5) $fatal(1,"peer diagnostic not re-armed after expiry");
        ch=2;
        meta(`DB_IMG_BEGIN,1,64,0);wait(ready_count==1);
        // Metadata must stay pending while image FIFO credits are unavailable.
        // Releasing credit is sampled in the existing classification stage;
        // no data word or image count can advance before that handshake.
        crc=32'hffffffff;
        @(negedge clk);sector_ready=0;op=`DB_IMG_DATA;obj=1;off=0;len=256;mv=1;
        repeat(12) begin @(posedge clk);if(mr || we || writes!=0) $fatal(1,"image credit stall bypassed");end
        @(negedge clk);sector_ready=1;
        @(posedge clk);if(mr) $fatal(1,"credit classification must precede metadata acceptance");
        @(posedge clk);while(!mr) @(posedge clk);@(negedge clk);mv=0;
        for(i=0;i<64;i=i+1) begin word(i,i==63);crc=crcw(crc,i);end
        meta(`DB_IMG_END,1,0,4);word(~crc,1);
        framevs();if(valid || present_count!=0) $fatal(1,"commit before SDRAM done");
        // ★ 新语义：写完成后由视频域事务控制器在帧界提交显示切换。
        //   seam_render 不再直接提交 display_index，而是在事务 done 后置位。
        @(negedge clk);finish=~finish;
        // 事务完成后（TB 模型发 done 并切 selected/handoff）才应出现 PRESENTED。
        wait(dut.image_state==5);repeat(8) @(negedge vc);framevs();
        wait(present_count==1);
        framevs();
        if(!valid || di!=0) $fatal(1,"display index not switched to new buffer");
        // A second good image must survive mailbox return-to-idle and swap banks.
        expected=0;meta(`DB_IMG_BEGIN,2,64,0);wait(ready_count==2);
        crc=32'hffffffff;meta(`DB_IMG_DATA,2,0,256);
        for(i=0;i<64;i=i+1) begin word(i,i==63);crc=crcw(crc,i);end
        meta(`DB_IMG_END,2,0,4);word(~crc,1);
        @(negedge clk);finish=~finish;
        wait(dut.image_state==5);repeat(8) @(negedge vc);framevs();wait(present_count==2);
        if(!valid || di!=1) $fatal(1,"second good image mailbox/bank swap");
        expected=0;meta(`DB_IMG_BEGIN,3,64,0);wait(ready_count==3);
        meta(`DB_IMG_DATA,3,0,16);for(i=0;i<4;i=i+1) word(i,i==3);
        @(negedge clk);sreset=1;@(negedge clk);sreset=0;wait(!abort);repeat(40) @(posedge clk);framevs();
        if(!valid || di!=1 || present_count!=2) $fatal(1,"partial disconnect changed picture");
        expected=0;meta(`DB_IMG_BEGIN,4,64,0);wait(ready_count==4);
        crc=32'hffffffff;meta(`DB_IMG_DATA,4,0,256);
        for(i=0;i<64;i=i+1) begin word(i,i==63);crc=crcw(crc,i);end
        meta(`DB_IMG_END,4,0,4);word(~crc^1,1);wait(errors!=0);repeat(50) @(posedge clk);framevs();
        if(di!=1 || present_count!=2) $fatal(1,"bad whole-image CRC committed");
        $display("*** PASS *** image: write completion, VS, read ownership, partial disconnect, whole-image CRC and peer diagnostic validity");$finish;
    end
    initial begin #500000;$display("image timeout state=%d",dut.image_state);$fatal(1,"image timeout");end
endmodule
