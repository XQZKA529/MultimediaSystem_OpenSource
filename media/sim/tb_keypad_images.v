`timescale 1ns/1ps
`include "pkg/fat_dir_bus.vh"
module tb_keypad_images;
    reg clk=0,rst=1,mount_done=0,ext_req=0,ack=0,fdv=0,fdone=0,finish=0;
    reg [85:0] dir=0;reg prev=0,nxt=0,ui=0,auto=0;reg [31:0] selected=20;wire [31:0] file_cluster;
    reg em_hold=0,restore=0;wire em_found,cat_done;wire [31:0] em_cluster;integer wav_count=0;wire wav_entry;
    always @(posedge clk) if(wav_entry) wav_count=wav_count+1;
    reg [7:0] byte_data=0;
    wire mount_start,dir_start,file_start,write_req,ready,abort_file;
    wire [3:0] state,diag;
    wire [31:0] limit;
    integer p,which;
    reg [7:0] header[0:53];
    always #5 clk=~clk;
    fat_bmp_controller #(.CLK_FREQ_HZ(1000),.LOAD_TIMEOUT_CYCLES(100),.COMMIT_TIMEOUT_CYCLES(300),.DST_W(8),.DST_H(4),
        .LOAD_ABS_TIMEOUT_CYCLES(3000),.LOAD_RETRY_MAX(0)) dut(.action_prev(prev),.action_next(nxt),
        .clk(clk),.rst(rst),.storage_hold(em_hold),.emergency_hold(em_hold),.restore_selection(restore),.restore_cluster(32'd20),.restore_size(32'd58),
        .emergency_found(em_found),.catalog_done(cat_done),.emergency_cluster(em_cluster),.sd_init_done(1'b1),.sd_init_error(1'b0),.sd_init_err_code(8'd0),
        .key_next(1'b1),.key_auto(1'b1),.replay_request(1'b0),.img_idle(),.img_ready(ready),
        .ext_load_req(ext_req),.ext_load_cluster(selected),.ext_load_size(32'd58),
        .ext_load_ack(),.ext_load_rejected(),.auto_toggle(auto),.ui_active(ui),.auto_interval_steps(6'd1),.auto_interval_changed(1'b0),.auto_audio_active(1'b0),.auto_timer_hold(1'b0),
        .bmp_width(16'd8),.bmp_height(16'd4),.scale_mode(2'd0),.write_ready(1'b1),.write_error(1'b0),.file_burst_ready(),.load_success(),.load_failed(),.mount_start(mount_start),
        .mount_done(mount_done),.mount_ok(1'b1),.fat_error_code(8'd0),
        .dir_req(),.dir_gnt(1'b1),.dir_start(dir_start),.dir_dat(dir),
        .file_start(file_start),.file_first_cluster(file_cluster),.file_size(),.file_read_limit(limit),
        .file_data(byte_data),.file_data_valid(fdv),.file_done(fdone),.file_ok(1'b1),
        .file_busy(1'b0),.file_abort(abort_file),.write_finish_toggle(finish),
        .write_buf_idx(),.disp_buf_idx(),.write_req(write_req),.write_req_ack(ack),
        .write_en(),.write_data(),.display_valid(),.state_code(state),.diag_code(diag),
        .catalog_count(),.o_wav_entry_valid(wav_entry),.o_wav_entry_cluster(),.o_wav_entry_size());
    task step;input integer n;begin repeat(n) @(negedge clk);end endtask
    task entry;input [31:0] cl;integer k;reg [31:0] name;begin
      @(negedge clk);name=".BMP";dir=0;dir[`VDIR_D_ESTART]=1;dir[`VDIR_D_FCLUST]=cl;dir[`VDIR_D_SIZE]=58;step(1);dir=0;
      for(k=0;k<4;k=k+1) begin dir[`VDIR_D_NVLD]=1;dir[`VDIR_D_CHAR]=name[(3-k)*8 +:8];step(1);end
      dir=0;dir[`VDIR_D_EEND]=1;step(1);dir=0;step(2);
    end endtask
    task wav_name;input [87:0] name;input integer length;input [31:0] cl;integer k;begin
      @(negedge clk);dir=0;dir[`VDIR_D_ESTART]=1;dir[`VDIR_D_FCLUST]=cl;dir[`VDIR_D_SIZE]=4096;step(1);dir=0;
      for(k=0;k<length;k=k+1) begin dir[`VDIR_D_NVLD]=1;dir[`VDIR_D_CHAR]=name[(length-k-1)*8+:8];step(1);end
      dir=0;dir[`VDIR_D_EEND]=1;step(1);dir=0;step(2);
    end endtask
    task complete;input [31:0] expected;begin
      if(state!=4) wait(file_start);if(file_cluster!=expected || limit!=512) $fatal(1,"selected cluster %d expected %d",file_cluster,expected);
      step(2);
      for(p=0;p<54;p=p+1) begin @(negedge clk);fdv=1;byte_data=header[p];end
      @(negedge clk);fdv=0;fdone=1;@(negedge clk);fdone=0;
      wait(write_req);@(negedge clk);ack=1;@(negedge clk);ack=0;
      wait(file_start);
      for(p=0;p<58;p=p+1) begin @(negedge clk);fdv=1;byte_data=p<54 ? header[p]:8'h80;end
      @(negedge clk);fdv=0;fdone=1;@(negedge clk);fdone=0;
      wait(state==7);@(negedge clk);finish=~finish;wait(ready);step(5);
    end endtask
    task direction;input back;begin @(negedge clk);prev=back;nxt=!back;step(1);prev=0;nxt=0;end endtask
    task external;input [31:0] cl;begin @(negedge clk);selected=cl;ext_req=1;step(1);ext_req=0;end endtask
    initial begin
        step(2);
      for(p=0;p<54;p=p+1)header[p]=0;
        header[0]="B";header[1]="M";header[2]=58;
        header[10]=54;header[14]=40;header[18]=1;header[22]=1;
        header[26]=1;header[28]=24;
        step(4);rst=0;wait(mount_start);@(negedge clk);mount_done=1;step(1);mount_done=0;
        wait(dir_start);wav_name("emerg.wav",9,99);wav_name("EMERG1.WAV",10,100);wav_name("SONG.WAV",8,101);entry(10);entry(20);entry(30);dir[`VDIR_D_DONE]=1;dir[`VDIR_D_OK]=1;step(1);dir=0;
        complete(10);
        if(!em_found || em_cluster!=99 || !cat_done || wav_count!=2) $fatal(1,"exact reserved name/playlist order found=%b cluster=%d done=%b count=%d",em_found,em_cluster,cat_done,wav_count);
        direction(1);complete(30);direction(0);complete(10);
        external(20);complete(20);direction(0);complete(30);
        external(40);complete(40);
        auto=1;step(1);auto=0;complete(10);auto=1;step(1);auto=0;
        external(40);complete(40);direction(1);complete(30);
        direction(0);wait(file_start);direction(0);direction(1);ui=1;
        // The probe is already active; complete() observes it before sending data.
        complete(10);step(20);if(file_start || !ready) $fatal(1,"pending navigation ignored UI gate");
        ui=0;complete(30);
        em_hold=1;auto=1;direction(1);step(2);auto=0;step(20);
        if(dut.auto_enable || dut.next_pending || !ready) $fatal(1,"emergency changed ordinary slideshow or queued input");
        restore=1;step(1);restore=0;wait(ready);step(2);em_hold=0;direction(0);complete(30);
        $display("*** PASS *** reserved EMERG.WAV, normal playlist, emergency gate/cursor restore and image prev/next/wrap/external alignment/outside catalog/auto fallback/busy last direction/UI gate");$finish;
    end
    initial begin #1000000;$fatal(1,"image timeout test watchdog state=%0d",state);end
endmodule

