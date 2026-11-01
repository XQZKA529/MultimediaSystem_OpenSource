`timescale 1ns/1ps
`include "pkg/board_link.vh"
module tb_media_source;
    reg clk=0,rst=1,req=0,iwv=0,ok=0,failed=0,allow=1;
    always #5 clk=~clk;
    reg [31:0] iw=0;
    wire ack,finish,burst,overflow,mv,dv,last;wire [7:0] ch,op;wire [31:0] obj,off,d;wire [15:0] len;
    reg rmv=0;reg [7:0] rop=0;reg [31:0] robj=0;
    wire rmr,kp_valid;wire [5:0] kp_data;reg [31:0] roff=0;integer kp_count=0;
    reg uw=0,uc=0;reg [8:0] ua=0;reg [7:0] ud=0;
    seam_media #(.FRAME_WORDS(64)) dut(.saturation_level(5'd10),.volume_level(5'd20),.volume_changed(1'b0),.volume_hint(1'b0),.volume_revision(32'd0),.keypad_valid(kp_valid),.keypad_data(kp_data),.contrast_level(5'd10),
        .subtitle_valid(1'b0),.ui_page(4'd0),.transition_mode(2'd0),
        .clk(clk),.rst(rst),.link_up(1'b1),.session_reset(1'b0),
        .image_req(req),.image_ack(ack),.image_finish_toggle(finish),.image_word_valid(iwv),.image_word(iw),
        .image_source_ok(ok),.image_source_failed(failed),.image_burst_ready(burst),
        .pcm_push(1'b0),.pcm(32'd0),.pcm_clear(1'b0),.pcm_eof(1'b0),.pcm_total(32'd0),.pcm_base(32'd0),
        .pcm_stream_toggle(1'b0),.paused(1'b0),.seek_request(1'b0),
        .brightness_level(4'd10),.ui_wr_en(uw),.ui_wr_addr(ua),.ui_wr_data(ud),.text_osd_page(1'b0),.ui_active(1'b1),.ui_cursor_en(1'b1),.ui_cursor_row(4'd3),.ui_commit_toggle(uc),.diag(4'd15),
        .rx_meta_valid(rmv),.rx_meta_ready(rmr),.rx_required(1'b1),.rx_channel(8'd0),.rx_opcode(rop),.rx_object(robj),.rx_offset(roff),.rx_length(16'd0),
        .rx_valid(1'b0),.rx_data(32'd0),.rx_last(1'b0),
        .tx_meta_valid(mv),.tx_meta_ready(allow),.tx_channel(ch),.tx_opcode(op),.tx_object(obj),.tx_offset(off),.tx_length(len),
        .tx_valid(dv),.tx_ready(allow),.tx_data(d),.tx_last(last),.overflow(overflow));
    `include "../rtl/link/db_crc.vh"
    function [31:0] crcw;input [31:0] c,w;
        begin crcw=db_crc_byte(db_crc_byte(db_crc_byte(db_crc_byte(c,w[31:24]),w[23:16]),w[15:8]),w[7:0]);end
    endfunction
    reg [7:0] payload_op;
    reg [31:0] crc=32'hffffffff;
    integer words=0,ends=0,uis=0,uiword=0,begins=0,acks=0,abort_count=0,j;
    reg [31:0] image_id;
    always @(posedge clk) if(!rst) begin
        if(kp_valid) begin kp_count=kp_count+1;if(kp_data!=4) $fatal(1,"keyboard metadata decode");end
        if(ack) acks=acks+1;
        if(mv && allow) begin
            payload_op=op;
            if(op==`DB_IMG_BEGIN) begin image_id=obj;begins=begins+1;end
            if(op==`DB_IMG_ABORT) abort_count=abort_count+1;
            if(op==`DB_IMG_DATA && off!=words*4) $fatal(1,"image offset");
            if(op==`DB_UI_SNAPSHOT) begin uiword=0;uis=uis+1;end
        end
        if(dv && allow) begin
            if(payload_op==`DB_IMG_DATA) begin
                if(d!==words) $fatal(1,"image payload order");crc=crcw(crc,d);words=words+1;
            end
            if(payload_op==`DB_IMG_END) begin
                if(words!=64 || d!==~crc || !ok) $fatal(1,"early/wrong END");ends=ends+1;
            end
            if(payload_op==`DB_UI_SNAPSHOT) begin
                if(uiword==0) begin if(d!=32'ha12a0a33) $fatal(1,"UI flags");end
                else if(uiword==1) begin if(d!==32'h0000002a) $fatal(1,"UI saturation word");end
                else for(j=0;j<4;j=j+1) if(d[31-j*8 -:8]!==((uiword-2)*4+j)%256) $fatal(1,"UI snapshot char order");
                uiword=uiword+1;
                if(last && uiword!=74) $fatal(1,"UI length");
            end
        end
        if(overflow) $fatal(1,"source FIFO overflow");
    end
    task reply;input [7:0] code;
        begin @(negedge clk);rop=code;robj=image_id;rmv=1;@(posedge clk);while(!rmr) @(posedge clk);@(negedge clk);rmv=0;end
    endtask
    task keyevent;input [31:0] offset,object;begin
      @(negedge clk);rop=`DB_KEYPAD_EVENT;robj=object;roff=offset;rmv=1;
      @(posedge clk);while(!rmr) @(posedge clk);@(negedge clk);rmv=0;repeat(4) @(negedge clk);
    end endtask
    integer i;
    initial begin
        #100;rst=0;repeat(10) @(posedge clk);keyevent(4,0);keyevent(4,1);keyevent(68,0);
        if(kp_count!=1) $fatal(1,"invalid/duplicate keypad event");roff=0;@(negedge clk);req=1;
        wait(begins==1);reply(`DB_IMG_READY);wait(acks==1);
        repeat(10) @(posedge clk);if(begins!=1) $fatal(1,"held request created another image");
        @(negedge clk);req=0;allow=0;repeat(5) @(posedge clk);
        for(i=0;i<64;i=i+1) begin @(negedge clk);iwv=1;iw=i;end
        @(negedge clk);iwv=0;repeat(30) @(posedge clk);if(ends || finish) $fatal(1,"completion without source success");
        @(negedge clk);allow=1;wait(words==64);repeat(10) @(posedge clk);if(ends) $fatal(1,"END before source success");
        @(negedge clk);ok=1;wait(ends==1);repeat(20) @(posedge clk);if(finish) $fatal(1,"packet ACK treated as PRESENTED");
        reply(`DB_IMG_PRESENTED);wait(finish);ok=0;
        for(i=0;i<288;i=i+1) begin @(negedge clk);uw=1;ua=i;ud=i;end
        @(negedge clk);uw=0;uc=~uc;wait(uis==1);wait(uiword==74);
        @(negedge clk);req=1;wait(begins==2);reply(`DB_IMG_READY);wait(acks==2);@(negedge clk);req=0;failed=1;
        @(negedge clk);failed=0;wait(abort_count==1);
        $display("*** PASS *** media: held request, burst buffering, source success, PRESENTED, complete UI, abort");$finish;
    end
    initial begin #500000;$display("DEBUG begins=%0d acks=%0d words=%0d ends=%0d ui=%0d state=%0d kind=%0d",begins,acks,words,ends,uis,dut.tx_state,dut.tx_kind);$fatal(1,"media source timeout");end
endmodule
