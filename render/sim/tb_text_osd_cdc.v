`timescale 1ns/1ps
module tb_text_osd_cdc;
    reg clk=0,vc=0,rst=1,vrst=1,vs=0;
    reg [`TEXT_OSD_META_W-1:0] metadata=0;reg [31:0] revision=0;
    reg [7:0] source[0:255];reg [7:0] edit_data;
    wire [7:0] edit_addr;reg [7:0] text_addr=0;wire [7:0] text_data;
    wire [`TEXT_OSD_META_W-1:0] view;reg [`TEXT_OSD_META_W-1:0] previous=0;wire video_commit;integer i,k;
    always #5 clk=~clk;always #7 vc=~vc;
    always @(posedge clk) edit_data<=source[edit_addr];
    text_osd_view_cdc dut(.clk(clk),.rst(rst),.metadata(metadata),.revision(revision),
        .edit_addr(edit_addr),.edit_data(edit_data),.video_clk(vc),.video_rst(vrst),.vs(vs),
        .text_addr(text_addr),.text_data(text_data),.view(view),.video_commit(video_commit));
    always @(negedge vc) begin
        if(!vrst && view!==previous && !vs) $fatal(1,"Metadata changed outside VS");previous=view;
    end
    task step;input integer n;begin repeat(n) @(negedge clk);end endtask
    task frame;begin step(260);@(negedge vc);vs=1;repeat(3) @(negedge vc);vs=0;step(20);end endtask
    task update;input [7:0] value;input [6:0] len;begin
        @(negedge clk);for(k=0;k<256;k=k+1) source[k]=value+k;
        metadata={1'b1,value[4:0],len};revision=revision+1;
    end endtask
    task check;input [7:0] value;integer a;reg [7:0] expected;begin
        if(view!==metadata) $fatal(1,"Latest metadata lost %h %h",view,metadata);
        for(a=0;a<128;a=a+1) begin
            @(negedge vc);text_addr=a;@(negedge vc);
            expected=a<metadata[`TEXT_OSD_VIEW_LEN] ? value+a:0;
            if(text_data!==expected) $fatal(1,"Snapshot byte %0d got %h expected %h",a,text_data,expected);
        end
    end endtask
    initial begin
        for(k=0;k<256;k=k+1) source[k]=8'hff;
        step(4);rst=0;vrst=0;frame;frame;check(0);
        update(65,256);step(240);if(view!==0) $fatal(1,"Midframe publish");
        frame;check(65);
        for(i=0;i<25;i=i+1) begin update(i,256);step(3);end
        frame;frame;check(24);
        update(90,255);frame;frame;check(90);
        update(32,0);frame;frame;check(32);
        update(70,256);frame;frame;check(70);
        repeat(2) begin
            update(80,256);step(230);
            @(negedge vc);vrst=1;step(8);@(negedge vc);vrst=0;
            frame;frame;frame;check(80);
            @(negedge vc);vrst=1;step(8);@(negedge vc);vrst=0;
            frame;frame;frame;check(80);
        end
        update(100,256);wait(dut.state==2 && dut.index==256);
        @(negedge clk);update(110,256);frame;frame;check(110);
        // Producer-only reset retains the visible bank until the new empty
        // model commits. Stale RAM contents must remain invisible afterwards.
        @(negedge clk);rst=1;metadata=0;revision=0;step(8);rst=0;
        frame;frame;frame;check(0);
        update(80,256);frame;frame;check(80);
        // Revision equality must also work across unsigned counter wrap.
        @(negedge clk);revision=32'hfffffffe;frame;frame;check(80);
        update(90,256);frame;frame;check(90);
        update(100,256);frame;frame;check(100);
        $display("*** PASS *** Text BRAM CDC: coherent bytes, VS atomicity, edits during copy, tail masking, independent resets, revision wrap");$finish;
    end
    initial begin #1000000;$fatal(1,"CDC timeout");end
endmodule
