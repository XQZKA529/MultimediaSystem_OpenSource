`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_ui_snapshot;
    reg clk=0,rst=1,sreset=0,mv=0,dv=0,last=0,uiack=0;
    reg [31:0] data=0;wire mr,dr,commit,we,local_page;
    reg [7:0] opcode=`DB_UI_SNAPSHOT;
    reg [31:0] offset=0;reg [15:0] length=296;
    wire reply_valid;wire [7:0] reply_status;wire [31:0] reply_epoch,reply_revision;
    integer replies=0,chars_before;
    wire [4:0] contrast,saturation;wire [3:0] brightness;reg [31:0] saturation_word=32'h2a;reg [4:0] expected_saturation=10;
    integer i,chars=0;reg previous_commit;
    always #5 clk=~clk;
    always @(posedge clk) begin
        if(rst) uiack<=0;
        else begin uiack<=commit;if(we) chars=chars+1;if(reply_valid) replies=replies+1;end
    end
    seam_render dut(.text_osd_page(local_page),.keypad_valid(1'b0),.keypad_data(6'd0),.clk(clk),.rst(rst),.link_up(1'b1),.session_reset(sreset),
        .video_clk(clk),.video_rst(rst),.vs(1'b0),
        .brightness_mode(2'd2),.brightness_level(brightness),.contrast_level(contrast),.saturation_level(saturation),
        .rx_meta_valid(mv),.rx_meta_ready(mr),.rx_required(1'b1),.rx_channel(8'd0),
        .rx_opcode(opcode),.rx_object(32'd1),.rx_offset(offset),.rx_length(length),
        .emergency_reply_valid(reply_valid),.emergency_reply_status(reply_status),
        .emergency_reply_epoch(reply_epoch),.emergency_reply_revision(reply_revision),
        .rx_valid(dv),.rx_ready(dr),.rx_data(data),.rx_last(last),
        .tx_meta_ready(1'b1),.tx_ready(1'b1),.write_req_ack(1'b0),.write_abort_ack(1'b1),
        .write_full(1'b0),.write_sector_ready(1'b1),.write_finish_toggle(1'b0),
        .read_selected_index(2'd0),.read_handoff_toggle(1'b0),
        .transition_ack(1'b0),.transition_done(1'b0),.transition_failed(1'b0),
        .ui_wr_en(we),.ui_commit_toggle(commit),.ui_commit_seen(uiack),
        .audio_packet_ready(1'b1),.audio_feedback(1'b0),.feedback_epoch(32'd0),
        .feedback_position(32'd0),.feedback_flags(3'd0));
    task step;input integer n;begin repeat(n) @(negedge clk);end endtask
    task meta;
        begin mv=1;@(posedge clk);while(!mr) @(posedge clk);@(negedge clk);mv=0;end
    endtask
    task word;input [31:0] value;input final_word;
        begin data=value;last=final_word;dv=1;
            @(posedge clk);while(!dr) @(posedge clk);@(negedge clk);dv=0;end
    endtask
    task snapshot;input [31:0] flags;input [4:0] want;
        begin
            previous_commit=commit;meta;word(flags,0);word(saturation_word,0);
            for(i=0;i<72;i=i+1) word(32'h20202020,i==71);
            wait(commit!=previous_commit);step(10);
            if(local_page !== flags[12]) $fatal(1,"Local page flag not committed");
            if(saturation!==expected_saturation) $fatal(1,"Saturation got %0d expected %0d",saturation,expected_saturation);
            if(contrast!==want || brightness!=5) $fatal(1,"Snapshot controls got=%0d wanted=%0d",contrast,want);
        end
    endtask
    initial begin
        step(4);rst=0;step(4);
        if(contrast!=10 || brightness!=10) $fatal(1,"Reset defaults");
        snapshot(32'h00200501,0);snapshot(32'h00340501,20);
        snapshot(32'h00000501,10); // old sender: extension absent
        snapshot(32'h00140501,10); // value set, presence absent
        snapshot(32'h003f0501,10); // invalid 31
        snapshot(32'h00350501,10); // invalid 21
        snapshot(32'h00271501,7);
        saturation_word=32'h20;expected_saturation=0;snapshot(32'h00271501,7);
        saturation_word=32'h34;expected_saturation=20;snapshot(32'h00271501,7);
        saturation_word=32'h14;expected_saturation=10;snapshot(32'h00271501,7);
        saturation_word=32'h35;expected_saturation=10;snapshot(32'h00271501,7);
        saturation_word=32'h2a;
        previous_commit=commit;meta;word(32'h00271501,1);step(10);
        if(commit!=previous_commit || dut.ui_busy) $fatal(1,"Short flags word stuck UI");
        previous_commit=commit;meta;word(32'h00271501,0);word(32'h20,1);step(10);
        if(commit!=previous_commit || dut.ui_busy) $fatal(1,"Short extension word stuck UI");
        previous_commit=commit;meta;word(32'h00271501,0);word(32'h20,0);word(32'h20202020,1);step(10);
        if(commit!=previous_commit || saturation!=10 || dut.ui_busy) $fatal(1,"Short snapshot committed");
        // Partial new snapshot cannot change committed contrast on disconnect.
        previous_commit=commit;meta;word(32'h00300501,0);word(32'h20202020,0);step(8);
        sreset=1;step(1);sreset=0;step(10);
        if(contrast!=7 || !local_page || commit!=previous_commit) $fatal(1,"Partial snapshot changed controls");
        snapshot(32'h00230501,3);
        if(chars<8*288) $fatal(1,"Missing committed UI characters");
        // The formerly critical header bit belongs to offset[26]. Invalid
        // snapshots must drain without taking ownership of the UI payload.
        chars_before=chars;previous_commit=commit;
        offset=32'h04000000;meta;
        for(i=0;i<74;i=i+1) word(32'hffffffff,i==73);
        step(10);
        if(chars!=chars_before || commit!=previous_commit || contrast!=3)
            $fatal(1,"Invalid UI offset accepted");
        offset=0;length=288;meta;
        for(i=0;i<72;i=i+1) word(32'hffffffff,i==71);
        step(10);
        if(chars!=chars_before || commit!=previous_commit) $fatal(1,"Invalid UI length accepted");
        opcode=`DB_EMERGENCY_STATUS;length=4;offset=32'h040000ff;
        meta;word(32'h12345678,1);step(10);
        if(replies!=0) $fatal(1,"Invalid emergency offset accepted");
        offset=255;length=8;meta;word(0,0);word(0,1);step(10);
        if(replies!=0) $fatal(1,"Invalid emergency length accepted");
        length=4;meta;word(32'h12345678,1);step(10);
        if(replies!=1 || reply_status!=255 || reply_epoch!=32'h12345678 || reply_revision!=1)
            $fatal(1,"Valid emergency status not delivered");
        opcode=`DB_UI_SNAPSHOT;offset=0;length=296;snapshot(32'h00270501,7);
        $display("*** PASS *** UI snapshots and pre-admission payload qualification: invalid offset/length drain, valid emergency status, UI recovery, partial disconnect");$finish;
    end
    initial begin #100000;$fatal(1,"Snapshot watchdog");end
endmodule
