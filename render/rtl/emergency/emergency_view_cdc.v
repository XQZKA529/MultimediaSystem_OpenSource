// Four-phase mailbox and one serial converter for all eighteen calendar fields.
module emergency_view_cdc(
    input wire clk,rst,input wire [1:0] mode,
    input wire [2:0] sources,input wire [8:0] groups,
    input wire [98:0] timestamps,
    input wire video_clk,video_rst,vs,
    output reg enable,output reg [2:0] video_sources,output reg [8:0] video_groups,
    output reg [143:0] video_timestamps
);
    reg [11:0] last_view;
    reg [12:0] captured;
    // Month/day/hour/minute/second tens have known binary field bounds.
    // Omit their constant high BCD bits from both sides of the mailbox.
    reg [116:0] digits;
    function [47:0] expand_time;
        input [38:0] t;
        begin expand_time={t[38:31],3'd0,t[30:26],2'd0,t[25:20],
            2'd0,t[19:14],1'b0,t[13:7],1'b0,t[6:0]};end
    endfunction
    wire [156:0] mailbox={captured,expand_time(digits[38:0]),
        expand_time(digits[77:39]),expand_time(digits[116:78])};
    wire [11:0] view=sources!=0 ? {sources,groups}:last_view;
    wire [12:0] desired=(mode!=0 || sources!=0) ? {1'b1,view}:13'd0;
    reg [1:0] state;
        reg [1:0] source_index;
    reg [2:0] calendar_field;
    reg [3:0] bit_count;
    reg [7:0] binary,bcd;
    reg request,ack,alive,dirty;
    (* async_reg="true" *) reg ack1,ack2,req1,req2,alive1,alive2;
    wire [32:0] selected_time=source_index==0 ? timestamps[32:0]:
        source_index==1 ? timestamps[65:33]:timestamps[98:66];
    reg [7:0] selected_field,correction;
    always @(*) begin
        case(calendar_field)
            0:selected_field={1'b0,selected_time[32:26]};
            1:selected_field={4'd0,selected_time[25:22]};
            2:selected_field={3'd0,selected_time[21:17]};
            3:selected_field={3'd0,selected_time[16:12]};
            4:selected_field={2'd0,selected_time[11:6]};
            default:selected_field={2'd0,selected_time[5:0]};
        endcase
        correction=bcd;
        if(bcd[3:0]>=5) correction[3:0]=bcd[3:0]+4'd3;
        if(bcd[7:4]>=5) correction[7:4]=bcd[7:4]+4'd3;
    end
    wire [7:0] next_bcd={correction[6:0],binary[7]};
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            last_view<=0;captured<=0;state<=0;
            source_index<=2;calendar_field<=0;bit_count<=0;binary<=0;bcd<=0;
            request<=0;ack1<=0;ack2<=0;alive1<=0;alive2<=0;dirty<=1;
        end else begin
            ack1<=ack;ack2<=ack1;alive1<=alive;alive2<=alive1;
            // A source can clear and retrigger while the mailbox waits for VS.
            // Remember even a transient identity change so a new timestamp is
            // republished when the final source/group identity returns to itself.
            if(request && desired!=captured) dirty<=1;
            if(sources!=0) last_view<={sources,groups};
            else if(mode==0) last_view<=0;
            if(!alive2) begin request<=0;state<=0;dirty<=1;end
            // Each timestamp update accompanies a source-set change on the same
            // edge. Checking that identity EVERY cycle makes the input slots
            // a stable conversion source, avoiding a redundant 99-bit copy.
            else if(!request && state!=0 && desired!=captured) state<=0;
            else case(state)
                0:if(!request && !ack2 && (dirty || desired!=captured)) begin
                    captured<=desired;source_index<=2;calendar_field<=0;state<=1;
                end
                1:begin binary<=selected_field;bcd<=0;bit_count<=0;state<=2;end
                2:begin
                    binary<={binary[6:0],1'b0};bcd<=next_bcd;bit_count<=bit_count+1'b1;
                    if(bit_count==7) begin
                        if(source_index==0 && calendar_field==5) state<=3;
                        else begin
                            state<=1;
                            if(calendar_field==5) begin calendar_field<=0;source_index<=source_index-1'b1;end
                            else calendar_field<=calendar_field+1'b1;
                        end
                    end
                end
                3:if(!request) begin
                    // Reject a stale conversion; never mix source generations.
                    if(desired!=captured) state<=0;
                    else begin request<=1;dirty<=0;end
                end else if(ack2) begin request<=0;state<=0;end
            endcase
        end
    end
    // Payload validity is qualified by the completed mailbox handshake.
    // Reset the control, not these overwritten-before-publication data flops;
    // this avoids unnecessary SR packing constraints in a nearly full device.
    always @(posedge clk) begin
        if(!rst && alive2 && state==2 && bit_count==7 && desired==captured) begin
                        if(source_index==0) case(calendar_field)
                            0:digits[109 +: 8]<=next_bcd[7:0];
                            1:digits[104 +: 5]<=next_bcd[4:0];
                            2:digits[98 +: 6]<=next_bcd[5:0];
                            3:digits[92 +: 6]<=next_bcd[5:0];
                            4:digits[85 +: 7]<=next_bcd[6:0];
                            5:digits[78 +: 7]<=next_bcd[6:0];
                        endcase
                        if(source_index==1) case(calendar_field)
                            0:digits[70 +: 8]<=next_bcd[7:0];
                            1:digits[65 +: 5]<=next_bcd[4:0];
                            2:digits[59 +: 6]<=next_bcd[5:0];
                            3:digits[53 +: 6]<=next_bcd[5:0];
                            4:digits[46 +: 7]<=next_bcd[6:0];
                            5:digits[39 +: 7]<=next_bcd[6:0];
                        endcase
                        if(source_index==2) case(calendar_field)
                            0:digits[31 +: 8]<=next_bcd[7:0];
                            1:digits[26 +: 5]<=next_bcd[4:0];
                            2:digits[20 +: 6]<=next_bcd[5:0];
                            3:digits[14 +: 6]<=next_bcd[5:0];
                            4:digits[7 +: 7]<=next_bcd[6:0];
                            5:digits[0 +: 7]<=next_bcd[6:0];
                        endcase
        end
    end
    always @(posedge video_clk) begin
        if(!video_rst && req2 && !ack && vs) video_timestamps<=mailbox[143:0];
    end
    always @(posedge video_clk or posedge video_rst) begin
        if(video_rst) begin
            req1<=0;req2<=0;ack<=0;alive<=0;enable<=0;
            video_sources<=0;video_groups<=0;
        end else begin
            alive<=1;req1<=request;req2<=req1;
            if(!req2) ack<=0;
            // The complete vertical-sync window is safe. This also accepts
            // normal-mode release after the controller observes VS rising,
            // so audio and picture restore in the SAME following frame.
            else if(vs && !ack) begin
                {enable,video_sources,video_groups}<=mailbox[156:144];ack<=1;
            end
        end
    end
endmodule
