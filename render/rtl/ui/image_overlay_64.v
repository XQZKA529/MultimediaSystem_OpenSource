// Fixed 64x64 RGB565 image store and top-right scanout overlay.
// Two 2048x16 BRAM32K banks hold the low/high half of each 32-bit input word.
module image_overlay_64(
    input wire wr_clk, input wire wr_en, input wire [10:0] wr_addr,
    input wire [31:0] wr_data,
    input wire video_clk, input wire video_rst,
    input wire hs_in,vs_in,de_in, input wire [23:0] rgb_in,
    input wire enable_in,input wire prepare_toggle,commit_toggle,
    output reg prepare_ack,commit_ack,
    output reg hs_out,vs_out,de_out, output wire [23:0] rgb_out
);
    wire [10:0] rd_word;
`ifdef DB_BEHAVIORAL_RAM
    reg [15:0] lo_mem[0:2047],hi_mem[0:2047];
    reg [15:0] lo_q_r,hi_q_r;
    wire [15:0] lo_q=lo_q_r,hi_q=hi_q_r;
    always @(posedge wr_clk) if(wr_en) begin lo_mem[wr_addr]<=wr_data[15:0];hi_mem[wr_addr]<=wr_data[31:16];end
    always @(posedge video_clk) begin lo_q_r<=lo_mem[rd_word];hi_q_r<=hi_mem[rd_word];end
`else
    wire [15:0] lo_q,hi_q;
`endif
    wire [10:0] x_offset;
    wire [10:0] y_offset;
    reg [10:0] x_count,y_count;
    reg de_d,vs_d;
    reg half_select_d;
    reg inside_d;
    reg [23:0] rgb_d;
    wire [23:0] pixel_rgb;
    reg enabled_frame,enable_vs_d;
    (* async_reg="true" *) reg [2:0] prepare_sync,commit_sync;
    (* async_reg="true" *) reg [1:0] show_sync;
    reg show_frame;
    wire inside_window = de_in && x_count>=11'd1200 && x_count<11'd1264 &&
                         y_count>=11'd16 && y_count<11'd80;
    assign x_offset=x_count-11'd1200;
    assign y_offset=y_count-11'd16;
    assign rd_word={y_offset[5:0],x_offset[5:1]};
    assign pixel_rgb= half_select_d ? {hi_q[15:11],hi_q[15:13],hi_q[10:5],hi_q[10:9],hi_q[4:0],hi_q[4:2]} :
                                     {lo_q[15:11],lo_q[15:13],lo_q[10:5],lo_q[10:9],lo_q[4:0],lo_q[4:2]};
    assign rgb_out=inside_d ? pixel_rgb:rgb_d;
`ifndef DB_BEHAVIORAL_RAM
    EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG")) u_overlay_lo(
        .clka(wr_clk),.addra(wr_addr),.dia(wr_data[15:0]),.doa(),.bytea(1'b0),.bytewea(1'b0),
        .csa(1'b1),.wea(wr_en),.rsta(1'b0),.ocea(1'b1),
        .clkb(video_clk),.addrb(rd_word),.dib(16'd0),.dob(lo_q),.byteb(1'b0),.byteweb(1'b0),
        .csb(1'b1),.web(1'b0),.rstb(1'b0),.oceb(1'b1));
    EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG")) u_overlay_hi(
        .clka(wr_clk),.addra(wr_addr),.dia(wr_data[31:16]),.doa(),.bytea(1'b0),.bytewea(1'b0),
        .csa(1'b1),.wea(wr_en),.rsta(1'b0),.ocea(1'b1),
        .clkb(video_clk),.addrb(rd_word),.dib(16'd0),.dob(hi_q),.byteb(1'b0),.byteweb(1'b0),
        .csb(1'b1),.web(1'b0),.rstb(1'b0),.oceb(1'b1));
`endif
    always @(posedge video_clk or posedge video_rst) begin
        if(video_rst) begin
            x_count<=0;y_count<=0;de_d<=0;vs_d<=0;inside_d<=0;half_select_d<=0;
            prepare_sync<=0;commit_sync<=0;prepare_ack<=0;commit_ack<=0;
            show_sync<=0;show_frame<=0;enabled_frame<=0;enable_vs_d<=0;
            rgb_d<=0;hs_out<=0;vs_out<=0;de_out<=0;
        end else begin
            prepare_sync<={prepare_sync[1:0],prepare_toggle};
            commit_sync<={commit_sync[1:0],commit_toggle};
            show_sync<={show_sync[0],enable_in};
            enable_vs_d<=vs_in;
            if(vs_in && !enable_vs_d) begin
                show_frame<=show_sync[1];
                if(prepare_sync[2]!=prepare_ack) begin
                    enabled_frame<=0;prepare_ack<=prepare_sync[2];
                    // Hiding cancels an old commit before it can enable stale RAM.
                    commit_ack<=commit_sync[2];
                end
                else if(commit_sync[2]!=commit_ack) begin enabled_frame<=1;commit_ack<=commit_sync[2];end
            end
            de_d<=de_in;vs_d<=vs_in;inside_d<=inside_window && enabled_frame && show_frame;half_select_d<=x_count[0];rgb_d<=rgb_in;
            hs_out<=hs_in;vs_out<=vs_in;de_out<=de_in;
            if(de_in) begin
                if(x_count==11'd1279) x_count<=0; else x_count<=x_count+1'b1;
            end
            if(de_d && !de_in) begin
                x_count<=0;
                if(y_count==11'd719) y_count<=0; else y_count<=y_count+1'b1;
            end
            if(vs_in && !vs_d) begin x_count<=0;y_count<=0;end
        end
    end
endmodule
