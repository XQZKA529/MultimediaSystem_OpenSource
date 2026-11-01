`timescale 1ns/1ps
`include "pkg/text_osd_model.vh"
module tb_text_osd_events;
    reg clk=0,rst=1,link=1,sreset=0,active=0,page=0,commit=0,ack=0;
    reg down=0,online=1,fault=0,remote_ready=1;reg [3:0] id=0;
    wire valid,ready,cancel,remote_valid,edit,up,dn,left,right,confirm;
    wire [5:0] data,remote_data;wire [`TEXT_OSD_MODEL_W-1:0] model;
    wire on;wire [`TEXT_OSD_LEN_W-1:0] length;wire [4:0] focus;integer fives=0,backs=0,cancels=0;
    always #5 clk=~clk;
    keypad_event_encoder #(.CLK_HZ(1000)) encoder(.clk(clk),.rst(rst),.cancel(fault || cancel),
        .enabled(link && !sreset),.down(down),.online(online),.key_id(id),.valid(valid),.ready(ready),.data(data));
    text_osd_event_router router(.clk(clk),.rst(rst),.link_up(link),.session_reset(sreset),
        .input_cancel(fault),
        .ui_active(active),.text_osd_page(page),.ui_commit_toggle(commit),.ui_commit_seen(ack),
        .event_valid(valid),.event_data(data),.event_ready(ready),.remote_valid(remote_valid),.remote_data(remote_data),
        .remote_ready(remote_ready),.encoder_cancel(cancel),.edit_enable(edit),.up(up),.down(dn),.left(left),.right(right),.confirm(confirm));
    text_osd_controller controller(.clk(clk),.rst(rst),.edit_enable(edit),.up(up),.down(dn),.left(left),.right(right),.confirm(confirm),
        .metadata(),.osd_enable(on),.text_len(length),.focus_id(focus),.revision(),.read_addr(7'd0),.read_data(),.changed());
    always @(posedge clk) if(remote_valid && remote_ready) begin
        if(remote_data==5) fives=fives+1;
        if(remote_data==14) backs=backs+1;
        if(remote_data[5:4]==3) cancels=cancels+1;
    end
    task step;input integer n;begin repeat(n) @(negedge clk);end endtask
    task press;input [3:0] key;begin id=key;down=1;step(8);end endtask
    task release_key;begin down=0;step(8);end endtask
    task tap;input [3:0] key;begin press(key);release_key;end endtask
    task snapshot;input a,p;begin active=a;page=p;commit=~commit;step(8);end endtask
    task frame;begin ack=commit;step(12);end endtask
    initial begin
        step(3);rst=0;step(8);snapshot(1,0);frame;
        press(5);if(fives!=1) $fatal(1,"Parent confirm not forwarded");
        snapshot(1,1);step(600);if(on || edit) $fatal(1,"Edited before video commit");
        frame;step(600);if(on) $fatal(1,"Entry held 5 edited local page");
        release_key;press(5);step(600);release_key;
        if(!on || fives!=1) $fatal(1,"Local 5 not single local action");
        tap(9);tap(5);if(length!=1 || focus!=2) $fatal(1,"Local A input");
        press(6);step(810);release_key;if(focus!=6) $fatal(1,"Local direction repeats %d",focus);
        remote_ready=0;press(14);step(40);
        if(backs || !remote_valid) $fatal(1,"Back lost under backpressure");
        remote_ready=1;step(8);release_key;
        if(backs!=1 || edit) $fatal(1,"Exit fence");
        snapshot(1,1);frame;tap(5);if(length!=1 || edit) $fatal(1,"Late local snapshot undid exit");
        snapshot(1,0);frame;tap(5);if(fives!=2 || length!=1) $fatal(1,"Remote ownership restored");
        snapshot(1,1);frame;tap(5);if(length!=2) $fatal(1,"Re-entry retention");
        sreset=1;step(4);sreset=0;step(20);tap(5);
        if(length!=2 || edit) $fatal(1,"Session retained stale editing context");
        snapshot(1,1);frame;tap(5);if(length!=3) $fatal(1,"Fresh snapshot after reconnect");
        online=0;step(10);online=1;press(5);step(30);
        if(length!=3) $fatal(1,"Fault did not require release");
        release_key;tap(5);if(length!=4) $fatal(1,"Fault recovery");
        id=5;down=1;step(1);fault=1;step(1);fault=0;release_key;
        if(length!=4) $fatal(1,"Fault coincident with queued confirm did not win");
        // Snapshot departure stops editing immediately, before display catches up.
        snapshot(0,0);tap(5);if(length!=4) $fatal(1,"Closed page still edited");frame;
        if(cancels<4) $fatal(1,"Missing cancellation deliveries");
        $display("*** PASS *** Text OSD routing: real encoder, entry/repeats, backpressure, late snapshot, session/fault, ownership");$finish;
    end
    initial begin #100000;$fatal(1,"Event timeout");end
endmodule
