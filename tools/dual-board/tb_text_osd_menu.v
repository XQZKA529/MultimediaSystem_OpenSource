`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_text_osd_menu;
    parameter RETRY_TEST=0,MENU_SMOKE=0;reg drop_volume=0;wire [31:0] volume_retries;
    reg clk=0,vc=0,t0=0,t1=0,rst=1,phy=1,vs=0;
    always #5 clk=~clk;always #6.667 vc=~vc;always #4 t0=~t0;always #4.01 t1=~t1;
    // Accelerated frame boundaries; full 720p timing is covered by tb_frame_read_dual.
    wire up0,up1,s0,s1;
    wire [7:0] macd0,macd1,rd0,rd1;wire macv0,macv1,ma0,ma1,rv0,rv1,rg0,rg1;
    wire mt0,mr0,dt0,dr0,lt0,mt1,mr1,dt1,dr1,lt1;
    wire [7:0] ch0,op0,ch1,op1;wire [31:0] obj0,off0,d0,obj1,off1,d1;wire [15:0] len0,len1;
    wire rm0,rrm0,rvd0,rrd0,rl0,rq0,rm1,rrm1,rvd1,rrd1,rl1,rq1;
    wire [7:0] rch0,rop0,rch1,rop1;wire [31:0] robj0,roff0,rdata0,robj1,roff1,rdata1;wire [15:0] rlen0,rlen1;
    db_link #(.RETRY_CYCLES(10000)) a(.retry_count(volume_retries),.clk(clk),.rst(rst),.phy_ok(phy),.link_up(up0),.session_reset(s0),
        .tx_meta_valid(mt0),.tx_meta_ready(mr0),.tx_channel(ch0),.tx_opcode(op0),.tx_object(obj0),.tx_offset(off0),.tx_length(len0),
        .tx_valid(dt0),.tx_ready(dr0),.tx_data(d0),.tx_last(lt0),
        .rx_meta_valid(rm0),.rx_meta_ready(rrm0),.rx_required(rq0),.rx_channel(rch0),.rx_opcode(rop0),.rx_object(robj0),.rx_offset(roff0),.rx_length(rlen0),
        .rx_valid(rvd0),.rx_ready(rrd0),.rx_data(rdata0),.rx_last(rl0),
        .mac_tx_clk(t0),.mac_tx_data(macd0),.mac_tx_valid(macv0),.mac_tx_ack(ma0),
        .mac_rx_clk(t1),.mac_rx_data(rd0),.mac_rx_valid(rv0),.mac_rx_good(rg0),.mac_rx_bad(1'b0));
    db_link_render #(.RETRY_CYCLES(10000),.ROLE(2),.LOCAL_MAC(`DB_MAC_RENDER),.PEER_MAC(`DB_MAC_MEDIA)) b(
        .clk(clk),.rst(rst),.phy_ok(phy),.link_up(up1),.session_reset(s1),
        .tx_meta_valid(mt1),.tx_meta_ready(mr1),.tx_channel(ch1),.tx_opcode(op1),.tx_object(obj1),.tx_offset(off1),.tx_length(len1),
        .tx_valid(dt1),.tx_ready(dr1),.tx_data(d1),.tx_last(lt1),
        .rx_meta_valid(rm1),.rx_meta_ready(rrm1),.rx_required(rq1),.rx_channel(rch1),.rx_opcode(rop1),.rx_object(robj1),.rx_offset(roff1),.rx_length(rlen1),
        .rx_valid(rvd1),.rx_ready(rrd1),.rx_data(rdata1),.rx_last(rl1),
        .mac_tx_clk(t1),.mac_tx_data(macd1),.mac_tx_valid(macv1),.mac_tx_ack(ma1),
        .mac_rx_clk(t0),.mac_rx_data(rd1),.mac_rx_valid(rv1),.mac_rx_good(rg1),.mac_rx_bad(1'b0));
    tb_mac_client_pipe p0(.clk(t0),.rst(rst),.din(macd0),.valid(macv0),.ack(ma0),.drop_next(drop_volume && a.send_header[239:232]==1 && a.send_header[39:32]==`DB_VOLUME_SET),.corrupt_next(1'b0),.dout(rd1),.dv(rv1),.good(rg1));
    tb_mac_client_pipe p1(.clk(t1),.rst(rst),.din(macd1),.valid(macv1),.ack(ma1),.drop_next(1'b0),.corrupt_next(1'b0),.dout(rd0),.dv(rv0),.good(rg0));
    // Complete menu lifecycle through both production links and the video commit.
    reg k2=1,k3=1,k4=1,ev=0,de=0;reg [5:0] event_data=0;
    wire event_ready,kp_send,kp_ready,kp_received;wire [5:0] kp_word,kp_received_data;
    wire active,local_page,commit,we,cen,nav;wire [8:0] addr;wire [7:0] character;
    wire [3:0] cursor,state,brightness,page;wire [4:0] contrast,saturation;wire [1:0] mode,transition;
    wire ao,ab,au,ad,al,ar,ac,vu,vd,mvu,mvd,vchanged,vhint;
    wire [4:0] volume;wire [31:0] vrevision;
    volume_controller volume_owner(.clk(clk),.rst(rst),.increase(vu || mvu),.decrease(vd || mvd),
        .shortcut(vu || vd),.level(volume),.changed(vchanged),.hint(vhint),.revision(vrevision));
    keypad_action_router #(.CLK_HZ(1000)) actions(.clk(clk),.rst(rst),.cancel(s0),
        .event_valid(kp_received),.event_data(kp_received_data),.ui_active(active),.text_osd_page(local_page),
        .ui_page(page),.navigable(nav),.playing(1'b0),.new_track(1'b0),
        .volume_up(vu),.volume_down(vd),.open_menu(ao),.back(ab),.up(au),.down(ad),.left(al),.right(ar),.confirm(ac));
    file_browser #(.CLK_FREQ_HZ(1000),.DEBOUNCE_MS(2),.HOLD_MS(1000)) menu(
        .clk(clk),.rst(rst),.ev_ok_press(1'b0),.ev_ok_release(1'b0),.ev_ok_hold(1'b0),
        .action_open(ao),.action_back(ab),.action_up(au),.action_down(ad),.action_left(al),.action_right(ar),.action_confirm(ac),
        .ui_page(page),.ui_navigable(nav),.text_osd_page(local_page),.key_open(k3),.key_sel(k2),.key_ok(k4),
        .volume_level(volume),.volume_increase(mvu),.volume_decrease(mvd),.brightness_mode(mode),.brightness_level(brightness),.contrast_level(contrast),.saturation_level(saturation),.transition_mode(transition),
        .img_idle(1'b1),.img_ready(1'b1),.fat_busy(1'b0),.dir_gnt(1'b0),.dir_dat(86'd0),
        .ui_active(active),.ui_commit_toggle(commit),.cursor_row(cursor),.cursor_en(cen),
        .ui_wr_en(we),.ui_wr_addr(addr),.ui_wr_data(character),
        .ext_load_ack(1'b0),.ext_load_rejected(1'b0),.ext_play_ack(1'b0),.ext_play_rejected(1'b0),.dbg_browser_state(state));
    seam_media #(.FRAME_WORDS(432)) source(.saturation_level(saturation),.subtitle_valid(1'b0),.subtitle_revision(32'd0),.subtitle_word(32'd0),.subtitle_word_valid(1'b0),.volume_level(volume),.volume_changed(vchanged),.volume_hint(vhint),.volume_revision(vrevision),.keypad_valid(kp_received),.keypad_data(kp_received_data),
        .clk(clk),.rst(rst),.link_up(up0),.session_reset(s0),.image_req(1'b0),.image_word_valid(1'b0),
        .image_word(32'd0),.image_source_ok(1'b0),.image_source_failed(1'b0),
        .pcm_push(1'b0),.pcm(32'd0),.pcm_clear(1'b0),.pcm_eof(1'b0),.pcm_total(32'd0),.pcm_base(32'd0),
        .pcm_stream_toggle(1'b0),.paused(1'b0),.seek_request(1'b0),
        .contrast_level(contrast),.brightness_level(brightness),.brightness_mode(mode),.transition_mode(transition),
        .ui_page(page),.ui_wr_en(we),.ui_wr_addr(addr),.ui_wr_data(character),.text_osd_page(local_page),.ui_active(active),
        .ui_cursor_en(cen),.ui_cursor_row(cursor),.ui_commit_toggle(commit),.diag(4'd15),
        .rx_meta_valid(rm0),.rx_meta_ready(rrm0),.rx_required(rq0),.rx_channel(rch0),.rx_opcode(rop0),.rx_object(robj0),.rx_offset(roff0),.rx_length(rlen0),
        .rx_valid(rvd0),.rx_ready(rrd0),.rx_data(rdata0),.rx_last(rl0),
        .tx_meta_valid(mt0),.tx_meta_ready(mr0),.tx_channel(ch0),.tx_opcode(op0),.tx_object(obj0),.tx_offset(off0),.tx_length(len0),
        .tx_valid(dt0),.tx_ready(dr0),.tx_data(d0),.tx_last(lt0));
    wire ractive,rlocal,rcommit,rwe,rcen,frame_active,frame_local,uiack;
    wire debug_ui_dirty=source.ui_dirty,debug_ui_pending=source.ui_pending;
    wire debug_page_ready=source.page_ready,debug_copy_dirty=source.copy_dirty;
    wire [1:0] debug_copy_state=source.copy_state;
    wire [31:0] debug_ui_controls=source.ui_controls,debug_ui_controls_seen=source.ui_controls_seen;
    wire [8:0] debug_copy_index=source.copy_index;
    wire debug_ui_wr=we,debug_commit=commit;
    wire [31:0] debug_controls_frozen=source.ui_controls_frozen;
    wire [2:0] debug_tx_state=source.tx_state,debug_ui_bytes=sink.ui_bytes;
    wire [3:0] debug_payload_kind=sink.payload_kind;
    wire debug_ui_busy=sink.ui_busy;
    wire debug_checked_ui=sink.checked_ui,debug_checked_payload=sink.checked_ui_payload;
    wire [8:0] raddr;wire [7:0] rchar;wire [3:0] rcursor,rbrightness;
    wire [4:0] rcontrast,rvolume,video_volume;wire rvolume_valid,rvolume_hint,volume_event;
    wire [3:0] rpage;
    integer volume_hints=0,pcm_checks=0;
    volume_view_cdc volume_cdc(.clk(clk),.rst(rst),.cfg_valid(rvolume_valid),.cfg_level(rvolume),.cfg_hint(rvolume_hint),
        .cancel(s1 || !up1),.video_clk(vc),.video_rst(rst),.vs(vs),.level(video_volume),.hint_event(volume_event));
    always @(negedge vc) if(volume_event) volume_hints=volume_hints+1;
    wire pcm_volume_valid;wire [23:0] pcm_volume_left,pcm_volume_right;
    audio_volume_gain volume_gain(.clk(vc),.rst(rst),.level(video_volume),
        .in_valid(1'b1),.in_left(24'h7fffff),.in_right(24'h800000),
        .out_valid(pcm_volume_valid),.out_left(pcm_volume_left),.out_right(pcm_volume_right));
    seam_render #(.FRAME_WORDS(432)) sink(.volume_valid(rvolume_valid),.volume_level(rvolume),.volume_hint(rvolume_hint),.clk(clk),.rst(rst),.link_up(up1),.session_reset(s1),
        .keypad_valid(kp_send),.keypad_data(kp_word),.keypad_ready(kp_ready),.video_clk(vc),.video_rst(rst),.vs(vs),
        .rx_meta_valid(rm1),.rx_meta_ready(rrm1),.rx_required(rq1),.rx_channel(rch1),.rx_opcode(rop1),.rx_object(robj1),.rx_offset(roff1),.rx_length(rlen1),
        .rx_valid(rvd1),.rx_ready(rrd1),.rx_data(rdata1),.rx_last(rl1),
        .tx_meta_valid(mt1),.tx_meta_ready(mr1),.tx_channel(ch1),.tx_opcode(op1),.tx_object(obj1),.tx_offset(off1),.tx_length(len1),
        .tx_valid(dt1),.tx_ready(dr1),.tx_data(d1),.tx_last(lt1),
        .write_req_ack(1'b0),.write_abort_ack(1'b1),.write_full(1'b0),.write_sector_ready(1'b1),.write_finish_toggle(1'b0),
        .read_selected_index(2'd0),.read_handoff_toggle(1'b0),.transition_ack(1'b0),.transition_done(1'b0),.transition_failed(1'b0),
        .ui_page(rpage),.text_osd_page(rlocal),.ui_active(ractive),.ui_cursor_en(rcen),.ui_cursor_row(rcursor),
        .ui_wr_en(rwe),.ui_wr_addr(raddr),.ui_wr_data(rchar),.ui_commit_toggle(rcommit),.ui_commit_seen(uiack),
        .brightness_level(rbrightness),.brightness_mode(2'd2),.contrast_level(rcontrast),
        .audio_packet_ready(1'b1),.audio_feedback(1'b0),.feedback_epoch(32'd0),.feedback_position(32'd0),.feedback_flags(3'd0));
    wire cancel,edit,up,down,left,right,confirm,on;wire [4:0] focus;wire [8:0] length;
    wire [14:0] metadata,view;wire [31:0] revision;
    wire [7:0] text_addr;wire [7:0] text_data;wire text_commit;
    wire edit_wr_en;wire [7:0] edit_wr_addr,edit_wr_data;
    wire clock_edit,clock_up,clock_down,clock_left,clock_right,clock_confirm,clock_editing;
    wire [32:0] clock_live,clock_draft;wire [2:0] clock_focus;
    wire [47:0] clock_live_digits,clock_draft_digits;wire [2:0] clock_video_focus;wire clock_video_editing;
    reg clock_visible1=0,clock_visible2=0;
    always @(posedge clk) begin
        if(rst) begin clock_visible1<=0;clock_visible2<=0;end
        else begin clock_visible1<=clock_video_editing && frame_active && rpage==7;clock_visible2<=clock_visible1;end
    end
    text_osd_event_router route(.clk(clk),.rst(rst),.link_up(up1),.session_reset(s1),.input_cancel(1'b0),
        .ui_active(ractive),.text_osd_page(rlocal),.ui_page(rpage),.ui_commit_toggle(rcommit),.ui_commit_seen(uiack),
        .event_valid(ev),.event_data(event_data),.event_ready(event_ready),
        .remote_valid(kp_send),.remote_data(kp_word),.remote_ready(kp_ready),.encoder_cancel(cancel),
        .edit_enable(edit),.up(up),.down(down),.left(left),.right(right),.confirm(confirm),
        .clock_edit_enable(clock_edit),.clock_up(clock_up),.clock_down(clock_down),.clock_left(clock_left),.clock_right(clock_right),.clock_confirm(clock_confirm));
    calendar_clock clock_owner(.clk(clk),.rst(rst),.edit_enable(clock_edit),.cancel(1'b0),
        .up(clock_up && clock_visible2),.down(clock_down && clock_visible2),
        .left(clock_left && clock_visible2),.right(clock_right && clock_visible2),.confirm(clock_confirm && clock_visible2),
        .live(clock_live),.draft(clock_draft),.focus(clock_focus),.editing(clock_editing));
    clock_view_cdc clock_cdc(.clk(clk),.rst(rst),.live(clock_live),.draft(clock_draft),.focus(clock_focus),.editing(clock_editing),
        .video_clk(vc),.video_rst(rst),.vs(vs),.live_digits(clock_live_digits),.draft_digits(clock_draft_digits),
        .video_focus(clock_video_focus),.video_editing(clock_video_editing));
    text_osd_controller editor(.clk(clk),.rst(rst),.edit_enable(edit),.up(up),.down(down),.left(left),.right(right),.confirm(confirm),
        .metadata(metadata),.revision(revision),.edit_wr_en(edit_wr_en),.edit_wr_addr(edit_wr_addr),.edit_wr_data(edit_wr_data),.osd_enable(on),.text_len(length),.focus_id(focus));
    text_osd_view_cdc cdc(.clk(clk),.rst(rst),.metadata(metadata),.revision(revision),.edit_wr_en(edit_wr_en),.edit_wr_addr(edit_wr_addr),.edit_wr_data(edit_wr_data),.text_addr(text_addr),.text_data(text_data),.video_clk(vc),.video_rst(rst),.vs(vs),.view(view),.video_commit(text_commit));
    wire [23:0] rgb_ui,rgb_out;wire out_de,ui_hs,ui_vs,ui_de;
    wire [6:0] mc,tc;wire [3:0] mx,my,tx,ty;wire [1:0] alpha;
    wire use_menu=frame_active && !frame_local;
    font_rom shared_font(.clk(vc),.char_code(use_menu ? mc:tc),
        .gx(use_menu ? mx:tx),.gy(use_menu ? my:ty),.alpha(alpha));
    ui_text_overlay #(.EXTERNAL_FONT(1)) ui(.saturation_level(5'd10),.video_clk(vc),.rst(rst),.hs(1'b0),.vs(vs),.de(de),.pix_in(24'h123456),.pix_out(rgb_ui),
        .hs_out(ui_hs),.vs_out(ui_vs),.de_out(ui_de),.ui_page(rpage),.contrast_level(rcontrast),.volume_level(rvolume),.osd_enabled(view[14]),
        .font_char(mc),.font_x(mx),.font_y(my),.font_alpha(alpha),
        .text_osd_page(rlocal),.ui_active_frame(frame_active),.text_osd_page_frame(frame_local),
        .ui_active(ractive),.ui_commit_toggle(rcommit),.cursor_row(rcursor),.cursor_en(rcen),
        .wr_clk(clk),.wr_en(rwe),.wr_addr(raddr),.wr_data(rchar),.dbg_commit_seen(uiack),.brightness_level(rbrightness));
    text_osd_overlay #(.EXTERNAL_FONT(1)) pixels(.clk(vc),.rst(rst),.hs(ui_hs),.vs(ui_vs),.de(ui_de),.pix_in(rgb_ui),
        .font_char(tc),.font_x(tx),.font_y(ty),.font_alpha(alpha),
        .ui_active_frame(frame_active),.text_osd_page_frame(frame_local),.diag_show(1'b0),.banner_source(1'b0),.banner_reset(text_commit),.view(view),.text_addr(text_addr),.text_data(text_data),.de_out(out_de),.pix_out(rgb_out));
    task step;input integer n;begin repeat(n) @(negedge clk);end endtask
    task frame;begin step(2200);@(negedge vc);vs=1;repeat(10) @(negedge vc);vs=0;step(20);end endtask
    task key;input [5:0] value;begin @(negedge clk);event_data=value;ev=1;
        @(posedge clk);while(!event_ready) @(posedge clk);@(negedge clk);ev=0;step(1000);end endtask
    integer settle_calls=0;
    task settle;input wanted_active,wanted_local;integer n;begin
        settle_calls=settle_calls+1;
        n=0;while((ractive!==wanted_active || rlocal!==wanted_local || rpage!==page || source.ui_dirty || source.ui_pending || source.copy_state!=0 || source.tx_state!=0) && n<300) begin
            step(1000);frame;n=n+1;
        end
        frame;step(100);
        if(ractive!==wanted_active || rlocal!==wanted_local || frame_active!==wanted_active || frame_local!==wanted_local)
            $fatal(1,"Menu propagation failed call=%0d state=%0d active=%b/%b frame=%b page=%0d/%0d local=%b/%b/%b ui=%b/%b ready=%b copy=%b/%0d idx=%0d wr=%b commit=%b controls=%h/%h/%h tx=%0d kind=%0d recvbytes=%0d busy=%b checked=%b/%b links=%b/%b",
                settle_calls,state,active,ractive,frame_active,page,rpage,local_page,rlocal,frame_local,
                debug_ui_dirty,debug_ui_pending,debug_page_ready,debug_copy_dirty,debug_copy_state,debug_copy_index,debug_ui_wr,debug_commit,
                debug_ui_controls,debug_ui_controls_seen,debug_controls_frozen,
                debug_tx_state,debug_payload_kind,debug_ui_bytes,debug_ui_busy,debug_checked_ui,debug_checked_payload,up0,up1);
    end endtask
    task board;input integer k;begin case(k) 2:k2=0;3:k3=0;4:k4=0;endcase step(12);
        k2=1;k3=1;k4=1;step(12);end endtask
    task volume_settle;input [4:0] want;integer t;begin
        t=0;while(video_volume!==want && t<100) begin step(1000);frame;t=t+1;end
        if(video_volume!==want || rvolume!==want || volume!==want) $fatal(1,"Volume failed through both links");
        repeat(550) @(negedge vc);
    end endtask
    integer x,y,editor_pixels=0,old_hints;
    initial begin
        rst=0;step(2);rst=1;step(20);rst=0;
        wait(up0 && up1);step(1000);frame;step(1000);
        board(3);wait(state==12);settle(1,0);
        if(MENU_SMOKE) begin
            repeat(9) key(9);
            if(cursor!=11) $fatal(1,"Tenth INTERVAL menu item navigation");
            key(5);settle(1,0);
            if(page!=8 || rpage!=8) $fatal(1,"INTERVAL page snapshot did not cross both production links");
            key(14);settle(1,0);
            if(page!=1 || rpage!=1 || cursor!=11) $fatal(1,"INTERVAL return lifecycle");
            board(3);wait(state==0);settle(0,0);
            $display("*** PASS *** tenth INTERVAL item, page-8 snapshot and return through both production links");$finish;
        end
        key(9);key(9);key(9);key(9);settle(1,0);if(cursor!=6) $fatal(1,"Text OSD menu selection");
        board(4);settle(1,1);if(!edit || nav) $fatal(1,"Editor ownership/ready");
        key(5);key(9);key(5);if(!on || length!=1 || focus!=2) $fatal(1,"Local editing failed");
        frame;frame;
        for(y=0;y<435;y=y+1) begin
            for(x=0;x<840;x=x+1) begin
                @(negedge vc);de=1;
                // The editor retains its white border independently of its
                // translucent interior and background-dependent glyph edges.
                if(out_de && rgb_out==24'hd6dbe1) editor_pixels=editor_pixels+1;
            end
            @(negedge vc);de=0;repeat(10) @(negedge vc);
        end
        if(editor_pixels<500) $fatal(1,"Editor did not render pixels: %d",editor_pixels);
        key(14);settle(1,0);if(local_page || cursor!=6 || !nav) $fatal(1,"Return to settings failed");
        key(1);settle(1,0);if(cursor!=5) $fatal(1,"Navigation blocked after return");
        key(9);board(4);settle(1,1);if(length!=1 || !on) $fatal(1,"Reentry lost configuration");
        board(3);wait(state==0);settle(0,0);
        // Closed-window/no-track shortcuts traverse both production links.
        if(RETRY_TEST) fork
            begin key(9);end
            begin drop_volume=1;
                wait(p0.active && p0.drop_frame);wait(!p0.active);drop_volume=0;end
        join
        else key(9);
        volume_settle(19);step(15000);frame;
        if(RETRY_TEST && volume_retries==0) $fatal(1,"Volume retry not exercised");
        if(volume_hints!=1) $fatal(1,"Shortcut hint delivery");
        key(1);volume_settle(20);old_hints=volume_hints;key(1);step(2000);frame;frame;
        if(volume!=20 || volume_hints!=old_hints+1) $fatal(1,"Boundary hint delivery");
        board(3);wait(state==12);settle(1,0);key(9);settle(1,0);
        if(cursor!=7) $fatal(1,"Volume sixth item");key(5);wait(state==15);settle(1,0);
        key(4);volume_settle(19);key(6);volume_settle(20);
        if(pcm_volume_left!=24'h7fffff || pcm_volume_right!=24'h800000) $fatal(1,"Unity PCM through network config");
        repeat(20) key(4);volume_settle(0);
        if(pcm_volume_left!=0 || pcm_volume_right!=0) $fatal(1,"Mute PCM through network config");
        old_hints=volume_hints;key(14);settle(1,0);board(3);wait(state==0);settle(0,0);
        phy=0;step(20);phy=1;wait(up0 && up1);step(5000);frame;frame;
        if(volume!=0 || video_volume!=0 || volume_hints!=old_hints) $fatal(1,"Reconnect volume/hint replay");
        if(length!=1 || !on) $fatal(1,"Volume changed Text OSD storage");
        board(3);wait(state==12);settle(1,0);key(9);key(9);settle(1,0);
        if(cursor!=9) $fatal(1,"CLOCK eighth item through both links");
        key(5);wait(state==15);settle(1,0);
        frame;step(200);frame;step(200);
        if(rpage!=7 || !clock_edit || !clock_editing || edit || nav || clock_focus!=0) begin
            $display("Clock entry page=%d ready=%b editing=%b",rpage,clock_edit,clock_editing);
            $display("Clock entry text=%b nav=%b focus=%d",edit,nav,clock_focus);
            $display("Clock ACK=%b commit=%b",uiack,rcommit);
            $fatal(1,"CLOCK entry ownership/enter-key isolation");
        end
        key(6);if(clock_draft[32:26]!=1 || clock_live[32:26]!=0 || page!=7) $fatal(1,"CLOCK local edit");
        repeat(6) key(9);key(5);if(clock_live[32:26]!=1) $fatal(1,"CLOCK APPLY through local route");
        key(14);settle(1,0);if(rpage!=1 || cursor!=9 || clock_editing) $fatal(1,"CLOCK back lifecycle");
        board(4);wait(state==15);settle(1,0);frame;step(200);frame;step(200);key(6);
        board(3);wait(state==0);settle(0,0);if(clock_live[32:26]!=1) $fatal(1,"CLOCK cancel overwrote live");
        phy=0;step(30);if(clock_editing || clock_live[32:26]!=1) $fatal(1,"CLOCK disconnect retention");
        phy=1;wait(up0 && up1);step(5000);frame;frame;
        if(clock_live[32:26]!=1 || length!=1 || !on) $fatal(1,"CLOCK reconnect/Text storage isolation");
        $display("*** PASS *** CLOCK eighth entry/both links/frame ACK/local draft/APPLY/cancel/reconnect, volume and Text OSD complete menu");$finish;
    end
    initial begin #30000000;$fatal(1,"Menu system timeout");end
endmodule
