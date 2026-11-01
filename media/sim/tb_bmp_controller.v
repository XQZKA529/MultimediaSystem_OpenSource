`timescale 1ns/1ps
`include "pkg/fat_dir_bus.vh"
// Real parser/scaler/packer transaction coverage, with explicit presented barrier.
module tb_bmp_controller #(parameter CANCEL_GLITCH=0);
    reg clk=0,rst=1,md=0,ext=0,ack=0,fdv=0,fd=0,fok=1,finish=0,replay=0;
    reg [1:0] mode=0;
    reg [85:0] dir=0;reg [7:0] data=0,header[0:53];
    wire mount,ds,fs,wr,credit,success,failed,ready,displayed,rejected,we;
    wire [3:0] state,diag;wire [31:0] limit;wire [23:0] rgb;
    wire [31:0] word;wire wv,alignment,overflow;
    wire overlay_found;wire [31:0] overlay_cluster,overlay_size;
    reg output_ready=1;
    reg [5:0] interval_steps=1;
    reg interval_changed=0;
    reg injected_error=0;
    integer i,sw,sh,rs,total,words=0,successes=0,failures=0,pixels=0;
    always #5 clk=~clk;
    fat_bmp_controller #(.DST_W(8),.DST_H(4),.CLK_FREQ_HZ(10000),
        .LOAD_TIMEOUT_CYCLES(1000),.LOAD_ABS_TIMEOUT_CYCLES(50000),.LOAD_RETRY_MAX(1)) dut(
        .clk(clk),.rst(rst),.sd_init_done(1'b1),.sd_init_error(1'b0),.sd_init_err_code(8'd0),
        .action_prev(1'b0),.action_next(1'b0),.key_next(1'b1),.key_auto(1'b1),
        .replay_request(replay),.img_idle(),.img_ready(ready),.ext_load_req(ext),
        .ext_load_cluster(32'd3),.ext_load_size(32'd512),.ext_load_ack(),.ext_load_rejected(rejected),
        .auto_toggle(1'b0),.ui_active(1'b0),.auto_interval_steps(interval_steps),.auto_interval_changed(interval_changed),.auto_audio_active(1'b0),.auto_timer_hold(1'b0),.bmp_width(16'd8),.bmp_height(16'd4),
        .scale_mode(mode),.write_ready(output_ready),.write_error(injected_error || alignment || overflow),
        .file_burst_ready(credit),.load_success(success),.load_failed(failed),
        .mount_start(mount),.mount_done(md),.mount_ok(1'b1),.fat_error_code(8'd4),
        .dir_req(),.dir_gnt(1'b1),.dir_start(ds),.dir_dat(dir),.file_start(fs),
        .file_first_cluster(),.file_size(),.file_read_limit(limit),.file_data(data),
        .file_data_valid(fdv),.file_done(fd),.file_ok(fok),.file_busy(1'b0),.file_abort(),
        .write_finish_toggle(finish),.write_buf_idx(),.disp_buf_idx(),.write_req(wr),.write_req_ack(ack),
        .write_en(we),.write_data(rgb),.display_valid(displayed),.state_code(state),.diag_code(diag),
        .catalog_count(),.overlay_found(overlay_found),.overlay_cluster(overlay_cluster),.overlay_size(overlay_size),
        .o_wav_entry_valid(),.o_wav_entry_cluster(),.o_wav_entry_size());
    rgb888_word_packer #(.FRAME_PIXELS(32)) pack(.clk(clk),.rst(rst || failed),
        .frame_start(wr && ack),.pixel_valid(we),.pixel_rgb(rgb),.word_valid(wv),.word_data(word),
        .alignment_error(alignment),.overflow_error(overflow));
    always @(posedge clk) begin
        if(wr && ack) begin words=0;pixels=0;end
        if(wv) words=words+1;
        if(we) pixels=pixels+1;
        if(success) begin
            successes=successes+1;
            if(words!=24 || pixels!=32) $fatal(1,"source success before final packed word");
        end
        if(failed) begin
            failures=failures+1;
            if(CANCEL_GLITCH && !displayed) begin
                $display("cancel pulse: abort_error=%0d pixels=%0d",dut.abort_error,pixels);
                $fatal(1,"cancel decode pulse stranded active transaction");
            end
        end
    end
    task put32;input integer at;input [31:0] v;begin
        header[at]=v[7:0];header[at+1]=v[15:8];header[at+2]=v[23:16];header[at+3]=v[31:24];
    end endtask
    task make_header;input integer width,height;begin
        sw=width;sh=height;rs=(sw*3+3)&~3;total=54+rs*sh;
        for(i=0;i<54;i=i+1)header[i]=0;
        header[0]="B";header[1]="M";put32(2,total);put32(10,54);put32(14,40);
        put32(18,sw);put32(22,sh);header[26]=1;header[28]=24;
    end endtask
    task external;begin wait(ready);@(negedge clk);ext=1;@(negedge clk);ext=0;end endtask
    task probe_file;begin
        wait(fs);if(limit!=512)$fatal(1,"missing probe on replay");
        repeat(2)@(negedge clk);
        for(i=0;i<54;i=i+1)begin fdv=1;data=header[i];@(negedge clk);end
        fdv=0;fd=1;@(negedge clk);fd=0;
    end endtask
    task load_file;input bad;begin
        wait(wr);@(negedge clk);ack=1;@(negedge clk);ack=0;wait(fs);
        repeat(2)@(negedge clk);wait(credit);
        for(i=0;i<total;i=i+1)begin @(negedge clk);fdv=1;data=i<54 ? header[i]:8'h80;end
        @(negedge clk);fdv=0;fok=!bad;fd=1;@(negedge clk);fd=0;fok=1;
    end endtask
    task overlay_entry;integer j;reg [87:0] nm;begin
        nm="overlay.bmp";@(negedge clk);dir=0;dir[`VDIR_D_ESTART]=1;dir[`VDIR_D_FCLUST]=32'd77;dir[`VDIR_D_SIZE]=32'd12342;@(negedge clk);dir=0;
        for(j=0;j<11;j=j+1)begin dir[`VDIR_D_NVLD]=1;dir[`VDIR_D_CHAR]=nm[(11-j)*8-1 -:8];dir[`VDIR_D_INDEX]=j;@(negedge clk);dir=0;@(negedge clk);end
        dir[`VDIR_D_EEND]=1;@(negedge clk);dir=0;@(negedge clk);
    end endtask
    task presented;begin
        wait(state==7);repeat(20)@(negedge clk);
        finish=~finish;wait(ready);repeat(3)@(negedge clk);
    end endtask
    task second_tick;begin @(negedge clk);dut.auto_count=9999;@(posedge clk);#1;end endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;wait(mount);@(negedge clk);md=1;@(negedge clk);md=0;
        wait(ds);overlay_entry;dir[`VDIR_D_DONE]=1;dir[`VDIR_D_OK]=1;@(negedge clk);dir=0;
        if(!overlay_found || overlay_cluster!=77 || overlay_size!=12342 || dut.catalog_count!=0)$fatal(1,"reserved overlay directory entry was not isolated");
        make_header(1,1);external;probe_file;output_ready=0;load_file(0);
        repeat(100)@(negedge clk);if(successes!=0 || state!=6 || displayed)$fatal(1,"file_done committed stalled output");
        output_ready=1;presented;if(successes!=1 || !displayed)$fatal(1,"first frame");
        // A different geometry must replace the previous completed setup.
        make_header(3,5);external;probe_file;load_file(0);presented;
        if(dut.scaled_w!=2 || dut.scaled_h!=4 || successes!=2)$fatal(1,"stale geometry");
        @(negedge clk);replay=1;@(negedge clk);replay=0;probe_file;load_file(0);presented;
        if(successes!=3)$fatal(1,"replay completion");
        mode=1;external;probe_file;wait(rejected);if(wr)$fatal(1,"unsupported mode opened transaction");
        mode=0;make_header(2,2);external;probe_file;load_file(1);
        wait(failed);load_file(0);presented;if(failures!=1 || successes!=4)$fatal(1,"retry recovery");
        // A successful SD completion with a truncated byte stream is still an error.
        external;probe_file;wait(wr);@(negedge clk);ack=1;@(negedge clk);ack=0;wait(fs);
        repeat(2)@(negedge clk);fd=1;@(negedge clk);fd=0;
        wait(failed);load_file(1);wait(ready);
        if(failures!=3 || successes!=4 || !displayed)$fatal(1,"terminal error lost old image");
        make_header(1,1);external;probe_file;load_file(0);
        wait(pixels==8);@(negedge clk);injected_error=1;@(negedge clk);injected_error=0;
        wait(failed);load_file(0);presented;
        if(failures!=4 || successes!=5 || alignment || overflow)$fatal(1,"partial-frame retry kept stale packer phase");
        // Lose sink permission immediately after the last pixel, before pack drain.
        external;probe_file;output_ready=0;load_file(0);output_ready=1;
        wait(pixels==32);@(negedge clk);output_ready=0;
        repeat(100)@(negedge clk);
        if(successes!=5 || state!=6 || !displayed) $fatal(1,"success across final-word sink cancellation");
        output_ready=1;presented;
        if(successes!=6) $fatal(1,"final-word sink permission recovery");
        // Keep the current image and force only the existing coarse one-second
        // counter to its terminal value, checking 5-second step selection.
        @(negedge clk);dut.catalog_count=2;dut.auto_enable=1;dut.auto_count=0;
        dut.auto_five_sec=0;dut.auto_steps_left=1;dut.state=3;
        repeat(4) begin second_tick;if(state!=3) $fatal(1,"autoplay switched before five seconds");end
        second_tick;if(state==3) $fatal(1,"five-second autoplay interval did not switch");
        @(negedge clk);interval_steps=2;interval_changed=1;@(negedge clk);interval_changed=0;
        dut.auto_count=0;dut.auto_five_sec=0;dut.auto_steps_left=2;dut.state=3;
        repeat(5) begin second_tick;if(state!=3) $fatal(1,"ten-second autoplay interval switched at five seconds");end
        repeat(4) second_tick;
        if(state!=3) $fatal(1,"ten-second autoplay interval switched early");
        second_tick;if(state==3) $fatal(1,"ten-second autoplay interval did not switch");
        if(CANCEL_GLITCH) $display("*** PASS *** synchronous cancel ignores between-edge decode pulse: six complete frames, no startup ERROR 5");
        $display("*** PASS *** BMP retries/retention and 5/10-second autoplay interval thresholds");$finish;
    end
    // State decode hazards may pulse between edges as WAIT_WR(0101) becomes
    // LOAD(0110). Cancellation is a clocked command, not an async reset.
    initial if(CANCEL_GLITCH) begin
        wait(state==6);#1;force dut.pipeline_cancel=1'b1;#1;release dut.pipeline_cancel;
    end
    initial begin #2000000;$fatal(1,"controller watchdog state=%0d",state);end
endmodule
