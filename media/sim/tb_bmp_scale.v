`timescale 1ns/1ps
module tb_bmp_scale;
    parameter DST_W=32,DST_H=18,CASE=-1;
    reg clk=0,rst=1,probe=0,pv=0,pfinish=0,gs=0,start=0,cancel=0;
    always #5 clk=~clk;
    reg [7:0] b=0;reg fv=0,fd=0,fok=1;
    reg [31:0] size=0;
    wire hd,hok,gd,gok,credit,ov,done,failed;
    wire [12:0] w,h;wire [31:0] off,stride,last;
    wire [15:0] rw,rh,left,bottom;wire [23:0] rgb;
    reg ready=1,checking=0;
    reg [31:0] random_state=32'h12345678;
    reg [23:0] expected[0:DST_W*DST_H-1];
    reg [7:0] header[0:53];
    integer count=0,cycles=0,stall=0;
    integer sw,sh,ew,eh,el,eb,offset,rs,total,idx,fp,r,i,n,pos,k,px,py;
    reg [1023:0] filename;
    reg [23:0] source;
    reg was_stalled=0;reg [23:0] stalled_rgb;
    bmp_header_parser hp(.clk(clk),.rst(rst),.start(probe),.byte_valid(pv),.byte_data(b),
        .finish(pfinish),.actual_size(size),.done(hd),.ok(hok),.width(w),.height(h),
        .pixel_offset(off),.row_stride(stride),.payload_end(last));
    image_scale_geometry geo(.clk(clk),.rst(rst),.start(gs),.src_w(w),.src_h(h),
        .dst_w(DST_W[15:0]),.dst_h(DST_H[15:0]),.mode(2'd0),.done(gd),.ok(gok),
        .scaled_w(rw),.scaled_h(rh),.left(left),.bottom(bottom));
    bmp_image_pipeline #(.DST_W(DST_W),.DST_H(DST_H)) dut(
        .clk(clk),.rst(rst),.start(start),.cancel(cancel),.src_w(w),.src_h(h),
        .pixel_offset(off),.row_stride(stride),.scaled_w(rw),.scaled_h(rh),.left(left),.bottom(bottom),
        .file_data(b),.file_valid(fv),.file_done(fd),.file_ok(fok),.burst_ready(credit),
        .pixel_valid(ov),.pixel_rgb(rgb),.pixel_ready(ready),.progress(),.done(done),.failed(failed));
    task put32;input integer at;input [31:0] v;begin
        header[at]=v[7:0];header[at+1]=v[15:8];header[at+2]=v[23:16];header[at+3]=v[31:24];
    end endtask
    function [23:0] color;input integer x,y;reg [7:0] rr,gg,bb;begin
        rr=x*17+y*3;gg=x*5+y*29;bb=x*11+y*7;color={rr,gg,bb};
    end endfunction
    always @(negedge clk) if(checking) begin
        random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        ready=random_state[3:0]!=0;
        // Repeated long pauses exercise input credit and stable output data.
        cycles=cycles+1;if(cycles%8192==0) stall=1500;
        if(stall>0) begin ready=0;stall=stall-1;end
    end
    always @(posedge clk) if(checking) begin
        if(failed) $fatal(1,"pipeline failure case=%0d count=%0d",idx,count);
        if(was_stalled && (!ov || rgb!==stalled_rgb)) $fatal(1,"unstable ready/valid output");
        was_stalled=ov && !ready;stalled_rgb=rgb;
        if(ov && ready) begin
            if(count>=DST_W*DST_H || rgb!==expected[count])
                $fatal(1,"case=%0d pixel=%0d got=%h expected=%h",idx,count,rgb,expected[count]);
            count=count+1;
        end
        if(done && !start && count!=DST_W*DST_H) $fatal(1,"early completion");
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;fp=$fopen("cases.txt","r");
        for(idx=0;idx<17;idx=idx+1) begin
            r=$fscanf(fp,"%d %d %d %d %d %d %d\n",sw,sh,ew,eh,el,eb,offset);
            if(r!=7) $fatal(1,"fixture metadata");
            if(CASE==-1 || CASE==idx) begin
                $display("case=%0d source=%0dx%0d target=%0dx%0d",idx,sw,sh,DST_W,DST_H);
                rs=(sw*3+3)&~3;total=offset+rs*sh+17;size=total;
                for(i=0;i<54;i=i+1) header[i]=0;
                header[0]="B";header[1]="M";put32(2,total);put32(10,offset);put32(14,40);
                put32(18,sw);put32(22,sh);header[26]=1;header[28]=24;
                probe=1;@(negedge clk);probe=0;
                for(i=0;i<54;i=i+1) begin pv=1;b=header[i];@(negedge clk);end
                pv=0;pfinish=1;@(negedge clk);pfinish=0;wait(hd);
                if(!hok || stride!=rs || last!=offset+rs*sh) $fatal(1,"BMP metadata");
                @(negedge clk);gs=1;@(negedge clk);gs=0;wait(gd);
                if(!gok || rw!=ew || rh!=eh || left!=el || bottom!=eb) $fatal(1,"geometry oracle mismatch");
                $sformat(filename,"expected_%0d.hex",idx);$readmemh(filename,expected);
                @(negedge clk);count=0;cycles=0;stall=0;checking=1;start=1;
                @(negedge clk);start=0;
                pos=0;
                while(pos<total) begin
                    wait(credit);n=total-pos;if(n>512)n=512;
                    for(k=0;k<n;k=k+1) begin
                        @(negedge clk);fv=1;
                        if(pos<54) b=header[pos];
                        else if(pos<offset) b=8'h55;
                        else if(pos>=offset+rs*sh) b=8'haa;
                        else begin
                            px=(pos-offset)%rs;
                            py=sh-1-(pos-offset)/rs;
                            source=color(px/3,py);
                            b=px>=sw*3 ? 8'hcc : source[(px%3)*8+:8];
                        end
                        pos=pos+1;
                    end
                    @(negedge clk);fv=0;
                end
                fd=1;@(negedge clk);fd=0;wait(done);
                @(negedge clk);checking=0;was_stalled=0;
                if(count!=DST_W*DST_H) $fatal(1,"output count");
                $display("checked %0d pixels",count);
            end
        end
        $fclose(fp);$display("*** PASS *** BMP contain pixels, odd borders, padding, limits, source drain and random backpressure");$finish;
    end
    initial begin #(64'd6000000000);$fatal(1,"scale watchdog case=%0d",idx);end
endmodule
