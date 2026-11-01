// Adapts non-preemptible, <=2048-byte (4-sector) file bursts to a stallable RGB scaler.
module bmp_image_pipeline #(parameter DST_W=1280,DST_H=720)(
    input wire clk,rst,start,cancel,input wire [12:0] src_w,src_h,
    input wire [31:0] pixel_offset,row_stride,
    input wire [15:0] scaled_w,scaled_h,left,bottom,
    input wire [7:0] file_data,input wire file_valid,file_done,file_ok,
    output wire burst_ready,output wire pixel_valid,output wire [23:0] pixel_rgb,
    input wire pixel_ready,output wire progress,output reg done,failed
);
    reg [7:0] mem[0:4095] /* fehdl force_ram=1, ram_style="bram" */;
    reg [12:0] wp,rp;
    reg [7:0] q,hold;
    reg hv,pending,active,eof,success,credit;
    reg [2:0] empty_age;
    wire [12:0] free_bytes=13'd4096-(wp-rp);
    wire byte_ready,source_valid,source_ready,decode_done,scale_done;
    wire [23:0] source_rgb;
    wire clear=rst || start || cancel;
    wire empty=wp==rp && !pending && !hv;
    // Register the occupancy comparison to break the FIFO-to-FAT FSM path.
    // A burst is at most 4 sectors (2048 B); 2080 guarantees at least 2048 B
    // when the downstream reader uses the registered credit.
    assign burst_ready=active && !failed && !eof && credit;
    assign progress=active && (file_valid || (hv && byte_ready) ||
        (source_valid && source_ready) || (pixel_valid && pixel_ready));
    // All stages sample cancel on clk, matching FIFO/transaction ownership.
    // FSM decode hazards cannot asynchronously clear only part of the pipeline.
    bmp_pixel_unpack unpack(.clk(clk),.rst(rst),.start(start),.cancel(cancel),
        .width(src_w),.height(src_h),.pixel_offset(pixel_offset),.row_stride(row_stride),
        .byte_valid(hv),.byte_data(hold),.byte_ready(byte_ready),
        .pixel_valid(source_valid),.pixel_rgb(source_rgb),.pixel_ready(source_ready),.done(decode_done));
    image_scale_nearest #(.DST_W(DST_W),.DST_H(DST_H)) scaler(
        .clk(clk),.rst(rst),.start(start),.cancel(cancel),.src_w(src_w),.src_h(src_h),
        .scaled_w(scaled_w),.scaled_h(scaled_h),.left(left),.bottom(bottom),
        .in_valid(source_valid),.in_rgb(source_rgb),.in_ready(source_ready),
        .out_valid(pixel_valid),.out_rgb(pixel_rgb),.out_ready(pixel_ready),.done(scale_done));
    always @(posedge clk) begin
        if(active && file_valid && free_bytes!=0 && !clear) mem[wp[11:0]]<=file_data;
        q<=mem[rp[11:0]];
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin wp<=0;rp<=0;hv<=0;pending<=0;active<=0;eof<=0;success<=0;done<=0;failed<=0;hold<=0;empty_age<=0;credit<=0;end
        else if(start || cancel) begin
            wp<=0;rp<=0;hv<=0;pending<=0;active<=start;eof<=0;success<=0;done<=0;failed<=0;empty_age<=0;credit<=0;
        end else if(active) begin
            credit<=free_bytes>=2080;
            if(file_valid) begin if(free_bytes!=0) wp<=wp+1'b1;else failed<=1;end
            if(hv && byte_ready) begin hv<=0;rp<=rp+1'b1;end
            if(!hv && !pending && wp!=rp) pending<=1;
            else if(pending) begin hold<=q;hv<=1;pending<=0;end
            if(file_done) begin eof<=1;success<=file_ok;if(!file_ok) failed<=1;end
            if(eof && empty && !file_valid) begin if(empty_age!=7) empty_age<=empty_age+1'b1;end
            else empty_age<=0;
            if(eof && empty && !file_valid) begin
                if(empty_age>=4 && !decode_done && !source_valid) failed<=1;
                if(success && decode_done && scale_done) begin done<=1;active<=0;end
            end
        end
    end
endmodule
