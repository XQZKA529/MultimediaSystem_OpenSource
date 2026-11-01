`timescale 1ns/1ps
// The runner supplies an unchanged reference module from a Git revision.
module tb_scale_cycle_equivalence;
    parameter DST_W=32,DST_H=18;
    reg clk=0,rst=1,start=0,cancel=0;
    always #5 clk=~clk;
    reg [12:0] src_w=1,src_h=1;
    reg [15:0] scaled_w=1,scaled_h=1,left=0,bottom=0;
    reg in_valid=0,out_ready=0;
    reg [23:0] in_rgb=0;
    wire old_ready,new_ready,old_valid,new_valid,old_done,new_done;
    wire [23:0] old_rgb,new_rgb;
    image_scale_nearest_reference #(.DST_W(DST_W),.DST_H(DST_H)) reference(
        .clk(clk),.rst(rst),.start(start),.cancel(cancel),.src_w(src_w),.src_h(src_h),
        .scaled_w(scaled_w),.scaled_h(scaled_h),.left(left),.bottom(bottom),
        .in_valid(in_valid),.in_rgb(in_rgb),.in_ready(old_ready),
        .out_valid(old_valid),.out_rgb(old_rgb),.out_ready(out_ready),.done(old_done));
    image_scale_nearest #(.DST_W(DST_W),.DST_H(DST_H)) candidate(
        .clk(clk),.rst(rst),.start(start),.cancel(cancel),.src_w(src_w),.src_h(src_h),
        .scaled_w(scaled_w),.scaled_h(scaled_h),.left(left),.bottom(bottom),
        .in_valid(in_valid),.in_rgb(in_rgb),.in_ready(new_ready),
        .out_valid(new_valid),.out_rgb(new_rgb),.out_ready(out_ready),.done(new_done));
    integer sent=0,received=0,total=0,cycles=0,fp,scanned,idx,w,h,rw,rh,l,b,offset;
    reg running=0,accepted=0;
    reg [31:0] random_state=32'h29cafe15;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(!rst) begin
            if({old_ready,old_valid,old_done} !== {new_ready,new_valid,new_done})
                $fatal(1,"handshake/completion mismatch case=%0d cycle=%0d",idx,cycles);
            if(old_valid && old_rgb!==new_rgb)
                $fatal(1,"pixel mismatch case=%0d output=%0d",idx,received);
        end
        accepted=running && in_valid && old_ready && !start && !cancel;
        if(accepted) sent=sent+1;
        if(running && old_valid && out_ready) received=received+1;
    end
    always @(negedge clk) if(running && !start && !cancel) begin
        random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        // Hold a stalled source pixel; also inject bubbles and long output stalls.
        in_valid=sent<total && ((in_valid && !accepted) || random_state[3:0]!=0);
        in_rgb={sent[7:0],sent[15:8],(sent[7:0]^sent[15:8])};
        out_ready=random_state[7:4]!=0 && cycles%4096<3800;
    end
    task begin_image;
        begin
            @(negedge clk);running=0;in_valid=0;out_ready=0;start=1;
            sent=0;received=0;total=w*h;
            src_w=w;src_h=h;scaled_w=rw;scaled_h=rh;left=l;bottom=b;
            @(negedge clk);start=0;running=1;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        fp=$fopen("cases.txt","r");
        for(idx=0;idx<17;idx=idx+1) begin
            scanned=$fscanf(fp,"%d %d %d %d %d %d %d\n",w,h,rw,rh,l,b,offset);
            if(scanned!=7) $fatal(1,"missing geometry fixture");
            // Cancel during different pipeline states, then restart without reset.
            begin_image();repeat(37+idx*19) @(negedge clk);
            running=0;cancel=1;in_valid=0;
            @(negedge clk);cancel=0;
            begin_image();wait(old_done);@(negedge clk);running=0;in_valid=0;
            if(sent!=total || received!=DST_W*DST_H)
                $fatal(1,"incomplete frame source=%0d/%0d output=%0d",sent,total,received);
            $display("case=%0d %0dx%0d passed",idx,w,h);
        end
        $fclose(fp);
        $display("*** PASS *** scaler cycle-exact handshakes/RGB/completion, %0d clocks, 17 sizes, stalls/cancel/restart",cycles);
        $finish;
    end
    initial begin #2000000000;$fatal(1,"scaler equivalence watchdog");end
endmodule
