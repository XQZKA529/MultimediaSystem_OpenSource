`timescale 1ns/1ps
`include "pkg/fat_dir_bus.vh"
// File-service model around the production BMP controller and RGB888 packer.
module tb_bmp_network_source #(parameter TARGET_W=32,TARGET_H=18)(
    input wire clk,rst,launch,ack,finish,pixel_ready,
    output wire req,word_valid,success,failed,output wire [31:0] word
);
    reg md=0,ext=0,fv=0,fd=0;reg [85:0] dir=0;
    reg [7:0] data=0,header[0:53];
    wire mount,ds,fs,ready,credit,we;wire [31:0] limit;wire [23:0] rgb;
    wire alignment,overflow;
    integer i,px,py;reg [23:0] c;
    localparam W=7,H=13,STRIDE=24,SIZE=54+STRIDE*H;
    fat_bmp_controller #(.DST_W(TARGET_W),.DST_H(TARGET_H)) controller(
        .clk(clk),.rst(rst),.sd_init_done(1'b1),.sd_init_error(1'b0),.sd_init_err_code(8'd0),
        .action_prev(1'b0),.action_next(1'b0),.key_next(1'b1),.key_auto(1'b1),.replay_request(1'b0),
        .img_idle(),.img_ready(ready),.ext_load_req(ext),.ext_load_cluster(32'd3),.ext_load_size(SIZE),
        .ext_load_ack(),.ext_load_rejected(),.auto_toggle(1'b0),.ui_active(1'b0),.auto_interval_steps(6'd1),.auto_interval_changed(1'b0),.auto_audio_active(1'b0),.auto_timer_hold(1'b0),
        .bmp_width(TARGET_W[15:0]),.bmp_height(TARGET_H[15:0]),.scale_mode(2'd0),.write_ready(pixel_ready),
        .write_error(alignment || overflow),.file_burst_ready(credit),.load_success(success),.load_failed(failed),
        .mount_start(mount),.mount_done(md),.mount_ok(1'b1),.fat_error_code(8'd0),
        .dir_req(),.dir_gnt(1'b1),.dir_start(ds),.dir_dat(dir),.file_start(fs),.file_first_cluster(),
        .file_size(),.file_read_limit(limit),.file_data(data),.file_data_valid(fv),.file_done(fd),.file_ok(1'b1),
        .file_busy(1'b0),.file_abort(),.write_finish_toggle(finish),.write_buf_idx(),.disp_buf_idx(),
        .write_req(req),.write_req_ack(ack),.write_en(we),.write_data(rgb),.display_valid(),.state_code(),
        .diag_code(),.catalog_count(),.o_wav_entry_valid(),.o_wav_entry_cluster(),.o_wav_entry_size());
    rgb888_word_packer #(.FRAME_PIXELS(TARGET_W*TARGET_H)) packer(.clk(clk),.rst(rst || failed),
        .frame_start(req && ack),.pixel_valid(we),.pixel_rgb(rgb),.word_valid(word_valid),.word_data(word),
        .alignment_error(alignment),.overflow_error(overflow));
    function [23:0] color;input integer x,y;reg [7:0] r,g,b;begin
        r=x*17+y*3;g=x*5+y*29;b=x*11+y*7;color={r,g,b};
    end endfunction
    initial begin
        for(i=0;i<54;i=i+1)header[i]=0;
        header[0]="B";header[1]="M";header[2]=SIZE%256;header[3]=SIZE/256;
        header[10]=54;header[14]=40;header[18]=W;header[22]=H;header[26]=1;header[28]=24;
        wait(!rst);wait(mount);@(negedge clk);md=1;@(negedge clk);md=0;
        wait(ds);@(negedge clk);dir[`VDIR_D_DONE]=1;dir[`VDIR_D_OK]=1;@(negedge clk);dir=0;
        wait(ready && launch);@(negedge clk);ext=1;@(negedge clk);ext=0;
        wait(fs);repeat(2)@(negedge clk);
        for(i=0;i<54;i=i+1)begin fv=1;data=header[i];@(negedge clk);end
        fv=0;fd=1;@(negedge clk);fd=0;
        wait(fs && limit==0);repeat(2)@(negedge clk);wait(credit);
        for(i=0;i<SIZE;i=i+1)begin
            @(negedge clk);fv=1;
            if(i<54)data=header[i];
            else begin
                px=(i-54)%STRIDE;py=H-1-(i-54)/STRIDE;c=color(px/3,py);
                data=px>=W*3 ? 8'hcc:c[(px%3)*8+:8];
            end
        end
        @(negedge clk);fv=0;fd=1;@(negedge clk);fd=0;
    end
endmodule
