`include "../pkg/text_osd_model.vh"
// Copy into the invisible bank, then atomically commit bank + metadata at VS.
// A four-phase request/ack handshake prevents reuse before consumption.
module text_osd_view_cdc(
    input wire clk,rst,input wire [`TEXT_OSD_META_W-1:0] metadata,input wire [31:0] revision,
    output wire [7:0] edit_addr,input wire [7:0] edit_data,
    input wire video_clk,video_rst,vs,input wire [7:0] text_addr,
    output wire [7:0] text_data,output wire [`TEXT_OSD_META_W-1:0] view,
    output reg video_commit
);
    localparam IDLE=0,READ=1,WRITE=2,CHECK=3,WAIT_ACK=4,WAIT_LOW=5;
    reg [2:0] state;
    reg [8:0] index;
    reg [`TEXT_OSD_META_W-1:0] mailbox;
    reg [31:0] copy_revision,last_revision;
    reg bank,front_bank,request,ack,dirty,alive,alive_d,vs_d;
    (* async_reg="true" *) reg ack1,ack2,alive1,alive2,req1,req2,front1,front2;
    // Prime byte zero in READ, then prefetch the next word while writing the
    // current word. The copy streams one byte per clock after the first read.
    assign edit_addr=(state==WRITE && index<`TEXT_OSD_MAX_LEN) ? index[7:0]+8'd1:index[7:0];
    wire [7:0] copy_byte=index<mailbox[`TEXT_OSD_VIEW_LEN] ? edit_data:8'd0;
    wire [7:0] ram_data;
    text_osd_ram u_display(.wr_clk(clk),.wr_en(state==WRITE && index<`TEXT_OSD_MAX_LEN && alive2 && !rst),
        .wr_addr({bank,index[7:0]}),.wr_data(copy_byte),.rd_clk(video_clk),
        .rd_addr({front_bank,text_addr}),.rd_data(ram_data));
    reg in_range;
    always @(posedge video_clk) in_range<=!video_rst && {1'b0,text_addr}<view[`TEXT_OSD_VIEW_LEN];
    assign text_data=in_range ? ram_data:8'd0;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;index<=0;mailbox<=0;copy_revision<=0;last_revision<=0;
            bank<=1;request<=0;dirty<=1;ack1<=0;ack2<=0;
            alive1<=0;alive2<=0;alive_d<=0;front1<=0;front2<=0;
        end else begin
            ack1<=ack;ack2<=ack1;alive1<=alive;alive2<=alive1;alive_d<=alive2;
            front1<=front_bank;front2<=front1;
            if(alive2!=alive_d) dirty<=1;
            if(!alive2) begin state<=IDLE;request<=0;dirty<=1;end
            else case(state)
                IDLE:if(!ack2 && !request && (dirty || revision!=last_revision)) begin
                    mailbox<=metadata;copy_revision<=revision;bank<=~front2;index<=0;state<=READ;
                end
                READ:state<=WRITE;
                WRITE:if(index==`TEXT_OSD_MAX_LEN) state<=CHECK;
                      else index<=index+1'b1;
                CHECK:if(revision!=copy_revision) state<=IDLE;
                      else begin request<=1;dirty<=0;last_revision<=copy_revision;state<=WAIT_ACK;end
                WAIT_ACK:if(ack2) begin request<=0;state<=WAIT_LOW;end
                WAIT_LOW:if(!ack2) state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
    reg [`TEXT_OSD_META_W-1:0] view_q;
    assign view=view_q;
    always @(posedge video_clk or posedge video_rst) begin
        if(video_rst) begin req1<=0;req2<=0;ack<=0;vs_d<=0;alive<=0;front_bank<=0;view_q<=0;video_commit<=0;end
        else begin
            alive<=1;req1<=request;req2<=req1;vs_d<=vs;video_commit<=0;
            if(!req2) ack<=0;
            else if(vs && !vs_d && !ack) begin view_q<=mailbox;front_bank<=bank;ack<=1;video_commit<=1;end
        end
    end
endmodule
