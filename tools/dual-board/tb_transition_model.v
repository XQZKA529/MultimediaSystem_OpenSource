`timescale 1ns/1ps
// Real transition/alpha controllers; only the SDRAM reader handoff is modeled.
module tb_transition_model(input clk,rst,vs,req,input [1:0] new_idx,cur_idx,
    output ack,done,failed,output reg [1:0] selected,output reg handoff);
    (* async_reg="true" *) reg [2:0] req_sync;
    wire active,lane1,start,valid,ab,ad;
    wire [1:0] display_idx,laneidx;wire [8:0] alpha;
    reg vs_d=0,reader_dual=0;integer delay_count=0;
    always @(posedge clk) begin
        if(rst) begin req_sync<=0;vs_d<=0;reader_dual<=0;selected<=0;handoff<=0;delay_count<=0;end
        else begin
            req_sync<={req_sync[1:0],req};vs_d<=vs;
            if(vs && !vs_d) delay_count<=8;
            else if(delay_count!=0) begin
                delay_count<=delay_count-1;
                if(delay_count==1) begin selected<=display_idx;reader_dual<=lane1;handoff<=~handoff;end
            end
        end
    end
    mix_alpha_ctrl ramp(.clk(clk),.rst(rst),.vs(vs),.start(start),.fail(1'b0),.alpha(alpha),.busy(ab),.done(ad));
    mix_transition_ctrl ctrl(.clk(clk),.rst(rst),.vs(vs),.transition_req(req_sync[2]),
        .req_new_idx(new_idx),.req_cur_idx(cur_idx),.req_ack(ack),
        .mix_active(active),.lane1_en(lane1),.lane1_idx(laneidx),.alpha_start(start),
        .alpha(alpha),.alpha_busy(ab),.alpha_done(ad),.mix_fail_in(1'b0),
        .read_handoff(handoff),.read_index(selected),.read_dual_active(reader_dual),
        .disp_index_out(display_idx),.disp_valid_out(valid),.transition_done(done),.transition_failed(failed));
endmodule
