`timescale 1ns/1ps
module tb_contrast_adjust;
    reg clk=0,rst=1,cv=0,en=1,h=0,v=0,d=0;
    reg [4:0] level=10;
    reg [23:0] rgb=0;
    wire ho,vo,do_,hl,vl,dl;wire [23:0] out,out_low;
    integer expected_level=10,checks=0,i,l;
    reg [23:0] qrgb[0:2];reg [2:0] qh,qv,qd,qvalid;
    always #5 clk=~clk;
    contrast_adjust dut(.clk(clk),.rst(rst),.cfg_valid(cv),.cfg_level(level),.enable(en),
        .hs_in(h),.vs_in(v),.de_in(d),.rgb_in(rgb),.hs_out(ho),.vs_out(vo),.de_out(do_),.rgb_out(out));
    contrast_adjust #(.VS_ACTIVE_HIGH(0)) low_polarity(.clk(clk),.rst(rst),.cfg_valid(cv),.cfg_level(level),.enable(en),
        .hs_in(h),.vs_in(~v),.de_in(d),.rgb_in(rgb),.hs_out(hl),.vs_out(vl),.de_out(dl),.rgb_out(out_low));
    function [7:0] reference;
        input integer c,g;integer x;
        begin
            x=((c-128)*g+1280+5);
            if(x<0) reference=0;
            else if(x/10>255) reference=255;
            else reference=x/10;
        end
    endfunction
    always @(posedge clk) begin
        if(rst) begin qvalid=0;qh=0;qv=0;qd=0;end
        else begin
            qrgb[2]=qrgb[1];qrgb[1]=qrgb[0];
            qrgb[0]={reference(rgb[23:16],en ? expected_level:10),
                reference(rgb[15:8],en ? expected_level:10),reference(rgb[7:0],en ? expected_level:10)};
            qh={qh[1:0],h};qv={qv[1:0],v};qd={qd[1:0],d};qvalid={qvalid[1:0],1'b1};
            #1;
            if(qvalid[2]) begin
                if({ho,vo,do_}!={qh[2],qv[2],qd[2]} || {hl,vl,dl}!={qh[2],~qv[2],qd[2]})
                    $fatal(1,"Three-cycle sync/DE alignment");
                if(qd[2]) begin
                    if(out!==qrgb[2] || out_low!==qrgb[2])
                        $fatal(1,"Contrast got=%h/%h expected=%h level=%0d",out,out_low,qrgb[2],expected_level);
                    checks=checks+1;
                end
            end
        end
    end
    task step;input integer n;begin repeat(n) @(negedge clk);end endtask
    task frame;input integer want;
        begin
            d=0;step(6);v=1;step(8);v=0;step(1);
            expected_level=(want<=20) ? want:10;step(4);
        end
    endtask
    task configure;input integer want;
        begin d=0;level=want;cv=1;step(1);cv=0;frame(want);end
    endtask
    task ramp;
        begin
            for(i=0;i<256;i=i+1) begin
                d=1;h=i[0];rgb={i[7:0],8'hff-i[7:0],i[7:0]^8'h59};step(1);
            end
            d=0;step(5);
        end
    endtask
    initial begin
        step(4);rst=0;step(4);ramp;
        for(l=0;l<=20;l=l+1) begin configure(l);ramp;end
        // Mid-frame update remains pending; the last update wins next frame.
        configure(3);d=1;rgb=24'h10_80_f0;step(12);
        level=18;cv=1;step(1);cv=0;step(10);
        level=7;cv=1;step(1);cv=0;step(10);frame(7);ramp;
        // Configuration arriving on the VS trailing edge applies this frame.
        d=0;step(5);v=1;step(8);level=20;cv=1;v=0;step(1);
        expected_level=20;cv=0;step(4);ramp;
        en=0;ramp;en=1;ramp;
        configure(31);ramp;
        // Reset during a non-neutral stream restores 100% and clears DE.
        configure(0);d=1;rgb=24'h35_90_e1;step(10);rst=1;d=0;step(3);
        if(do_ || out!=0) $fatal(1,"Reset output");
        expected_level=10;rst=0;step(4);ramp;
        if(checks<6000) $fatal(1,"Insufficient exhaustive coverage");
        $display("*** PASS *** contrast: 256 inputs x 21 levels, RGB, saturation, bypass, 3-cycle sync, both VS polarities, frame config, reset (%0d pixels)",checks);
        $finish;
    end
    initial begin #1000000;$fatal(1,"Watchdog");end
endmodule
