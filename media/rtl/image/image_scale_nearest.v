// Generic bottom-up RGB stream scaler. Sampling uses integer remainder steps.
// Horizontal: floor((2*x+1)*W/(2*DW)). Vertical storage coordinate:
// H-1-floor((2*(DH-1-y)+1)*H/(2*DH)) = floor(((2*y+1)*H-1)/(2*DH)).
module image_scale_nearest #(parameter DST_W=1280,DST_H=720)(
    input wire clk,rst,start,cancel,input wire [12:0] src_w,src_h,
    input wire [15:0] scaled_w,scaled_h,left,bottom,
    input wire in_valid,input wire [23:0] in_rgb,output wire in_ready,
    output wire out_valid,output wire [23:0] out_rgb,input wire out_ready,
    output reg done
);
    localparam IDLE=0,YNORM=1,SEEK=2,ROW_START=3,LEFT=4,XNORM=5,
        SAMPLE=6,WRITE=7,RIGHT=8,DROP=9,SETTLE=10,READ_START=11,
        EMIT=12,BLACK=13,DRAIN=14;
    reg [3:0] state;
    reg [12:0] sx,sy,wanted_x,wanted_y,held_x,cache_y;
    // Geometry confines output positions to the destination rectangle.
    // Include the terminal row/column value used before drain/row drop.
    localparam integer X_BITS=DST_W<2 ? 1:$clog2(DST_W+1),
        Y_BITS=DST_H<2 ? 1:$clog2(DST_H+1);
    reg [X_BITS-1:0] ox,row_x,remaining_x;
    reg [Y_BITS-1:0] oy;
    reg [14:0] xrem,yrem;
    reg [23:0] held_rgb;
    reg [2:0] settle;
    reg row_has_output;
    wire [16:0] xden={scaled_w,1'b0},yden={scaled_h,1'b0};
    wire row_pixel_valid;wire [23:0] row_pixel;
    wire row_write=state==LEFT || state==WRITE || state==RIGHT;
    image_row_store #(.WIDTH(DST_W)) row(
        .clk(clk),.rst(rst),.write_start(state==ROW_START),.write_valid(row_write),
        .write_rgb(state==WRITE ? held_rgb:24'd0),.read_start(state==READ_START),
        .pixel_valid(row_pixel_valid),.pixel_rgb(row_pixel),.pixel_ready(state==EMIT && out_ready));
    assign in_ready=(state==SEEK && sy<wanted_y) || state==SAMPLE ||
        (state==DROP && sy==cache_y) || (state==DRAIN && sy<src_h);
    assign out_valid=state==BLACK || (state==EMIT && row_pixel_valid);
    assign out_rgb=state==BLACK ? 24'd0:row_pixel;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            // Every row/data counter is initialized before its valid state.
            state<=IDLE;done<=0;
        end else if(cancel) begin
            state<=IDLE;done<=0;
        end else if(start) begin
            sx<=0;sy<=0;wanted_x<=0;wanted_y<=0;ox<=0;oy<=0;done<=0;
            yrem<=src_h-1'b1;state<=YNORM;
        end else begin
            if(in_valid && in_ready) begin
                if(sx+1==src_w) begin sx<=0;sy<=sy+1'b1;end
                else sx<=sx+1'b1;
            end
            case(state)
                YNORM: if(yrem>=yden) begin yrem<=yrem-yden;wanted_y<=wanted_y+1'b1;end
                    else if(oy<bottom || oy>=bottom+scaled_h) state<=BLACK;
                    else if(oy!=bottom && wanted_y==cache_y) state<=READ_START;
                    else state<=SEEK;
                SEEK: if(sy==wanted_y) state<=ROW_START;
                ROW_START: begin
                    row_x<=0;remaining_x<=scaled_w[X_BITS-1:0];row_has_output<=0;
                    wanted_x<=0;xrem<=src_w;cache_y<=sy;
                    state<=left==0 ? XNORM:LEFT;
                end
                LEFT: begin row_x<=row_x+1'b1;if(row_x+1==left) state<=XNORM;end
                XNORM: if(xrem>=xden) begin xrem<=xrem-xden;wanted_x<=wanted_x+1'b1;end
                    else if(row_has_output && wanted_x==held_x) state<=WRITE;
                    else state<=SAMPLE;
                SAMPLE: if(in_valid && in_ready && sx==wanted_x) begin
                    held_rgb<=in_rgb;held_x<=sx;state<=WRITE;
                end
                WRITE: begin
                    row_x<=row_x+1'b1;remaining_x<=remaining_x-1'b1;row_has_output<=1;
                    if(remaining_x==1) state<=row_x+1==DST_W ? DROP:RIGHT;
                    else begin xrem<=xrem+{src_w,1'b0};state<=XNORM;end
                end
                RIGHT: begin row_x<=row_x+1'b1;if(row_x+1==DST_W) state<=DROP;end
                DROP: if(sy>cache_y) begin settle<=4;state<=SETTLE;end
                SETTLE: if(settle==0) state<=READ_START;else settle<=settle-1'b1;
                READ_START: state<=EMIT;
                EMIT: if(out_valid && out_ready) begin
                    if(ox==DST_W-1) begin
                        ox<=0;oy<=oy+1'b1;
                        if(oy==DST_H-1) state<=DRAIN;
                        else begin yrem<=yrem+{src_h,1'b0};state<=YNORM;end
                    end else ox<=ox+1'b1;
                end
                BLACK: if(out_ready) begin
                    if(ox==DST_W-1) begin
                        ox<=0;oy<=oy+1'b1;
                        if(oy==DST_H-1) state<=DRAIN;
                        else if(oy+1==bottom) state<=SEEK;
                    end else ox<=ox+1'b1;
                end
                DRAIN: if(sy==src_h) begin done<=1;state<=IDLE;end
                default: ;
            endcase
        end
    end
endmodule
