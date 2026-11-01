// Latest-value mailbox, four-phase handshake, atomic commit at VS.
// Video reset resets only the transport; the bus-domain user value survives.
module volume_view_cdc(
    input wire clk,rst,cfg_valid,input wire [4:0] cfg_level,input wire cfg_hint,cancel,
    input wire video_clk,video_rst,vs,
    output reg [4:0] level,output reg hint_event
);
    reg [4:0] latest_level;
    reg latest_hint;reg [31:0] serial;
    always @(posedge clk or posedge rst) begin
        if(rst) begin latest_level<=20;latest_hint<=0;serial<=0;end
        else begin
            if(cfg_valid) begin latest_level<=cfg_level;latest_hint<=cfg_hint;serial<=serial+1'b1;end
            if(cancel || video_rst) latest_hint<=0;
        end
    end
    wire transport_rst=rst || video_rst;
    reg [1:0] state;
    reg request,ack,replay;
    reg [5:0] mailbox;
    reg [31:0] sent_serial;
    (* async_reg="true" *) reg ack1,ack2,req1,req2;
    (* async_reg="true" *) reg cancel1,cancel2;
    reg vs_d;
    always @(posedge clk or posedge transport_rst) begin
        if(transport_rst) begin state<=0;request<=0;replay<=1;mailbox<=20;sent_serial<=0;ack1<=0;ack2<=0;end
        else begin
            ack1<=ack;ack2<=ack1;
            case(state)
                0:if(!cfg_valid && !ack2 && (replay || serial!=sent_serial)) begin
                    mailbox<={(!replay && !cancel && latest_hint),latest_level};
                    sent_serial<=serial;replay<=0;state<=1;
                end
                1:begin request<=1;state<=2;end
                2:if(ack2) begin request<=0;state<=3;end
                3:if(!ack2) state<=0;
            endcase
        end
    end
    always @(posedge video_clk or posedge transport_rst) begin
        if(transport_rst) begin req1<=0;req2<=0;ack<=0;vs_d<=0;cancel1<=1;cancel2<=1;level<=20;hint_event<=0;end
        else begin
            cancel1<=cancel;cancel2<=cancel1;req1<=request;req2<=req1;vs_d<=vs;hint_event<=0;
            if(!req2) ack<=0;
            else if(vs && !vs_d && !ack) begin level<=mailbox[4:0];hint_event<=mailbox[5] && !cancel2;ack<=1;end
        end
    end
endmodule
