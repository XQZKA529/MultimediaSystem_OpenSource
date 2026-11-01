// Full-frame dual-buffer reader; burst ownership retained until actual returns drain.
module frame_fifo_read_dual
#
(
	parameter MEM_DATA_BITS     = 32,
	parameter ADDR_BITS         = 21,
	parameter BURST_BITS        = 9,
	parameter BURST_SIZE        = 256,
	parameter FIFO_DEPTH        = 512,
	parameter LANES             = 2,
	parameter LINE_WORDS        = 960,
	parameter FRAME_HEIGHT      = 720,
	parameter SPLIT_LINE        = 360          // lane1 起始行
)
(
	input                            rst,
	input                            mem_clk,
	input                            Sdr_init_done,
	input                            Sdr_init_ref_vld,
	input                            Sdr_busy,

	// 读突发字口
	output reg                       App_rd_en,
	output reg[ADDR_BITS - 1:0]      App_rd_addr,
	input                            Sdr_rd_en,

	// 帧请求（video_clk 域）
	input                            read_req,
	output reg                       read_req_ack,
	output reg                       read_finish,
	output reg [1:0]                 read_selected_index,
	output reg                       read_handoff_toggle,

	// lane0 基地址选择（read_addr_0..3 + index），lane1 基地址与索引
	input[ADDR_BITS - 1:0]           read_addr_0,
	input[ADDR_BITS - 1:0]           read_addr_1,
	input[ADDR_BITS - 1:0]           read_addr_2,
	input[ADDR_BITS - 1:0]           read_addr_3,
	input[1:0]                       read_addr_index,
	input[ADDR_BITS - 1:0]           read_len,

	input[ADDR_BITS - 1:0]           read_addr_lane1,
	input[1:0]                       read_index_lane1,
	input                            read_lane1_en,
	input                            read_slide_en,
	input[9:0]                       read_slide_rows,

	// 写侧互斥：写突发在途时不启动读突发；本模块读突发在途时写侧
	//（frame_fifo_write）经 App_rd_busy 自行退让，二者合起来构成突发级互斥，
	// 不需要额外握手。
	input                            App_wr_busy,

	// 两级 FIFO 写侧口
	output                           fifo_aclr0,
	output                           fifo_aclr1,
	output                           lane0_lane1_sel,
	input[9:0]                       wrusedw0,
	input[9:0]                       wrusedw1,

	// 双路就绪：本帧所需的两路读 FIFO 均已备妥（供 video 侧提前离开消隐）
	output                           read_ready,
	// 写突发许可：0 = 读通路有迫切的补 FIFO 需求，写侧暂缓发起新的写突发。
	// 写侧（frame_fifo_write.into_burst）必须把它并进准入条件，避免写优先
	// 逻辑在长时间写回期间饿死读通路。
	output                           read_urgent,

	output                           read_dual_active,
	output                           O_rd_busy
);
    localparam S_IDLE=0, S_ACK=1, S_PICK=2, S_BURST=3, S_DRAIN=4, S_END=5, S_ADMIT=6;
    // The fixed 720p frame has 960 packed SDRAM words per row. Express row
    // multiplication as shifts/subtraction so this path cannot consume DSPs.
    function [ADDR_BITS-1:0] slide_word_offset;
        input [9:0] rows;
        reg [ADDR_BITS-1:0] extended_rows;
        begin
            extended_rows={{(ADDR_BITS-10){1'b0}},rows};
            slide_word_offset=(extended_rows<<10)-(extended_rows<<6);
        end
    endfunction
    reg [2:0] state;
    (* async_reg="true" *) reg [2:0] req_sync;
    (* async_reg="true" *) reg [1:0] slide_sync;
    reg [9:0] slide_rows_d0,slide_rows_d1;
    reg [1:0] idx_d0,idx_d1;
    reg dual_d0,dual_d1;
    reg [ADDR_BITS-1:0] len_d0,len_d1,base1_d0,base1_d1;
    reg [ADDR_BITS-1:0] next0,next1,left0,left1,segment_left0,slide_base1;
    reg slide_second0;
    reg dual_active,cur_lane,last_lane;
    reg [BURST_BITS:0] target,issued,returned;
    reg clear_fifos;
    wire rq=req_sync[2];
    wire need0=left0!=0;
    wire need1=dual_active && left1!=0;
    // Vendor FIFO reserves one entry. Reserve the entire in-flight burst.
    wire space0=wrusedw0 < FIFO_DEPTH-BURST_SIZE;
    wire space1=wrusedw1 < FIFO_DEPTH-BURST_SIZE;
    wire can0=need0 && space0;
    wire can1=need1 && space1;
    wire pick1=can1 && (!can0 || wrusedw1<wrusedw0 ||
                       (wrusedw1==wrusedw0 && !last_lane));
    wire [ADDR_BITS-1:0] remaining=cur_lane ? left1:((slide_sync[1]===1'b1) ? segment_left0:left0);
    wire [BURST_BITS:0] burst_len=remaining<BURST_SIZE ? remaining[BURST_BITS:0]:BURST_SIZE;
    // Sdr_busy qualifies burst admission, not individual words of an admitted
    // streaming burst. The vendor controller asserts it while servicing reads.
    assign O_rd_busy=state==S_BURST || state==S_DRAIN;
    assign read_dual_active=dual_active;
    assign lane0_lane1_sel=cur_lane;
    assign fifo_aclr0=rst || clear_fifos;
    assign fifo_aclr1=rst || clear_fifos;
    assign read_ready=state!=S_ACK && wrusedw0>=BURST_SIZE &&
                      (!dual_active || wrusedw1>=BURST_SIZE);
    // Once the final burst is buffered it is safe to write during scanout tail.
    assign read_urgent=rq || O_rd_busy || dual_active ||
                       (need0 && wrusedw0<BURST_SIZE);
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            req_sync<=0;slide_sync<=0;slide_rows_d0<=0;slide_rows_d1<=0;idx_d0<=0;idx_d1<=0;dual_d0<=0;dual_d1<=0;
            len_d0<=0;len_d1<=0;base1_d0<=0;base1_d1<=0;
        end else begin
            req_sync<={req_sync[1:0],read_req};
            slide_sync<={slide_sync[0],read_slide_en};
            slide_rows_d0<=read_slide_rows;slide_rows_d1<=slide_rows_d0;
            idx_d0<=read_addr_index;idx_d1<=idx_d0;
            dual_d0<=read_lane1_en;dual_d1<=dual_d0;
            len_d0<=read_len;len_d1<=len_d0;
            base1_d0<=read_addr_lane1;base1_d1<=base1_d0;
        end
    end
    reg [ADDR_BITS-1:0] base0;
    always @(*) case(idx_d1)
        0:base0=read_addr_0;1:base0=read_addr_1;
        2:base0=read_addr_2;default:base0=read_addr_3;
    endcase
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            state<=S_IDLE;read_req_ack<=0;read_finish<=0;clear_fifos<=0;
            read_selected_index<=0;read_handoff_toggle<=0;
            next0<=0;next1<=0;left0<=0;left1<=0;segment_left0<=0;slide_base1<=0;slide_second0<=0;dual_active<=0;
            cur_lane<=0;last_lane<=1;target<=0;issued<=0;returned<=0;App_rd_addr<=0;
            App_rd_en<=0;
        end else begin
            read_finish<=0;
            if(Sdr_rd_en && O_rd_busy) returned<=returned+1'b1;
            case(state)
                S_IDLE:if(rq && Sdr_init_done && !App_wr_busy) state<=S_ACK;
                S_ACK:begin
                    if(!read_req_ack) begin
                        read_selected_index<=idx_d1;read_handoff_toggle<=~read_handoff_toggle;
                        next0<=base0;next1<=base1_d1;
                        // Crossfade needs a COMPLETE frame from EACH buffer.
                        left0<=len_d1;left1<=dual_d1 ? len_d1:0;
                        slide_base1<=base1_d1;slide_second0<=0;segment_left0<=len_d1;
                        if(slide_sync[1]===1'b1) begin
                            if(slide_rows_d1==0) begin
                                next0<=base0;segment_left0<=len_d1;
                            end else if(slide_rows_d1>=FRAME_HEIGHT) begin
                                next0<=base1_d1;segment_left0<=len_d1;slide_second0<=1;
                            end else begin
                                next0<=base0+slide_word_offset(FRAME_HEIGHT-slide_rows_d1);
                                segment_left0<=slide_word_offset(FRAME_HEIGHT-slide_rows_d1);
                            end
                        end
                        dual_active<=dual_d1;last_lane<=1;
                    end
                    read_req_ack<=1;clear_fifos<=1;
                    if(!rq) begin
                        read_req_ack<=0;clear_fifos<=0;state<=S_PICK;
                    end
                end
                S_PICK:begin
                    // A new video frame may abandon an underfilled old frame,
                    // but only here, after the preceding burst has drained.
                    if(rq && !App_wr_busy) state<=S_ACK;
                    else if(!need0 && !need1) state<=S_END;
                    else if(!App_wr_busy && !Sdr_busy && !Sdr_init_ref_vld && (can0 || can1)) begin
                        // FIFO arbitration must not drive address/counter
                        // enables through the burst setup mux in the same cycle.
                        cur_lane<=pick1;state<=S_ADMIT;
                    end
                end
                S_ADMIT:begin
                    // Only this reader fills the FIFOs. Between drained bursts
                    // occupancy can only fall, so the selected credit stays safe.
                    // Recheck shared SDRAM ownership before starting the burst.
                    if(rq && !App_wr_busy) state<=S_ACK;
                    else if(!App_wr_busy && !Sdr_busy && !Sdr_init_ref_vld) begin
                        App_rd_addr<=cur_lane ? next1:next0;
                        target<=burst_len;issued<=0;returned<=0;App_rd_en<=1;state<=S_BURST;
                    end
                end
                S_BURST:begin
                    if(App_rd_en) begin
                        issued<=issued+1'b1;App_rd_addr<=App_rd_addr+1'b1;
                        if(issued+1'b1==target) begin App_rd_en<=0;state<=S_DRAIN;end
                    end
                end
                S_DRAIN:if(returned==target) begin
                    if(cur_lane) begin next1<=App_rd_addr;left1<=left1-target;end
                    else begin
                        left0<=left0-target;
                        if(slide_sync[1]===1'b1 && !slide_second0 && segment_left0==target) begin
                            next0<=slide_base1;segment_left0<=slide_word_offset(slide_rows_d1);slide_second0<=1;
                        end else begin
                            next0<=App_rd_addr;
                            // A non-final burst always transfers BURST_SIZE
                            // words. Avoid feeding the variable target through
                            // this wide counter's subtractor; the final partial
                            // burst is handled by the equality case above.
                            segment_left0<=segment_left0-BURST_SIZE;
                        end
                    end
                    last_lane<=cur_lane;state<=S_PICK;
                end
                S_END:begin read_finish<=1;state<=S_IDLE;end
                default:state<=S_IDLE;
            endcase
        end
    end
endmodule
