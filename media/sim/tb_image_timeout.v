`timescale 1ns/1ps
`include "pkg/fat_dir_bus.vh"
module tb_image_timeout;
    reg clk=0,rst=1,mount_done=0,ext_req=0,ack=0,fdv=0,fdone=0,finish=0;
    reg [85:0] dir=0;
    reg [7:0] byte_data=0;
    wire mount_start,dir_start,file_start,write_req,ready,abort_file;
    wire [3:0] state,diag;
    wire [31:0] limit;
    integer p,which;
    time load_started;
    reg [7:0] header[0:53];
    always #5 clk=~clk;
    fat_bmp_controller #(.LOAD_TIMEOUT_CYCLES(100),.COMMIT_TIMEOUT_CYCLES(300),.DST_W(8),.DST_H(4),
        .LOAD_ABS_TIMEOUT_CYCLES(1550),.LOAD_RETRY_MAX(0)) dut(.action_prev(1'b0),.action_next(1'b0),
        .clk(clk),.rst(rst),.sd_init_done(1'b1),.sd_init_error(1'b0),.sd_init_err_code(8'd0),
        .key_next(1'b1),.key_auto(1'b1),.replay_request(1'b0),.img_idle(),.img_ready(ready),
        .ext_load_req(ext_req),.ext_load_cluster(32'd3),.ext_load_size(32'd500),
        .ext_load_ack(),.ext_load_rejected(),.auto_toggle(1'b0),.ui_active(1'b0),.auto_interval_steps(6'd1),.auto_interval_changed(1'b0),.auto_audio_active(1'b0),.auto_timer_hold(1'b0),
        .bmp_width(16'd8),.bmp_height(16'd4),.scale_mode(2'd0),.write_ready(1'b1),.write_error(1'b0),.file_burst_ready(),.load_success(),.load_failed(),.mount_start(mount_start),
        .mount_done(mount_done),.mount_ok(1'b1),.fat_error_code(8'd0),
        .dir_req(),.dir_gnt(1'b1),.dir_start(dir_start),.dir_dat(dir),
        .file_start(file_start),.file_first_cluster(),.file_size(),.file_read_limit(limit),
        .file_data(byte_data),.file_data_valid(fdv),.file_done(fdone),.file_ok(1'b1),
        .file_busy(1'b0),.file_abort(abort_file),.write_finish_toggle(finish),
        .write_buf_idx(),.disp_buf_idx(),.write_req(write_req),.write_req_ack(ack),
        .write_en(),.write_data(),.display_valid(),.state_code(state),.diag_code(diag),
        .catalog_count(),.o_wav_entry_valid(),.o_wav_entry_cluster(),.o_wav_entry_size());
    task launch;
        begin
            rst=1;finish=0;repeat(4) @(negedge clk);rst=0;
            wait(mount_start);@(negedge clk);mount_done=1;@(negedge clk);mount_done=0;
            wait(dir_start);@(negedge clk);dir[`VDIR_D_DONE]=1;dir[`VDIR_D_OK]=1;
            @(negedge clk);dir=0;wait(ready);
            @(negedge clk);ext_req=1;@(negedge clk);ext_req=0;
            wait(file_start);if(limit!=512) $fatal(1,"probe limit");
            for(p=0;p<54;p=p+1) begin @(negedge clk);fdv=1;byte_data=header[p];end
            @(negedge clk);fdv=0;fdone=1;@(negedge clk);fdone=0;
            wait(write_req);@(negedge clk);ack=1;@(negedge clk);ack=0;
            wait(file_start);
            load_started=$time;
      // Legal trailing bytes make loading approach its absolute deadline.
      // Commit must still receive its entire separate 300-cycle budget.
      for(p=0;p<500;p=p+1) begin @(negedge clk);fdv=1;byte_data=p<54 ? header[p]:8'h80;end
      @(negedge clk);fdv=0;fdone=1;@(negedge clk);fdone=0;
            wait(state==7);
            if(($time-load_started)/10<1400 || ($time-load_started)/10>=1550)
                $fatal(1,"fixture did not exercise loading near its absolute deadline");
        end
    endtask
    initial begin
        for(p=0;p<54;p=p+1)header[p]=0;
        header[0]="B";header[1]="M";header[2]=58;
        header[10]=54;header[14]=40;header[18]=1;header[22]=1;
        header[26]=1;header[28]=24;
        launch;
        repeat(150) @(negedge clk);
        if(state!=7 || abort_file) $fatal(1,"load watchdog incorrectly shortened commit deadline");
        finish=1;wait(ready);if(diag!=15) $fatal(1,"delayed successful presentation");
        launch;
        repeat(150) @(negedge clk);if(state!=7) $fatal(1,"commit deadline too short");
        wait(state==15);if(diag!=5) $fatal(1,"missing timeout ERROR 5");
        $display("*** PASS *** image commit uses independent deadline: delayed success and ERROR 5 timeout");$finish;
    end
    initial begin #1000000;$fatal(1,"image timeout test watchdog state=%0d",state);end
endmodule
