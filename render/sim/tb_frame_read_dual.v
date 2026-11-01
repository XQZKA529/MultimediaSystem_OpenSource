`timescale 1ns/1ps
// Real production FIFOs + RGB unpackers at 125/75 MHz, full 720p scanout.
module tb_frame_read_dual;
    parameter VENDOR_TIMING=1;
    localparam W=1280,H=720,HT=1650,VT=750,WORDS=W*H*3/4;
    reg mc=0,vc=0,rst=1,req=0,dual=1,model_busy=0,wrbusy=0;
    always #4 mc=~mc;always #6.666667 vc=~vc;
    reg [1:0] primary_bank=0;
    wire en,ack,finish,clear0,clear1,owner,urgent,rb,ready,dual_active;
    wire [20:0] addr;wire [1:0] selected;wire handoff;
    wire [8:0] occ0,occ1;
    reg [8:0] vp=0;reg [20:0] ap[0:8];integer j,cycle=0;
    wire ret,busy,init,refv;
    reg [20:0] requests[0:511];reg [8:0] qw=0,qr=0;
    wire [20:0] returned_addr=VENDOR_TIMING ? requests[qr]:ap[8];
    function [23:0] pixel;
        input integer i;input integer bank;
        begin pixel={i[7:0],i[15:8],(bank ? 8'hd3:8'h27)};end
    endfunction
    function [31:0] packed;
        input [20:0] a;integer offset,b,pix,bidx,k;reg [23:0] rgb;
        begin
            b=a>=WORDS;offset=b ? a-WORDS:a;packed=0;
            for(k=0;k<4;k=k+1) begin
                pix=(offset*4+k)/3;bidx=(offset*4+k)%3;rgb=pixel(pix,b);
                case(bidx)
                    0:packed={packed[23:0],rgb[23:16]};
                    1:packed={packed[23:0],rgb[15:8]};
                    2:packed={packed[23:0],rgb[7:0]};
                endcase
            end
        end
    endfunction
    // Real encrypted controller supplies valid timing. The TD physical SDRAM
    // primitive is empty in simulation; deterministic pixels replace only DQ.
    wire [31:0] memdata=packed(returned_addr);
    generate if(VENDOR_TIMING) begin: actual
        wire raw_ret;wire [31:0] raw_data;wire ae;wire [20:0] aa;
        sdram memory(.Clk(mc),.Clk_sft(~mc),.Rst(rst),.Sdr_init_done(init),
            .Sdr_init_ref_vld(refv),.Sdr_busy(busy),.App_wr_en(1'b0),.App_wr_addr(21'd0),
            .App_wr_dm(4'd0),.App_wr_din(32'd0),.App_rd_en(ae),.App_rd_addr(aa),
            .Sdr_rd_en(raw_ret),.Sdr_rd_dout(raw_data));
        sdram_app_arb #(.TAG_AW(9),.ENABLE_AUDIO(0)) arb(.clk(mc),.rst(rst),.sdr_busy(busy),
            .f_App_wr_en(1'b0),.f_App_wr_addr(21'd0),.f_App_wr_din(32'd0),.f_App_wr_dm(4'd0),
            .f_App_rd_en(en),.f_App_rd_addr(addr),.f_Sdr_rd_en(ret),.f_Sdr_rd_dout(),
            .a_App_wr_en(1'b0),.a_App_wr_addr(21'd0),.a_App_wr_din(32'd0),.a_App_wr_dm(4'd0),
            .a_App_rd_en(1'b0),.a_App_rd_addr(21'd0),.a_Sdr_rd_en(),.a_Sdr_rd_dout(),.a_wr_gnt(),.a_rd_gnt(),
            .App_wr_en(),.App_wr_addr(),.App_wr_dm(),.App_wr_din(),.App_rd_en(ae),.App_rd_addr(aa),
            .Sdr_rd_en(raw_ret),.Sdr_rd_dout(raw_data));
    end else begin: behavioral
        assign init=1;assign refv=0;assign busy=model_busy;assign ret=vp[8];
    end endgenerate
    always @(posedge mc) begin
        if(rst) begin vp<=0;cycle<=0;model_busy<=0;qw<=0;qr<=0;end
        else begin
            cycle<=cycle+1;
            // Busy defers burst admission. It does not stop admitted words.
            model_busy<=cycle%3906<12;
            vp<={vp[7:0],en};ap[0]<=addr;
            for(j=1;j<9;j=j+1) ap[j]<=ap[j-1];
            if(en) begin requests[qw]<=addr;qw<=qw+1'b1;end
            if(ret) qr<=qr+1'b1;
            if(en && wrbusy) $fatal(1,"read/write burst collision");
            if(ret && !rb) $fatal(1,"return escaped burst owner");
        end
    end
    frame_fifo_read_dual dut(.rst(rst),.mem_clk(mc),.Sdr_init_done(init),
        .Sdr_init_ref_vld(refv),.Sdr_busy(busy),.App_rd_en(en),.App_rd_addr(addr),.Sdr_rd_en(ret),
        .read_req(req),.read_req_ack(ack),.read_finish(finish),.read_selected_index(selected),
        .read_handoff_toggle(handoff),.read_addr_0(21'd0),.read_addr_1(WORDS[20:0]),
        .read_addr_2(21'd0),.read_addr_3(21'd0),.read_addr_index(primary_bank),.read_len(WORDS[20:0]),
        .read_addr_lane1(WORDS[20:0]),.read_index_lane1(2'd1),.read_lane1_en(dual),
        .App_wr_busy(wrbusy),.fifo_aclr0(clear0),.fifo_aclr1(clear1),.lane0_lane1_sel(owner),
        .wrusedw0({1'b0,occ0}),.wrusedw1({1'b0,occ1}),.read_ready(ready),.read_urgent(urgent),
        .read_dual_active(dual_active),.O_rd_busy(rb));
    wire re0,re1,empty0,empty1,full0,full1;wire [31:0] data0,data1;
    rfifo_32_32_512 f0(.clkr(vc),.clkw(mc),.rst(clear0),.we(ret && !owner),.re(re0),
        .di(memdata),.empty_flag(empty0),.full_flag(full0),.wrusedw(occ0),.rdusedw(),.valid(),.afull(),.aempty(),.dout(data0));
    rfifo_32_32_512 f1(.clkr(vc),.clkw(mc),.rst(clear1),.we(ret && owner),.re(re1 && dual),
        .di(memdata),.empty_flag(empty1),.full_flag(full1),.wrusedw(occ1),.rdusedw(),.valid(),.afull(),.aempty(),.dout(data1));
    reg de=0;reg [1:0] as=0;
    always @(posedge vc) if(rst) as<=0;else as<={as[0],ack};
    wire de0,de1,pv0,pv1,uf0,uf1;wire [23:0] rgb0,rgb1;
    rgb888_word_reader r0(.clk(vc),.rst(rst),.frame_start(as[1]),.hs_in(1'b0),.vs_in(1'b0),.de_in(de),
        .fifo_empty(empty0),.fifo_read_en(re0),.fifo_read_data(data0),.hs_out(),.vs_out(),.de_out(de0),.pixel_rgb(rgb0),
        .pixel_valid(pv0),.underflow_sticky(uf0));
    rgb888_word_reader r1(.clk(vc),.rst(rst),.frame_start(as[1]),.hs_in(1'b0),.vs_in(1'b0),.de_in(de),
        .fifo_empty(empty1),.fifo_read_en(re1),.fifo_read_data(data1),.hs_out(),.vs_out(),.de_out(de1),.pixel_rgb(rgb1),
        .pixel_valid(pv1),.underflow_sticky(uf1));
    reg check_on=0;
    wire [23:0] mixed;wire pair_ok,mixed_de;
    pixel_mixer mixer(.clk(vc),.rst(rst),.mix_en(dual),.alpha(9'd128),
        .old_rgb(rgb0),.old_valid(pv0),.new_rgb(rgb1),.new_valid(pv1),.mixed_rgb(mixed),.pair_ok(pair_ok));
    reg [2:0] mix_de_pipe;
    always @(posedge vc or posedge rst)
        if(rst) mix_de_pipe<=0;else mix_de_pipe<={mix_de_pipe[1:0],de0};
    assign mixed_de=mix_de_pipe[2];
    integer mixed_pixels=0;
    reg [23:0] exp_mix;
    always @(posedge vc) begin
        #1;
        if(check_on && mixed_de) begin
            exp_mix=pixel(mixed_pixels,primary_bank);
            if(dual) exp_mix[7:0]=8'h7d;
            if(!pair_ok || mixed!==exp_mix) $fatal(1,"mixed timing/RGB at pixel %0d got=%h",mixed_pixels,mixed);
            mixed_pixels=mixed_pixels+1;
        end
    end
    integer words0=0,words1=0,pixels=0,frames=0,min0=511,min1=511;

    always @(posedge mc) if(!rst) begin
        if(ret && owner && full1 || ret && !owner && full0) $fatal(1,"FIFO overflow");
        if(ret) begin
            if(owner) begin
                if(returned_addr!==WORDS+words1) $fatal(1,"lane1 address %h expected %h",returned_addr,WORDS+words1);
                words1=words1+1;
            end else begin
                if(returned_addr!==primary_bank*WORDS+words0) $fatal(1,"lane0 address %h expected %h",returned_addr,primary_bank*WORDS+words0);
                words0=words0+1;
            end
        end
    end
    always @(posedge vc) begin
        #1;
        if(check_on && de0) begin
            if(!pv0 || rgb0!==pixel(pixels,primary_bank)) $fatal(1,"old pixel %0d valid=%b got=%h",pixels,pv0,rgb0);
            if(dual && (!pv1 || rgb1!==pixel(pixels,1))) $fatal(1,"new pixel %0d valid=%b got=%h",pixels,pv1,rgb1);
            if(occ0<min0) min0=occ0;if(dual && occ1<min1) min1=occ1;
            pixels=pixels+1;
        end
    end
    integer x,y;
    task frame;
        begin
            words0=0;words1=0;pixels=0;mixed_pixels=0;check_on=1;
            @(negedge vc);req=1;wait(as[1]);@(negedge vc);req=0;wait(!as[1]);
            // The real vertical blank interval lets both FIFOs prefill.
            repeat(HT*30) @(negedge vc);
            for(y=0;y<H;y=y+1) begin
                for(x=0;x<HT;x=x+1) begin de=x<W;@(negedge vc);end
            end
            de=0;repeat(10) @(negedge vc);check_on=0;
            if(pixels!=W*H || mixed_pixels!=W*H || words0!=WORDS || (dual && words1!=WORDS))
                $fatal(1,"incomplete full frame pixels=%0d words=%0d/%0d",pixels,words0,words1);
            frames=frames+1;$display("verified full frame %0d dual=%b",frames,dual);
        end
    endtask
    initial begin
        repeat(10) @(negedge mc);rst=0;wait(init);
        frame;frame;dual=0;primary_bank=1;frame;
        // An interrupted/full FIFO frame must not block the following frame.
        primary_bank=0;words0=0;words1=0;req=1;wait(as[1]);@(negedge vc);req=0;wait(!as[1]);
        repeat(5000) @(negedge mc);
        if(occ0>511) $fatal(1,"full-FIFO backpressure");
        primary_bank=0;frame;
        $display("STAT full720p frames=%0d low_water=%0d/%0d",frames,min0,min1);
        $display("*** PASS *** full720p two COMPLETE images, real FIFO backpressure, RGB coordinate alignment, refresh, single mode and interrupted frame recovery");$finish;
    end
    initial begin #100000000;$fatal(1,"full frame watchdog");end
endmodule
