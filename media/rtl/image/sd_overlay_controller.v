// Loads the reserved root OVERLAY.BMP and streams it as packed RGB565 pairs.
// The file must be a 64x64, 24-bit, bottom-up BI_RGB BMP (12342 bytes).
module sd_overlay_controller #(parameter integer WATCHDOG_CYCLES=25000000)(
    input wire clk,rst,link_up,session_reset,sd_ready,
    input wire catalog_done,overlay_found,input wire [31:0] overlay_cluster,overlay_size,
    input wire image_idle,image_valid,render_image_transport_idle,storage_idle,subtitle_busy,emergency_hold,ui_active,
    output reg file_start,output reg [31:0] file_cluster,file_size,file_read_limit,
    output reg file_abort,input wire file_busy,input wire [7:0] file_data,input wire file_valid,
    input wire file_done,file_ok,output wire file_ready,
    output reg begin_req,input wire begin_ack,begin_ready,begin_failed,
    output reg [31:0] begin_object,output reg abort_req,
    output reg word_valid,output reg [31:0] word_data,input wire word_ready,
    output reg source_ok,source_failed,input wire applied,output reg busy,output reg load_done
);
    localparam [3:0] IDLE=0,WAIT_READY=1,START_FILE=2,READ_FILE=3,WAIT_APPLY=4,FAILED=5;
    localparam [31:0] BMP_BYTES=32'd12342;
    reg [3:0] state;
    reg attempted;
    reg retry_after_cancel;
    reg retry_used;
    reg retry_for_begin_error;
    reg [31:0] watchdog_count;
    reg [13:0] byte_index;
    reg [1:0] component;
    reg [12:0] pixel_x,pixel_y;
    reg [7:0] blue,green;
    reg [15:0] low_pixel;
    reg [11:0] words_accepted;
    reg header_good,eof_seen;
    reg [30:0] object_counter;
    wire take_byte=file_valid && file_ready;
    assign file_ready=(state==READ_FILE) && (!word_valid || word_ready);
    function [7:0] expected_header_byte;
        input [5:0] idx;
        begin
            case(idx)
                0:expected_header_byte="B";1:expected_header_byte="M";
                2:expected_header_byte=8'h36;3:expected_header_byte=8'h30;
                4,5:expected_header_byte=0;
                10:expected_header_byte=8'h36;11,12,13:expected_header_byte=0;
                14:expected_header_byte=8'h28;15,16,17:expected_header_byte=0;
                18:expected_header_byte=8'h40;19,20,21:expected_header_byte=0;
                22:expected_header_byte=8'h40;23,24,25:expected_header_byte=0;
                26:expected_header_byte=1;27:expected_header_byte=0;
                28:expected_header_byte=24;29,30,31,32,33:expected_header_byte=0;
                default:expected_header_byte=8'hff;
            endcase
        end
    endfunction
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;attempted<=0;retry_after_cancel<=0;retry_used<=0;retry_for_begin_error<=0;watchdog_count<=0;file_start<=0;file_cluster<=0;file_size<=0;file_read_limit<=0;file_abort<=0;
            begin_req<=0;begin_object<=0;abort_req<=0;word_valid<=0;word_data<=0;source_ok<=0;source_failed<=0;
            busy<=0;load_done<=0;byte_index<=0;component<=0;pixel_x<=0;pixel_y<=0;blue<=0;green<=0;
            low_pixel<=0;words_accepted<=0;header_good<=1;eof_seen<=0;object_counter<=0;
        end else begin
            file_start<=0;file_abort<=0;abort_req<=0;source_failed<=0;
            if(word_valid && word_ready) begin
                word_valid<=0;
                if(words_accepted==12'd2047) begin
                    if(eof_seen) begin source_ok<=1;state<=WAIT_APPLY;end
                end
                words_accepted<=words_accepted+1'b1;
            end
            if(session_reset || !link_up) begin
                if(state!=IDLE) begin file_abort<=1;abort_req<=1;end
                state<=IDLE;attempted<=0;retry_after_cancel<=0;retry_used<=0;retry_for_begin_error<=0;watchdog_count<=0;busy<=0;begin_req<=0;word_valid<=0;source_ok<=0;load_done<=0;
            end else begin
                case(state)
                    IDLE:begin
                        busy<=0;begin_req<=0;source_ok<=0;word_valid<=0;
                        if(!attempted && sd_ready && catalog_done && overlay_found && image_idle && image_valid &&
                           render_image_transport_idle && storage_idle && !subtitle_busy &&
                           !emergency_hold && !ui_active) begin
                            attempted<=1;busy<=1;load_done<=0;object_counter<=object_counter+1'b1;
                            // Main image IDs are 24 bits. Keep overlay IDs in
                            // a separate namespace for shared ERROR responses.
                            begin_object<={1'b1,object_counter+31'd1};begin_req<=1;watchdog_count<=0;state<=WAIT_READY;
                        end
                    end
                    WAIT_READY:begin
                        if(begin_failed || emergency_hold || ui_active) begin
                            abort_req<=1;source_failed<=1;begin_req<=0;state<=FAILED;
                            watchdog_count<=0;
                            if(emergency_hold || ui_active) begin retry_after_cancel<=1;retry_for_begin_error<=0;end
                            else if(begin_failed && !retry_used) begin retry_after_cancel<=1;retry_for_begin_error<=1;end
                        end else if(begin_ready) begin
                            file_cluster<=overlay_cluster;file_size<=overlay_size;file_read_limit<=BMP_BYTES;
                            byte_index<=0;component<=0;pixel_x<=0;pixel_y<=0;words_accepted<=0;
                            header_good<=overlay_size==BMP_BYTES;eof_seen<=0;low_pixel<=0;watchdog_count<=0;
                            file_start<=1;state<=START_FILE;
                        end else if(watchdog_count>=WATCHDOG_CYCLES-1) begin
                            // A lost READY must not hold media's shared file/image scheduler forever.
                            begin_req<=0;abort_req<=1;source_failed<=1;watchdog_count<=0;state<=FAILED;
                            if(!retry_used) begin retry_after_cancel<=1;retry_for_begin_error<=1;end
                        end else begin
                            watchdog_count<=watchdog_count+1'b1;
                            if(begin_ack) begin_req<=0;
                        end
                    end
                    START_FILE:begin watchdog_count<=0;state<=READ_FILE;end
                    READ_FILE:begin
                        if(begin_failed || emergency_hold || ui_active || session_reset) begin
                            file_abort<=1;abort_req<=1;source_failed<=1;state<=FAILED;
                            watchdog_count<=0;
                            if(emergency_hold || ui_active) begin retry_after_cancel<=1;retry_for_begin_error<=0;end
                            else if(begin_failed && !retry_used) begin retry_after_cancel<=1;retry_for_begin_error<=1;end
                        end
                        if(take_byte) begin
                            watchdog_count<=0;
                            if(byte_index<54) begin
                                if(expected_header_byte(byte_index[5:0])!=8'hff &&
                                   file_data!=expected_header_byte(byte_index[5:0])) header_good<=0;
                                if(byte_index==53 && !header_good) begin
                                    file_abort<=1;abort_req<=1;source_failed<=1;state<=FAILED;
                                end
                            end else if(!header_good) begin
                                file_abort<=1;abort_req<=1;source_failed<=1;state<=FAILED;
                            end else begin
                                case(component)
                                    0:begin blue<=file_data;component<=1;end
                                    1:begin green<=file_data;component<=2;end
                                    2:begin
                                        component<=0;
                                        if(!pixel_x[0]) low_pixel<={file_data[7:3],green[7:2],blue[7:3]};
                                        else begin
                                            word_data<={{file_data[7:3],green[7:2],blue[7:3]},low_pixel};word_valid<=1;
                                        end
                                        if(pixel_x==63) begin pixel_x<=0;pixel_y<=pixel_y+1'b1;end
                                        else pixel_x<=pixel_x+1'b1;
                                    end
                                endcase
                            end
                            byte_index<=byte_index+1'b1;
                        end
                        if(file_done) begin
                            watchdog_count<=0;
                            if(!file_ok || byte_index!=BMP_BYTES || pixel_y!=64 || component!=0) begin
                                abort_req<=1;source_failed<=1;state<=FAILED;
                            end else eof_seen<=1;
                        end else if(!take_byte && watchdog_count>=WATCHDOG_CYCLES-1) begin
                            file_abort<=1;abort_req<=1;source_failed<=1;watchdog_count<=0;state<=FAILED;
                            if(!retry_used) begin retry_after_cancel<=1;retry_for_begin_error<=1;end
                        end else if(!take_byte) begin
                            watchdog_count<=watchdog_count+1'b1;
                        end
                    end
                    WAIT_APPLY:if(begin_failed || emergency_hold || ui_active) begin
                        source_ok<=0;source_failed<=1;abort_req<=1;busy<=0;load_done<=1;watchdog_count<=0;state<=FAILED;
                        if(emergency_hold || ui_active) begin retry_after_cancel<=1;retry_for_begin_error<=0;end
                        else if(begin_failed && !retry_used) begin retry_after_cancel<=1;retry_for_begin_error<=1;end
                    end else if(applied) begin source_ok<=0;busy<=0;load_done<=1;retry_used<=0;watchdog_count<=0;state<=IDLE;end
                    else if(watchdog_count>=WATCHDOG_CYCLES-1) begin
                        // APPLIED can be lost after a reset even when the pixel RAM write completed.
                        source_ok<=0;source_failed<=1;abort_req<=1;watchdog_count<=0;state<=FAILED;
                        if(!retry_used) begin retry_after_cancel<=1;retry_for_begin_error<=1;end
                    end else watchdog_count<=watchdog_count+1'b1;
                    FAILED:begin
                        source_ok<=0;word_valid<=0;attempted<=1;
                        if(!file_busy) begin
                            busy<=0;load_done<=1;watchdog_count<=0;state<=IDLE;
                            if(retry_after_cancel) begin
                                attempted<=0;
                                if(retry_for_begin_error) retry_used<=1;
                            end
                            retry_after_cancel<=0;
                            retry_for_begin_error<=0;
                        end
                        else busy<=1;
                    end
                    default:state<=IDLE;
                endcase
                if(state==READ_FILE && eof_seen && words_accepted==12'd2048 && !word_valid) begin
                    source_ok<=1;state<=WAIT_APPLY;
                end
            end
        end
    end
endmodule
