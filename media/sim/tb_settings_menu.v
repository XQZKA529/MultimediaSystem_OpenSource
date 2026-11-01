`timescale 1ns/1ps
`include "pkg/fat_dir_bus.vh"
module tb_settings_menu;
    parameter SHARED_OK=0;
    wire shared_press,shared_release,shared_hold;
    reg clk=0,rst=1,k2=1,k3=1,k4=1;
    reg [6:0] actions=0;
    reg [1:0] mode=2;
    reg [`VDIR_DBUS_W-1:0] dir=0;
    wire req,start,active,commit,we,cursor_en,load,play,local_page,navigable;
    wire [4:0] contrast,saturation;wire [3:0] row,state,level;wire [8:0] address;wire [7:0] data;
    wire [4:0] volume;wire vi,vd;
    volume_controller owner(.clk(clk),.rst(rst),.increase(vi),.decrease(vd),.shortcut(1'b0),.level(volume));
    wire [31:0] cluster,size;
    reg load_ack=0,play_ack=0,last_commit=0,txt_ack=0,txt_bad=0;
    reg sub_display=0,sub_auto=0;reg [3:0] sub_status=0;
    wire sub_dt,sub_at,sub_clear,txt_req;wire [31:0] txt_cluster,txt_size;
    integer txt_loads=0,clears=0;
    reg [7:0] text[0:287];
    integer i,entry_number,loads=0,plays=0,legacy_next_count=0;wire legacy_next;
    always #5 clk=~clk;
    key_debounce #(.CLK_FREQ_HZ(1000),.DEBOUNCE_MS(2),.HOLD_MS(1000)) shared_key(.clk(clk),.rst(rst),.button_in(k4),.press_pulse(shared_press),.release_pulse(shared_release),.hold_pulse(shared_hold));

    always @(posedge clk) begin
        if(!rst && dut.scan_inflight && dut.load_inflight)
            $fatal(1,"Directory scan and load share a timer and must not overlap");
        if(we) text[address]<=data;
        if(sub_dt) sub_display<=~sub_display;
        if(sub_at) begin sub_auto<=~sub_auto;sub_display<=1;end
        if(sub_clear) clears=clears+1;
        if(txt_req) txt_loads=txt_loads+1;
        if(legacy_next) legacy_next_count=legacy_next_count+1;
        if(load) loads=loads+1;
        if(play) plays=plays+1;
    end
    file_browser #(.CLK_FREQ_HZ(1000),.DEBOUNCE_MS(2),.HOLD_MS(1000)) dut(.legacy_next_pulse(legacy_next),.ev_ok_press(SHARED_OK && shared_press),.ev_ok_release(SHARED_OK && shared_release),.ev_ok_hold(SHARED_OK && shared_hold),.action_open(actions[0]),.action_back(actions[1]),.action_up(actions[2]),.action_down(actions[3]),.action_left(actions[4]),.action_right(actions[5]),.action_confirm(actions[6]),
        .subtitle_display(sub_display),.subtitle_auto(sub_auto),.subtitle_status(sub_status),
        .subtitle_display_toggle(sub_dt),.subtitle_auto_toggle(sub_at),.subtitle_clear(sub_clear),
        .ext_txt_req(txt_req),.ext_txt_cluster(txt_cluster),.ext_txt_size(txt_size),.ext_txt_ack(txt_ack),.ext_txt_rejected(txt_bad),
        .text_osd_page(local_page),.ui_navigable(navigable),.clk(clk),.rst(rst),.key_open(k3),.key_sel(k2),.key_ok(SHARED_OK ? 1'b1:k4),
        .volume_level(volume),.volume_increase(vi),.volume_decrease(vd),.contrast_level(contrast),.saturation_level(saturation),.brightness_mode(mode),.brightness_level(level),
        .img_idle(1'b1),.img_ready(1'b1),.fat_busy(1'b0),.dir_req(req),.dir_gnt(req),.dir_start(start),.dir_dat(dir),
        .ui_active(active),.ui_commit_toggle(commit),.cursor_row(row),.cursor_en(cursor_en),
        .ui_wr_en(we),.ui_wr_addr(address),.ui_wr_data(data),
        .ext_load_req(load),.ext_load_cluster(cluster),.ext_load_size(size),.ext_load_ack(load_ack),.ext_load_rejected(1'b0),
        .ext_play_req(play),.ext_play_ack(play_ack),.ext_play_rejected(1'b0),.dbg_browser_state(state));
    always @(negedge clk) if(!rst) begin
        if(dut.state_hot==0 || (dut.state_hot & (dut.state_hot-1))!=0)
            $fatal(1,"Browser control state must remain one-hot");
        if(!dut.state_hot[state]) $fatal(1,"Diagnostic state does not match control state");
    end
    task step;input integer cycles;begin repeat(cycles) @(negedge clk);end endtask
    task tap;input integer key;
        begin @(negedge clk);case(key) 2:k2=0;3:k3=0;4:k4=0;endcase
            step(12);case(key) 2:k2=1;3:k3=1;4:k4=1;endcase step(12);
        end
    endtask
    task await_state;input [3:0] want;integer t;
        begin t=0;while(state!==want && t<4000) begin step(1);t=t+1;end
            if(state!==want) $fatal(1,"Menu state timeout want=%d actual=%d",want,state);
        end
    endtask
    task matrix;input integer n;begin @(negedge clk);actions=1<<n;step(1);actions=0;step(3);end endtask
    task next_option;begin tap(2);step(310);end endtask
    task double_back;begin tap(2);step(20);tap(2);await_state(12);step(320);end endtask
    task send_entry;input [31:0] name;input [31:0] cl;
        begin dir=0;dir[`VDIR_D_ESTART]=1;step(1);dir=0;
            for(i=0;i<4;i=i+1) begin
                dir[`VDIR_D_NVLD]=1;dir[`VDIR_D_CHAR]=name[(3-i)*8 +: 8];dir[`VDIR_D_INDEX]=i;step(1);
            end
            dir=0;dir[`VDIR_D_EEND]=1;dir[`VDIR_D_FCLUST]=cl;dir[`VDIR_D_SIZE]=4096;step(1);dir=0;step(2);
        end
    endtask
    task finish_dir;
        begin dir=0;dir[`VDIR_D_DONE]=1;dir[`VDIR_D_OK]=1;step(1);dir=0;end
    endtask
    initial begin
        step(4);rst=0;await_state(0);
        if(active || level!=10 || text[0]!="S") $fatal(1,"Boot defaults/hidden page");
        tap(2);if(legacy_next_count!=1) $fatal(1,"closed KEY2 next pulse");
        // Debounce: a sub-threshold KEY3 glitch must not open the menu.
        k3=0;step(1);k3=1;step(15);if(active) $fatal(1,"Debounce glitch");
        tap(3);await_state(12);if(row!=2 || !cursor_en || text[64]!="F") $fatal(1,"Settings page");
        k4=0;step(1020);k4=1;step(12);if(state!=12) $fatal(1,"long KEY4 entered menu");
        next_option;if(row!=3) $fatal(1,"Selection");tap(4);await_state(13);
        tap(4);await_state(13);if(level!=9) $fatal(1,"Lower brightness");
        for(i=0;i<12;i=i+1) begin tap(4);await_state(13);end
        if(level!=1) $fatal(1,"Lower bound");
        double_back;if(level!=1 || row!=3) $fatal(1,"Double click changed brightness/selection");
        tap(4);await_state(13);
        repeat(12) begin next_option;await_state(13);end
        if(level!=10 || text[71]!="1" || text[72]!="0" || text[73]!="0") $fatal(1,"Upper bound/display");
        double_back;next_option;if(row!=4 || text[128]!="C") $fatal(1,"Contrast selection");
        tap(4);await_state(15);
        if(contrast!=10 || text[0]!="C" || text[160]!="I") $fatal(1,"Contrast defaults/page");
        repeat(25) begin tap(4);await_state(15);end
        if(contrast!=0 || level!=10) $fatal(1,"Contrast lower bound/brightness isolation");
        double_back;if(contrast!=0 || row!=4) $fatal(1,"Contrast double changed level/selection");
        tap(4);await_state(15);
        repeat(25) begin next_option;await_state(15);end
        if(contrast!=20 || text[71]!="2" || text[72]!="0" || text[73]!="0" || text[148]!="=")
            $fatal(1,"Contrast upper bound/display/bar");
        tap(4);await_state(15);if(contrast!=19) $fatal(1,"Contrast decrement");
        double_back;if(contrast!=19) $fatal(1,"Double leaked single increment");
        tap(4);await_state(15);tap(3);await_state(0);
        if(active || contrast!=19) $fatal(1,"Contrast close/retention");
        tap(3);await_state(12);next_option;if(row!=5) $fatal(1,"Saturation selection");
        tap(4);await_state(15);if(dut.page!=9 || saturation!=10 || text[0]!="S" || text[160]!="I") $fatal(1,"Saturation default/page");
        repeat(21) begin tap(4);await_state(15);end
        if(saturation!=0 || contrast!=19 || level!=10) $fatal(1,"Saturation minimum/isolation");
        repeat(21) begin next_option;await_state(15);end
        if(saturation!=20 || text[71]!="2" || text[72]!="0" || text[73]!="0" || text[148]!="=") $fatal(1,"Saturation maximum/display");
        tap(4);await_state(15);if(saturation!=19) $fatal(1,"Saturation decrement");
        double_back;if(row!=5 || saturation!=19) $fatal(1,"Saturation return");
        next_option;if(row!=6) $fatal(1,"Text selection");
        if(text[160]!="T") $fatal(1,"OSD menu ROM row");
        matrix(6);if(!local_page || navigable || req || load || play || state!=12) $fatal(1,"Local OSD entry");
        next_option;tap(4);matrix(2);matrix(3);matrix(6);
        if(row!=6 || !local_page || req || state!=12) $fatal(1,"Board keys or media navigation edited local page");
        matrix(1);await_state(12);if(local_page || row!=6) $fatal(1,"OSD matrix return");
        matrix(6);double_back;if(local_page || row!=6) $fatal(1,"OSD board double return");
        matrix(6);tap(3);await_state(0);if(local_page) $fatal(1,"OSD global close");
        tap(3);await_state(12);next_option;if(row!=7) $fatal(1,"Fifth volume selection");
        tap(4);await_state(15);if(volume!=20 || text[0]!="V") $fatal(1,"Volume entry");
        repeat(22) begin tap(4);step(5);await_state(15);end
        if(volume!=0 || text[72]!="0" || text[73]!="0") $fatal(1,"Volume lower bound");
        repeat(21) begin next_option;step(5);await_state(15);end
        if(volume!=20 || text[71]!="1" || text[73]!="0") $fatal(1,"Volume upper bound/display");
        tap(4);step(5);await_state(15);if(volume!=19 || text[72]!="9" || text[73]!="5") $fatal(1,"Volume five percent");
        double_back;if(volume!=19 || row!=7) $fatal(1,"Volume return retention");
        next_option;if(row!=8) $fatal(1,"Sixth SD subtitle selection");
        tap(4);await_state(15);if(text[0]!="S" || row!=2) $fatal(1,"SD page");
        tap(4);step(10);await_state(15);if(!sub_display || text[77]!="N") $fatal(1,"SD display toggle");
        next_option;tap(4);step(10);await_state(15);if(!sub_auto || row!=3 || text[109]!="N") $fatal(1,"SD auto toggle");
        next_option;tap(4);step(10);await_state(15);if(clears!=1) $fatal(1,"SD clear");
        sub_status=4;step(10);await_state(15);if(text[192]!="N") $fatal(1,"SD status redraw");
        double_back;if(row!=8) $fatal(1,"SD return");next_option;
        if(row!=9 || text[256]!="C") $fatal(1,"Seventh CLOCK entry");
        tap(4);await_state(15);if(dut.page!=7 || navigable || local_page) $fatal(1,"Clock lifecycle page");
        tap(4);next_option;if(dut.page!=7 || contrast!=19) $fatal(1,"Board keys edited clock/contrast");
        double_back;if(row!=9) $fatal(1,"Clock return selection");next_option;if(row!=10) $fatal(1,"Transition menu entry");
        tap(4);await_state(15);double_back;if(row!=10) $fatal(1,"Transition menu return selection");next_option;if(row!=11) $fatal(1,"Ninth interval entry");
        tap(4);await_state(15);if(dut.page!=8 || dut.auto_interval_steps!=1 || text[71]!="0" || text[72]!="0" || text[73]!="5")
            $fatal(1,"Interval page/default value");
        tap(2);step(320);await_state(15);if(dut.auto_interval_steps!=2 || text[73]!="0") $fatal(1,"Interval increase");
        tap(4);await_state(15);if(dut.auto_interval_steps!=1 || text[73]!="5") $fatal(1,"Interval minimum clamp/decrease");
        repeat(59) begin tap(2);step(320);await_state(15);end
        if(dut.auto_interval_steps!=60 || text[71]!="3" || text[72]!="0" || text[73]!="0") $fatal(1,"Interval maximum/value");
        tap(2);step(320);await_state(15);if(dut.auto_interval_steps!=60) $fatal(1,"Interval maximum clamp");
        double_back;if(row!=11) $fatal(1,"Interval return selection");next_option;if(row!=2) $fatal(1,"Settings wrap after interval");
        tap(4);await_state(4);
        // Return during active directory enumeration: retain ownership.
        double_back;if(!req) $fatal(1,"Directory released before done");
        tap(4);step(350);if(state!=12 || !req) $fatal(1,"Re-entered busy browser");
        finish_dir;step(4);if(req) $fatal(1,"Directory not released on done");
        tap(4);await_state(4);send_entry(".BMP",32'd7);send_entry(".WAV",32'd8);finish_dir;await_state(6);
        next_option;if(row!=1) $fatal(1,"Browser cursor");
        tap(4);wait(play);step(3);play_ack=1;step(1);play_ack=0;await_state(0);
        if(active || plays!=1 || loads!=0) $fatal(1,"WAV confirm/close");
        tap(3);await_state(12);tap(4);await_state(4);
        send_entry(".BMP",32'd7);finish_dir;await_state(6);tap(4);wait(load);step(3);
        // A late load ACK after global return must not close the parent menu.
        double_back;load_ack=1;step(1);load_ack=0;step(20);
        if(state!=12 || !active || loads!=1 || cluster!=7) $fatal(1,"Late ACK affected parent");
        tap(3);await_state(0);if(active || level!=10 || contrast!=19) $fatal(1,"KEY3 close/retention");
        tap(3);await_state(12);next_option;tap(4);await_state(13);
        mode=1;wait(state==14);step(80);mode=2;wait(dut.mode_drawn==2);await_state(13);step(3);
        if(state!=13 || text[160]!="G" || text[161]!="L") $fatal(1,"Backend text update lost during draw");
        last_commit=commit;mode=1;wait(state==14);tap(3);await_state(0);
        if(active || commit==last_commit) $fatal(1,"Close during draw did not commit a complete hidden page");
        // Independent matrix semantic actions, including wrap and live back.
        matrix(0);await_state(12);matrix(2);if(row!=2) $fatal(1,"matrix settings up");
        matrix(2);if(row!=11) $fatal(1,"matrix settings wrap");matrix(2);if(row!=10) $fatal(1,"matrix transition entry");matrix(2);if(row!=9) $fatal(1,"matrix settings clock entry");matrix(2);matrix(2);matrix(2);matrix(2);matrix(2);if(row!=4) $fatal(1,"matrix contrast select");matrix(6);await_state(15);
        matrix(4);await_state(15);if(contrast!=18) $fatal(1,"matrix contrast left");
        matrix(5);await_state(15);if(contrast!=19) $fatal(1,"matrix contrast right");
        matrix(1);await_state(12);matrix(2);if(row!=3) $fatal(1,"matrix brightness selection");
        matrix(6);await_state(13);matrix(4);await_state(13);if(level!=9) $fatal(1,"matrix brightness left");
        matrix(5);await_state(13);if(level!=10) $fatal(1,"matrix brightness right");
        matrix(1);await_state(12);matrix(2);matrix(6);await_state(4);
        send_entry(".BMP",32'd7);send_entry(".WAV",32'd8);finish_dir;await_state(6);
        matrix(2);if(row!=1) $fatal(1,"matrix browser up wrap");matrix(3);if(row!=0) $fatal(1,"matrix browser down wrap");
        matrix(6);wait(load);step(3);matrix(1);await_state(12);
        load_ack=1;step(1);load_ack=0;step(20);if(!active || state!=12) $fatal(1,"matrix late ack");
        matrix(1);await_state(0);if(active) $fatal(1,"matrix root close");
        tap(2);if(legacy_next_count!=2) $fatal(1,"menu KEY2 leaked image actions");
        matrix(0);await_state(12);matrix(6);await_state(4);
        send_entry(".TXT",32'd9);finish_dir;await_state(6);matrix(6);wait(txt_req);step(5);
        if(txt_cluster!=9 || txt_size!=4096 || loads!=2 || plays!=1) $fatal(1,"TXT independent request");
        txt_bad=1;step(1);txt_bad=0;await_state(6);if(!active || txt_loads!=1) $fatal(1,"TXT failed close");
        matrix(6);wait(txt_req);step(5);txt_ack=1;step(1);txt_ack=0;await_state(0);
        if(active || txt_loads!=2) $fatal(1,"TXT business ACK close");
        // Cross the eight-entry page boundary, then re-enumerate the root.
        // The first entry on page two must retain its own TXT type/cluster,
        // rather than metadata from one of the eight preceding BMP entries.
        matrix(0);await_state(12);matrix(6);await_state(4);
        for(entry_number=0;entry_number<8;entry_number=entry_number+1)
            send_entry(".BMP",32'd100+entry_number);
        send_entry(".TXT",32'd108);finish_dir;await_state(6);
        for(entry_number=0;entry_number<7;entry_number=entry_number+1) begin
            matrix(3);await_state(6);
        end
        matrix(3);await_state(4);
        for(entry_number=0;entry_number<8;entry_number=entry_number+1)
            send_entry(".BMP",32'd100+entry_number);
        send_entry(".TXT",32'd108);finish_dir;await_state(6);
        matrix(6);wait(txt_req);step(5);
        if(txt_cluster!=108 || txt_size!=4096 || txt_loads!=3)
            $fatal(1,"TXT metadata across page boundary");
        txt_ack=1;step(1);txt_ack=0;await_state(0);
        $display("*** PASS *** SD settings/TXT, CLOCK/TRANSITION navigation, volume, local OSD, contrast, debounce, directory drain, BMP/WAV and late ACK");$finish;
    end
    initial begin #3000000;$fatal(1,"Menu watchdog");end
endmodule
