`timescale 1ns/1ps
`include "pkg/text_osd_model.vh"
module tb_text_osd_controller;
    reg clk=0,rst=1,enabled=1;reg [4:0] action=0;
    wire on,changed;reg [`TEXT_OSD_TEXT_W-1:0] buffer=0;wire [`TEXT_OSD_META_W-1:0] metadata;reg [7:0] read_addr=0;wire [7:0] read_data;wire [`TEXT_OSD_LEN_W-1:0] length;wire [4:0] focus;wire [`TEXT_OSD_MODEL_W-1:0] model;
    assign model={metadata,buffer};
    integer i,j,expected;reg [`TEXT_OSD_MODEL_W-1:0] saved;
    always #5 clk=~clk;
    text_osd_controller dut(.clk(clk),.rst(rst),.edit_enable(enabled),
        .up(action[0]),.down(action[1]),.left(action[2]),.right(action[3]),.confirm(action[4]),
        .osd_enable(on),.read_addr(read_addr),.read_data(read_data),.text_len(length),.focus_id(focus),.metadata(metadata),.revision(),.changed(changed));
    always @(negedge clk) if(!rst) begin
        if(length>`TEXT_OSD_MAX_LEN || focus>29) $fatal(1,"Model invariant");
    end
    task step;input integer n;begin repeat(n) @(negedge clk);end endtask
    task refresh;integer k;begin
        for(k=0;k<`TEXT_OSD_BYTES;k=k+1) begin
            read_addr=k;step(1);buffer[k*8 +: 8]=read_data;
        end
        if(length<`TEXT_OSD_MAX_LEN && buffer[length*8 +: 8]!==0) $fatal(1,"Range masking");
    end endtask
    task act;input integer id;begin action=1<<id;step(1);action=0;step(1);refresh;end endtask
    task seek;input integer target;integer n;
        begin
            repeat(5) act(0);act(2); // control row, switch
            if(target==1) act(3);
            else if(target>=2) begin
                act(1);for(n=0;n<(target-2)/7;n=n+1) act(1);
                for(n=0;n<(target-2)%7;n=n+1) act(3);
            end
            if(focus!=target) $fatal(1,"seek %0d got %0d",target,focus);
        end
    endtask
    // Reference graph expressed as independent row/column coordinates.
    function integer neighbor;
        input integer f,d;integer r,c;
        begin
            r=f<2 ? 0:1+(f-2)/7;c=f<2 ? f:(f-2)%7;
            neighbor=f;
            if(r==0) begin
                case(d) 1:neighbor=c==0 ? 2:6;2:neighbor=0;3:neighbor=1;endcase
            end else case(d)
                0:neighbor=r==1 ? (c<4 ? 0:1):2+(r-2)*7+c;
                1:if(r<4) neighbor=2+r*7+c;
                2:if(c>0) neighbor=2+(r-1)*7+c-1;
                3:if(c<6) neighbor=2+(r-1)*7+c+1;
            endcase
        end
    endfunction
    initial begin
        step(3);rst=0;step(2);
        if(model!==0) $fatal(1,"Defaults");
        for(i=0;i<30;i=i+1) for(j=0;j<4;j=j+1) begin
            seek(i);expected=neighbor(i,j);act(j);
            if(focus!=expected) $fatal(1,"Navigation %d direction %d got %d expected %d",i,j,focus,expected);
        end
        seek(0);act(4);if(!on) $fatal(1,"Enable");
        for(i=0;i<26;i=i+1) begin
            seek(i+2);act(4);
            if(length!=1 || buffer[7:0]!==65+i) $fatal(1,"Alphabet %d",i);
            seek(1);act(4);if(length!=0 || buffer!=0 || !on) $fatal(1,"Clear preserves enable");
        end
        seek(28);act(4);if(length!=1 || buffer[7:0]!=32) $fatal(1,"SPACE");
        seek(29);act(4);act(4);if(length!=0) $fatal(1,"Empty DEL");
        seek(2);repeat(`TEXT_OSD_MAX_LEN) act(4);
        for(i=0;i<`TEXT_OSD_MAX_LEN;i=i+1) if(buffer[i*8 +: 8]!=65) $fatal(1,"Buffer data");
        #1;saved=model;act(4);#1;if(model!==saved) $fatal(1,"Letter overflow len=%0d/%0d focus=%0d on=%b",length,saved[`TEXT_OSD_LEN],focus,on);
        seek(28);saved=model;act(4);if(model!==saved) $fatal(1,"SPACE overflow");
        seek(29);act(4);if(length!=`TEXT_OSD_MAX_LEN-1 || buffer[(`TEXT_OSD_MAX_LEN-1)*8 +: 8]!=0) $fatal(1,"DEL");
        seek(27);act(4);if(length!=`TEXT_OSD_MAX_LEN || buffer[(`TEXT_OSD_MAX_LEN-1)*8 +: 8]!=90) $fatal(1,"Append after DEL");
        enabled=0;#1;saved=model;repeat(5) act(4);act(0);
        if(model!==saved) $fatal(1,"Disabled editor modified state");
        enabled=1;seek(1);act(4);seek(0);act(4);if(model!==0) $fatal(1,"Clear/disable");
        $display("*** PASS *** Text OSD: 120 graph edges, alphabet, SPACE, capacity/NUL, DEL/CLR, retention");$finish;
    end
    initial begin #20000000;$fatal(1,"Controller timeout");end
endmodule
