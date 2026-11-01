`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_system;
    parameter SCALE_BMP=0;
    parameter BMP_W=32,BMP_H=18;
    parameter FRAME_WORDS=691200;
    reg clk=0,vc=0,t0=0,t1=0,rst=1,phy=1,vs=0;
    always #5 clk=~clk;always #6.667 vc=~vc;always #4 t0=~t0;always #4.01 t1=~t1;
    // Accelerated frame boundaries; full 720p timing is covered by tb_frame_read_dual.
    always begin #10000;vs=1;#100;vs=0;end
    wire up0,up1,s0,s1;
    reg kp_send=0;reg [5:0] kp_word=0;wire kp_ready,kp_received;wire [5:0] kp_received_data;integer kp_count=0;
    always @(posedge clk) if(kp_received) begin if(kp_received_data!==kp_count[5:0]) $fatal(1,"keypad link order");kp_count=kp_count+1;end
    wire [7:0] macd0,macd1,rd0,rd1;wire macv0,macv1,ma0,ma1,rv0,rv1,rg0,rg1;
    wire mt0,mr0,dt0,dr0,lt0,mt1,mr1,dt1,dr1,lt1;
    wire [7:0] ch0,op0,ch1,op1;wire [31:0] obj0,off0,d0,obj1,off1,d1;wire [15:0] len0,len1;
    wire rm0,rrm0,rvd0,rrd0,rl0,rq0,rm1,rrm1,rvd1,rrd1,rl1,rq1;
    wire [7:0] rch0,rop0,rch1,rop1;wire [31:0] robj0,roff0,rdata0,robj1,roff1,rdata1;wire [15:0] rlen0,rlen1;
    db_link a(.clk(clk),.rst(rst),.phy_ok(phy),.link_up(up0),.session_reset(s0),
        .tx_meta_valid(mt0),.tx_meta_ready(mr0),.tx_channel(ch0),.tx_opcode(op0),.tx_object(obj0),.tx_offset(off0),.tx_length(len0),
        .tx_valid(dt0),.tx_ready(dr0),.tx_data(d0),.tx_last(lt0),
        .rx_meta_valid(rm0),.rx_meta_ready(rrm0),.rx_required(rq0),.rx_channel(rch0),.rx_opcode(rop0),.rx_object(robj0),.rx_offset(roff0),.rx_length(rlen0),
        .rx_valid(rvd0),.rx_ready(rrd0),.rx_data(rdata0),.rx_last(rl0),
        .mac_tx_clk(t0),.mac_tx_data(macd0),.mac_tx_valid(macv0),.mac_tx_ack(ma0),
        .mac_rx_clk(t1),.mac_rx_data(rd0),.mac_rx_valid(rv0),.mac_rx_good(rg0),.mac_rx_bad(1'b0));
    db_link_render #(.ROLE(2),.LOCAL_MAC(`DB_MAC_RENDER),.PEER_MAC(`DB_MAC_MEDIA)) b(
        .clk(clk),.rst(rst),.phy_ok(phy),.link_up(up1),.session_reset(s1),
        .tx_meta_valid(mt1),.tx_meta_ready(mr1),.tx_channel(ch1),.tx_opcode(op1),.tx_object(obj1),.tx_offset(off1),.tx_length(len1),
        .tx_valid(dt1),.tx_ready(dr1),.tx_data(d1),.tx_last(lt1),
        .rx_meta_valid(rm1),.rx_meta_ready(rrm1),.rx_required(rq1),.rx_channel(rch1),.rx_opcode(rop1),.rx_object(robj1),.rx_offset(roff1),.rx_length(rlen1),
        .rx_valid(rvd1),.rx_ready(rrd1),.rx_data(rdata1),.rx_last(rl1),
        .mac_tx_clk(t1),.mac_tx_data(macd1),.mac_tx_valid(macv1),.mac_tx_ack(ma1),
        .mac_rx_clk(t0),.mac_rx_data(rd1),.mac_rx_valid(rv1),.mac_rx_good(rg1),.mac_rx_bad(1'b0));
    tb_mac_client_pipe p0(.clk(t0),.rst(rst),.din(macd0),.valid(macv0),.ack(ma0),.drop_next(1'b0),.corrupt_next(1'b0),.dout(rd1),.dv(rv1),.good(rg1));
    tb_mac_client_pipe p1(.clk(t1),.rst(rst),.din(macd1),.valid(macv1),.ack(ma1),.drop_next(1'b0),.corrupt_next(1'b0),.dout(rd0),.dv(rv0),.good(rg0));
    reg req=0,iv=0,success=0,uw=0,uc=0;reg [31:0] word=0;reg [8:0] ua=0;reg [7:0] ud=0;
    wire ack,finish,credit,overflow;
    reg requested_local_page=0;wire received_local_page;
    reg [4:0] requested_contrast=17,requested_saturation=10;wire [4:0] received_contrast,received_saturation;reg [3:0] requested_brightness=5;wire [3:0] received_brightness;wire [1:0] received_mode;
    wire bmp_req,bmp_iv,bmp_success,bmp_failed,pixel_credit;wire [31:0] bmp_word;
    reg [31:0] bmp_expected[0:BMP_W*BMP_H*3/4-1];
    generate if(SCALE_BMP) begin: real_bmp
        tb_bmp_network_source #(.TARGET_W(BMP_W),.TARGET_H(BMP_H)) bmp(.clk(clk),.rst(rst),.launch(req),.ack(ack),.finish(finish),
            .pixel_ready(pixel_credit),.req(bmp_req),.word_valid(bmp_iv),
            .success(bmp_success),.failed(bmp_failed),.word(bmp_word));
        initial $readmemh("network_expected.hex",bmp_expected);
    end endgenerate
    seam_media #(.FRAME_WORDS(FRAME_WORDS)) source(.saturation_level(requested_saturation),.ui_page(4'd0),.transition_mode(2'd0),.subtitle_valid(1'b0),.volume_level(5'd20),.volume_changed(1'b0),.volume_hint(1'b0),.volume_revision(32'd0),.keypad_valid(kp_received),.keypad_data(kp_received_data),
        .clk(clk),.rst(rst),.link_up(up0),.session_reset(s0),.image_req(SCALE_BMP ? bmp_req:req),.image_ack(ack),.image_finish_toggle(finish),
        .image_word_valid(SCALE_BMP ? bmp_iv:iv),.image_word(SCALE_BMP ? bmp_word:word),.image_source_ok(SCALE_BMP ? bmp_success:success),.image_source_failed(SCALE_BMP && bmp_failed),.image_burst_ready(credit),.image_pixel_ready(pixel_credit),
        .pcm_push(1'b0),.pcm(32'd0),.pcm_clear(1'b0),.pcm_eof(1'b0),.pcm_total(32'd0),.pcm_base(32'd0),.pcm_stream_toggle(1'b0),.paused(1'b0),.seek_request(1'b0),
        .contrast_level(requested_contrast),.brightness_level(requested_brightness),.brightness_mode(received_mode),.ui_wr_en(uw),.ui_wr_addr(ua),.ui_wr_data(ud),.text_osd_page(requested_local_page),.ui_active(1'b1),.ui_cursor_en(1'b1),.ui_cursor_row(4'd2),.ui_commit_toggle(uc),.diag(4'd15),
        .rx_meta_valid(rm0),.rx_meta_ready(rrm0),.rx_required(rq0),.rx_channel(rch0),.rx_opcode(rop0),.rx_object(robj0),.rx_offset(roff0),.rx_length(rlen0),
        .rx_valid(rvd0),.rx_ready(rrd0),.rx_data(rdata0),.rx_last(rl0),
        .tx_meta_valid(mt0),.tx_meta_ready(mr0),.tx_channel(ch0),.tx_opcode(op0),.tx_object(obj0),.tx_offset(off0),.tx_length(len0),
        .tx_valid(dt0),.tx_ready(dr0),.tx_data(d0),.tx_last(lt0),.overflow(overflow));
    wire wr,ab,we,valid,uiwe,uitoggle;wire [31:0] wd;wire [1:0] wi,di;wire [8:0] uiaddr;wire [7:0] uichar;
    reg wack=0,aack=0,wdone=0,uiack=0;
    wire rhandoff;wire [1:0] rselected;
    wire t_req,t_ack,t_done,t_fail;wire [1:0] t_new,t_cur;
    tb_transition_model transition(.clk(vc),.rst(rst),.vs(vs),.req(t_req),.new_idx(t_new),.cur_idx(t_cur),
        .ack(t_ack),.done(t_done),.failed(t_fail),.selected(rselected),.handoff(rhandoff));
    seam_render #(.FRAME_WORDS(FRAME_WORDS)) sink(.text_osd_page(received_local_page),.keypad_valid(kp_send),.keypad_data(kp_word),.keypad_ready(kp_ready),.contrast_level(received_contrast),.saturation_level(received_saturation),.brightness_mode(2'd2),.brightness_level(received_brightness),
        .clk(clk),.rst(rst),.link_up(up1),.session_reset(s1),.video_clk(vc),.video_rst(rst),.vs(vs),
        .rx_meta_valid(rm1),.rx_meta_ready(rrm1),.rx_required(rq1),.rx_channel(rch1),.rx_opcode(rop1),.rx_object(robj1),.rx_offset(roff1),.rx_length(rlen1),
        .rx_valid(rvd1),.rx_ready(rrd1),.rx_data(rdata1),.rx_last(rl1),
        .tx_meta_valid(mt1),.tx_meta_ready(mr1),.tx_channel(ch1),.tx_opcode(op1),.tx_object(obj1),.tx_offset(off1),.tx_length(len1),
        .tx_valid(dt1),.tx_ready(dr1),.tx_data(d1),.tx_last(lt1),
        .write_req(wr),.write_req_ack(wack),.write_abort(ab),.write_abort_ack(aack),.write_en(we),.write_data(wd),
        .write_full(1'b0),.write_sector_ready(1'b1),.write_finish_toggle(wdone),.read_selected_index(rselected),.read_handoff_toggle(rhandoff),
        .transition_req(t_req),.transition_new_index(t_new),.transition_cur_index(t_cur),
        .transition_ack(t_ack),.transition_done(t_done),.transition_failed(t_fail),
        .write_index(wi),.display_index(di),.display_valid(valid),.ui_wr_en(uiwe),.ui_wr_addr(uiaddr),.ui_wr_data(uichar),.ui_commit_toggle(uitoggle),.ui_commit_seen(uiack),
        .audio_packet_ready(1'b1),.audio_feedback(1'b0),.feedback_epoch(32'd0),.feedback_position(32'd0),.feedback_flags(3'd0));
    // SDRAM DMA timing model, not a physical SDRAM model. Delay the last-write
    // and old-read completion to exercise both business completion barriers.
    integer writes=0,uichars=0,done_delay=0,read_delay=0;
    always @(posedge clk) begin
        if(rst) begin wack<=0;aack<=0;end
        else begin
            wack<=wr;aack<=ab;
            if(overflow) $fatal(1,"4 KiB source FIFO overflow");
            if(we) begin
                if(wd!==(SCALE_BMP ? bmp_expected[writes]:writes)) $fatal(1,"network image loss/order");writes=writes+1;
                if(writes%131072==0) $display("image words %0d / %0d at %0d us",writes,FRAME_WORDS,$time/1000);
                if(writes==FRAME_WORDS) done_delay=64;
            end
            if(done_delay>0) begin done_delay=done_delay-1;if(done_delay==0) wdone<=~wdone;end

            if(uiwe) begin
                if(uiaddr!=(uichars%288) || uichar!==((uichars%288)%256)) $fatal(1,"network UI snapshot");uichars=uichars+1;
            end
            if(vs) uiack<=uitoggle;
            if(valid && (writes!=FRAME_WORDS || done_delay!=0)) $fatal(1,"early image display");
        end
    end
    integer i;
    initial begin
        #100;rst=0;wait(up0 && up1);repeat(20) @(posedge clk);
        for(i=0;i<288;i=i+1) begin @(negedge clk);uw=1;ua=i;ud=i;end
        @(negedge clk);uw=0;uc=~uc;req=1;wait(ack);@(negedge clk);req=0;repeat(10) @(posedge clk);
        $display("TRANSFER start at %0d us",$time/1000);
        if(!SCALE_BMP) begin
        for(i=0;i<FRAME_WORDS;i=i+1) begin
            if(i%512==0) begin @(negedge clk);iv=0;wait(credit);end
            @(negedge clk);iv=1;word=i;
        end
        @(negedge clk);iv=0;success=1;
        end
        wait(finish);
        $display("TRANSFER finish at %0d us (%0d words)",$time/1000,writes);
        if(writes!=FRAME_WORDS || uichars!=288 || !valid || di!=0 || rselected!=di) $fatal(1,"incomplete business completion");
        wait(received_mode==2);
        if(received_contrast!=17) $fatal(1,"Contrast missing from UI flags");
        if(received_brightness!=5) $fatal(1,"Brightness missing from UI flags");
        // Local editor entry/exit uses the 296-byte snapshot.
        requested_local_page=1;wait(received_local_page);wait(uiack==uitoggle);repeat(10) @(posedge clk);
        requested_local_page=0;wait(!received_local_page);wait(uiack==uitoggle);repeat(10) @(posedge clk);
        // Control-only changes must send a complete new snapshot without text writes.
        requested_brightness=3;requested_contrast=0;wait(received_brightness==3 && received_contrast==0);
        wait(uiack==uitoggle);repeat(10) @(posedge clk);
        requested_contrast=20;requested_saturation=0;wait(received_contrast==20 && received_saturation==0);
        requested_saturation=20;wait(received_saturation==20);
        wait(uiack==uitoggle);repeat(10) @(posedge clk);
        requested_saturation=5;wait(source.copy_state==1);requested_saturation=13;wait(received_saturation==13);
        wait(uiack==uitoggle);repeat(10) @(posedge clk);
        // Change the setting while disconnected, then verify current snapshot resend.
        @(negedge clk);phy=0;wait(!up0 && !up1);requested_contrast=6;requested_saturation=7;
        repeat(200) @(negedge clk);phy=1;wait(up0 && up1);
        wait(received_contrast==6 && received_brightness==3 && received_saturation==7);
        wait(uiack==uitoggle);repeat(10) @(posedge clk);
        if(kp_count!=16) $fatal(1,"keypad delivery count %d",kp_count);
        $display("*** PASS *** system: %0d RGB888 packed words + 288 UI chars + brightness/contrast/saturation controls, reconnect resend and backend feedback through both reliable Ethernet endpoints",FRAME_WORDS);$finish;
    end
    initial begin #300000000;$fatal(1,"system watchdog");end
initial begin
      wait(up0 && up1);repeat(20) @(negedge clk);
      repeat(16) begin
        kp_send=1;@(posedge clk);while(!kp_ready) @(posedge clk);
        @(negedge clk);kp_send=0;kp_word=kp_word+1'b1;repeat(50) @(negedge clk);
      end
    end
endmodule
