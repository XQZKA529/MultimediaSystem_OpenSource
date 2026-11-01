// Root-directory BMP catalog and FAT file-stream to framebuffer adapter.
// img_idle / img_ready：跨模块空闲契约（替代暴露 FSM 状态编码）。
// dir_req/dir_gnt：目录口授权式申请（c0，优先低于 file_browser）。
// dir_dat：目录数据面捆绑（E1，位分配见 pkg/fat_dir_bus.vh）。
`include "../pkg/fat_dir_bus.vh"
`include "../pkg/image_scale_modes.vh"
module fat_bmp_controller #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer LOAD_TIMEOUT_CYCLES = CLK_FREQ_HZ,
    parameter integer LOAD_ABS_TIMEOUT_CYCLES = CLK_FREQ_HZ * 15,
    // C_COMMIT（等待 render 的 PRESENTED/完成反馈）专用：3 秒无进展超时。
    //   动画本身约 0.5s，加上写回/校验/握手余量，3s 足够宽裕；
    //   超时说明对端停滞，按失败处理（保留旧图）。
    parameter integer COMMIT_TIMEOUT_CYCLES = CLK_FREQ_HZ * 3,
    parameter integer LOAD_RETRY_MAX = 2,
    parameter integer KEY_DEBOUNCE_MS = 50,
    parameter integer CATALOG_MAX = 256,
    parameter integer DST_W = 1280, DST_H = 720
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        sd_init_done,
    input  wire        sd_init_error,
    input  wire [7:0]  sd_init_err_code,
    input wire action_prev,action_next,
    input wire storage_hold,
    input wire ctx_req,ctx_we,input wire [3:0] ctx_addr,ctx_read_addr,input wire [63:0] ctx_data,
    output wire ctx_ready,output wire [63:0] ctx_q,
    input wire emergency_hold,restore_selection,input wire [31:0] restore_cluster,restore_size,
    output reg emergency_found,catalog_done,output reg [31:0] emergency_cluster,emergency_size,
    output reg overlay_found,output reg [31:0] overlay_cluster,overlay_size,
    output wire [31:0] presented_file_cluster,presented_file_size,
    input  wire        key_next,
    input  wire        key_auto,
    input  wire        replay_request,
    // ---- 跨模块空闲契约（不再暴露 state 编码给 UI）----
    output wire        img_idle,            // 1 = 可占用目录口（C_READY 或 C_ERROR）
    output wire        img_ready,           // 1 = 仅 C_READY（自动轮播开关等）
    output wire        auto_enabled,
    // ---- 文件浏览器接入（2026-09-21 新增，见 rtl/ui/file_browser.v）----
    input  wire        ext_load_req,        // 外部指定簇号加载请求（1 拍，只能在 C_READY 被接受）
    input  wire [31:0] ext_load_cluster,    // 请求携带的起始簇号
    input  wire [31:0] ext_load_size,       // 请求携带的文件字节数
    output reg         ext_load_ack,        // 探测通过、决定加载（1 拍）
    output reg         ext_load_rejected,   // 探测不通过（不是合法 BMP），软错误（1 拍）
    input  wire        auto_toggle,         // 自动轮播开/关翻转脉冲（窗口关闭时长按 KEY2）
    input  wire        ui_active,           // 浏览器窗口可见期间轮播强制暂停
    input  wire [5:0]  auto_interval_steps, // 1..60, 每档 5 秒
    input  wire        auto_interval_changed,
    input wire auto_audio_active,
    input wire auto_timer_hold,
    input  wire [15:0] bmp_width,
    input  wire [15:0] bmp_height,
    input wire [1:0] scale_mode,
    input wire write_ready,
    input wire write_error,
    output wire file_burst_ready,
    output reg load_success,load_failed,

    output reg         mount_start,
    input  wire        mount_done,
    input  wire        mount_ok,
    input  wire [7:0]  fat_error_code,
    output wire        dir_req,             // 申请目录口（C_DIR 全程）
    input  wire        dir_gnt,             // 授权后才允许 dir_start
    output reg         dir_start,
    input  wire [`VDIR_DBUS_W-1:0] dir_dat,
    output reg         file_start,
    output reg [31:0]  file_first_cluster,
    output reg [31:0]  file_size,
    output reg [31:0]  file_read_limit,
    input  wire [7:0]  file_data,
    input  wire        file_data_valid,
    input  wire        file_done,
    input  wire        file_ok,
    input  wire        file_busy,
    output reg         file_abort,

    input  wire        write_finish_toggle,
    output reg [1:0]   write_buf_idx,
    output reg [1:0]   disp_buf_idx,
    output reg         write_req,
    input  wire        write_req_ack,
    output wire        write_en,
    output wire [23:0] write_data,
    output reg         display_valid,
    output wire [3:0]  state_code,          // 仅 DBG / TB；非跨模块控制契约
    output wire [3:0]  diag_code,
    output reg [8:0]   catalog_count,

    // ---- .WAV 目录捕获（供音频播放列表"下一首"）----
    //  搭开机那次 C_DIR 枚举的车：与上面 BMP 分支并列、同一拍判定，复用同一个
    //  suffix 滚窗与 fold()（大小写不敏感）。本模块只**转发**条目流，
    //  曲目表与"当前第几首"游标由 wav_playlist 维护 ⇒ 图像链对音频零职责。
    //  ★ 仍受 state==C_DIR 门控：浏览器枚举时这里看到的 dir_* 串扰会被挡掉。
    output wire        o_wav_entry_valid,
    output wire [31:0] o_wav_entry_cluster,
    output wire [31:0] o_wav_entry_size
);

// E1: dir_dat 捆绑 unpack —— 原信号名保持，FSM 体零改动
wire        dir_entry_start         = dir_dat[`VDIR_D_ESTART];
wire        dir_name_valid          = dir_dat[`VDIR_D_NVLD];
wire [7:0]  dir_name_char           = dir_dat[`VDIR_D_CHAR];
wire [7:0]  dir_name_index          = dir_dat[`VDIR_D_INDEX];
wire        dir_entry_end           = dir_dat[`VDIR_D_EEND];
wire [31:0] dir_entry_first_cluster = dir_dat[`VDIR_D_FCLUST];
wire [31:0] dir_entry_size          = dir_dat[`VDIR_D_SIZE];
wire        dir_entry_is_dir        = dir_dat[`VDIR_D_ISDIR];
wire        dir_done                = dir_dat[`VDIR_D_DONE];
wire        dir_ok                  = dir_dat[`VDIR_D_OK];

localparam C_WAIT_SD=4'd0, C_MOUNT=4'd1, C_DIR=4'd2, C_READY=4'd3,
           C_PROBE=4'd4, C_WAIT_WR=4'd5, C_LOAD=4'd6, C_COMMIT=4'd7,
           C_ABORT=4'd8, C_CAT_ADDR=4'd9, C_CAT_LOAD=4'd10,
           C_ALIGN_ADDR=4'd11,C_ALIGN_CHECK=4'd12,C_ALIGN_DECIDE=4'd13,
           C_ALIGN_EVAL=4'd14,
           C_ERROR=4'd15;
reg [3:0] state;
reg align_match,align_last;
reg [3:0] align_equal;
// The original demo kept four entries in registers.  A compact 64-bit metadata
// RAM now stores up to 256 {first_cluster,file_size} records.  Its synchronous
// read is deliberately isolated behind C_CAT_ADDR/C_CAT_LOAD so increasing the
// catalog does not create a 64-way mux on the 100 MHz control path.
reg [63:0] catalog_mem [0:511] /* fehdl force_ram=1, ram_style="bram" */;
reg [7:0] cat_addr;
reg [63:0] cat_q;
reg [7:0] current_index, load_index;
reg catalog_aligned;
reg [1:0] pending_buf;
// Rolling suffix predicates replace four character registers. Each stage
// describes the same last 1..4 characters used by the original comparisons.
reg suffix_dot,suffix_b,suffix_bm,suffix_bmp,suffix_w,suffix_wa,suffix_wav;
reg entry_dir;
reg [31:0] entry_cluster, entry_size;
wire [12:0] hdr_width,hdr_height;
wire [31:0] pixel_offset,row_stride,payload_end;
wire hdr_done,hdr_ok,geometry_done,geometry_ok,pipe_done,pipe_failed,pipe_progress;
wire [15:0] scaled_w,scaled_h,left,bottom;
reg probe_start,probe_finished,probe_success,geometry_kicked;
reg [1:0] mode_latched;
reg [2:0] drain_age;
reg completion_credit;
wire geometry_start=state==C_PROBE && probe_finished && !probe_start && hdr_done && hdr_ok && !geometry_kicked;
wire pipeline_start=state==C_WAIT_WR && write_req_ack;
wire pipeline_cancel=state!=C_LOAD && !pipeline_start;
wire pipeline_valid;
assign write_en=state==C_LOAD && pipeline_valid && write_ready;
bmp_header_parser header_parser(.clk(clk),.rst(rst),.start(probe_start),
    .byte_valid(file_data_valid && state==C_PROBE),.byte_data(file_data),
    .finish(file_done && state==C_PROBE),.actual_size(file_size),.done(hdr_done),.ok(hdr_ok),
    .width(hdr_width),.height(hdr_height),.pixel_offset(pixel_offset),
    .row_stride(row_stride),.payload_end(payload_end));
image_scale_geometry geometry(.clk(clk),.rst(rst),.start(geometry_start),
    .src_w(hdr_width),.src_h(hdr_height),.dst_w(bmp_width),.dst_h(bmp_height),
    .mode(mode_latched),.done(geometry_done),.ok(geometry_ok),
    .scaled_w(scaled_w),.scaled_h(scaled_h),.left(left),.bottom(bottom));
bmp_image_pipeline #(.DST_W(DST_W),.DST_H(DST_H)) pipeline(
    .clk(clk),.rst(rst),.start(pipeline_start),.cancel(pipeline_cancel),
    .src_w(hdr_width),.src_h(hdr_height),.pixel_offset(pixel_offset),.row_stride(row_stride),
    .scaled_w(scaled_w),.scaled_h(scaled_h),.left(left),.bottom(bottom),
    .file_data(file_data),.file_valid(file_data_valid && state==C_LOAD),
    .file_done(file_done && state==C_LOAD),.file_ok(file_ok),.burst_ready(file_burst_ready),
    .pixel_valid(pipeline_valid),.pixel_rgb(write_data),.pixel_ready(write_ready && state==C_LOAD),
    .progress(pipe_progress),.done(pipe_done),.failed(pipe_failed));
reg source_done, write_done;
reg [2:0] wr_tgl_sync;
reg [$clog2(CLK_FREQ_HZ+1)-1:0] auto_count;
reg [2:0] auto_five_sec;
reg [5:0] auto_steps_left;
reg auto_enable, next_pending;reg pending_prev;
reg ext_pending;                 // 当前这次 probe/加载来自 ext_load_req（外部指定文件）
reg [3:0] local_error;
reg [$clog2(LOAD_TIMEOUT_CYCLES+1)-1:0] op_timeout_count;
reg [$clog2(LOAD_ABS_TIMEOUT_CYCLES+1)-1:0] op_total_count;
// C_COMMIT 专用无进展计时：任何推进（PRESENTED 到达、写完成脉冲）都会清零。
reg [$clog2(COMMIT_TIMEOUT_CYCLES+1)-1:0] commit_age;
reg [2:0] load_retry_count;
reg abort_is_probe, abort_terminal;
reg [3:0] abort_error;
reg soft_error_valid;
reg [$clog2(CLK_FREQ_HZ+1)-1:0] soft_error_count;
reg dir_kicked;
reg replay_pending;
reg [31:0] presented_cluster,presented_size;
reg emergency_name_match;reg [3:0] emergency_name_length;
reg overlay_name_match;reg [4:0] overlay_name_length;
function [7:0] emergency_name_char;
 input [3:0] index;
 begin case(index)
 0:emergency_name_char="E";1:emergency_name_char="M";2:emergency_name_char="E";
 3:emergency_name_char="R";4:emergency_name_char="G";5:emergency_name_char=".";
 6:emergency_name_char="W";7:emergency_name_char="A";8:emergency_name_char="V";
 default:emergency_name_char=0;endcase end
endfunction
function [7:0] overlay_name_char;
 input [4:0] i;
 begin case(i)
 0:overlay_name_char="O";1:overlay_name_char="V";2:overlay_name_char="E";
 3:overlay_name_char="R";4:overlay_name_char="L";5:overlay_name_char="A";
 6:overlay_name_char="Y";7:overlay_name_char=".";8:overlay_name_char="B";
 9:overlay_name_char="M";10:overlay_name_char="P";default:overlay_name_char=0;
 endcase end
endfunction
// Directory metadata is stable on the entry-end handshake. The playlist
// captures it on that same edge, eliminating an unnecessary 64-bit copy.
assign o_wav_entry_valid=state==C_DIR && dir_entry_end && !entry_dir &&
    suffix_wav &&
    !(emergency_name_match && emergency_name_length==9);
assign o_wav_entry_cluster=entry_cluster;assign o_wav_entry_size=entry_size;
assign presented_file_cluster=presented_cluster;assign presented_file_size=presented_size;

wire key_next_pulse, key_auto_pulse;
wire write_finish_pulse=wr_tgl_sync[2]^wr_tgl_sync[1];
wire auto_second_tick=(auto_count==CLK_FREQ_HZ-1);
wire auto_tick=auto_second_tick && auto_five_sec==3'd4 && auto_steps_left<=1;
assign auto_enabled=auto_enable;
wire step_prev=next_pending && pending_prev;
wire [7:0] advanced_index=current_index+(step_prev ? 8'hff:8'd1);
wire [7:0] next_index=(catalog_count<=1) ? 8'd0:
    step_prev ? (current_index==0 ? catalog_count-1'b1:advanced_index):
                ({1'b0,current_index}+9'd1>=catalog_count ? 8'd0:advanced_index);

// Private watchdog write enables keep retry/error dispatch out of the wide
// counter CE. Probe start resets a retry one cycle after it is requested;
// timeout dispatch is suppressed on that same start edge. The write request
// acknowledgement begins a new absolute deadline for the full-file transfer.
always @(posedge clk or posedge rst) begin
 if(rst) begin op_timeout_count<=0;op_total_count<=0;end
 else if((state!=C_PROBE && state!=C_WAIT_WR && state!=C_LOAD) || probe_start) begin
  op_timeout_count<=0;op_total_count<=0;
 end else begin
  if(file_data_valid || pipe_progress || write_en || write_req_ack || write_finish_pulse)
   op_timeout_count<=0;
  else if(op_timeout_count<LOAD_TIMEOUT_CYCLES) op_timeout_count<=op_timeout_count+1'b1;
  if(write_req_ack) op_total_count<=0;
  else if(op_total_count<LOAD_ABS_TIMEOUT_CYCLES) op_total_count<=op_total_count+1'b1;
 end
end

always @(posedge clk) begin
  cat_q <= catalog_mem[(ctx_ready && ctx_req===1'b1) ? {5'b10000,ctx_read_addr}:{1'b0,cat_addr}];
end

// 256 ordinary entries + a reserved metadata page. Both geometries map to
// four BRAM9K blocks on EG4; only idle/error states grant the shared ports.
assign ctx_ready=state!=C_DIR && state!=C_CAT_ADDR && state!=C_CAT_LOAD &&
    state!=C_ALIGN_ADDR && state!=C_ALIGN_CHECK && state!=C_ALIGN_DECIDE && state!=C_ALIGN_EVAL;
assign ctx_q=cat_q;
wire is_overlay_entry=overlay_name_match && overlay_name_length==11;
wire catalog_write=state==C_DIR && dir_entry_end && !entry_dir && !is_overlay_entry &&
    suffix_bmp && catalog_count<CATALOG_MAX;
always @(posedge clk) begin
  if(ctx_ready && ctx_req===1'b1 && ctx_we) catalog_mem[{5'b10000,ctx_addr}]<=ctx_data;
  else if(catalog_write) catalog_mem[{1'b0,catalog_count[7:0]}]<={entry_cluster,entry_size};
end
assign state_code=state;
assign img_idle  = (state==C_READY) || (state==C_ERROR);
assign img_ready = (state==C_READY);
assign dir_req   = (state==C_DIR);
// Busy states are not errors.  Code 15 means "no error overlay"; a real SD/FAT
// failure is shown separately and can no longer be confused with LOADING.
assign diag_code = sd_init_error ? ((sd_init_err_code[3:0]==0)?4'd1:sd_init_err_code[3:0]) :
                   (state==C_ERROR) ? local_error :
                   soft_error_valid ? local_error : 4'd15;

key_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(KEY_DEBOUNCE_MS), .HOLD_MS(2000)) u_next
 (.clk(clk),.rst(rst),.button_in(key_next),.press_pulse(key_next_pulse),.release_pulse(),.hold_pulse());
key_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(KEY_DEBOUNCE_MS), .HOLD_MS(2000)) u_auto
 (.clk(clk),.rst(rst),.button_in(key_auto),.press_pulse(key_auto_pulse),.release_pulse(),.hold_pulse());

function [7:0] fold;
 input [7:0] c;
 begin fold=(c[7:6]==2'b01 && c[5] && c[4:0]!=0 && c[4:0]<=5'd26)?{c[7:6],1'b0,c[4:0]}:c; end
endfunction
function [3:0] error_digit;
 input [7:0] c;
 begin
   // The on-screen overlay has one decimal digit.  FAT code 10 is an I/O
   // timeout, represented as generic file error 4 instead of a blank glyph.
   error_digit=(c==0)?4'd4:((c<=9)?c[3:0]:4'd4);
 end
endfunction
task queue_catalog_probe;
 input [7:0] n;
 begin
   load_index<=n;cat_addr<=n;ext_pending<=0;state<=C_CAT_ADDR;
   load_retry_count<=0;
   soft_error_valid<=0;
 end
endtask

// Start a bounded probe; metadata and geometry are rebuilt on every replay.
task stream_lane_reset;
 begin
   file_read_limit<=512;file_start<=1;probe_start<=1;
   probe_finished<=0;probe_success<=0;geometry_kicked<=0;
   mode_latched<=scale_mode;
 end
endtask

// 外部指定文件（文件浏览器选中的条目）：探测链完全复用，只是簇号/大小来自端口
task begin_probe_ext;
 begin
   file_first_cluster<=ext_load_cluster; file_size<=ext_load_size;
   stream_lane_reset;
   ext_pending<=1; state<=C_PROBE;
   load_retry_count<=0;
   soft_error_valid<=0;
 end
endtask

task retry_probe_or_fail;
 input [3:0] code;
 begin
   if (load_retry_count < LOAD_RETRY_MAX) begin
     load_retry_count<=load_retry_count+1'b1;
     stream_lane_reset;
    state<=C_PROBE;
   end else if (display_valid) begin
     local_error<=code;soft_error_valid<=1;soft_error_count<=CLK_FREQ_HZ;
     if (!ext_pending) current_index<=load_index;
     ext_pending<=0;state<=C_READY;
   end else begin
     local_error<=code;state<=C_ERROR;
   end
 end
endtask

task abort_then_retry_or_fail;
 input is_probe;
 input [3:0] code;
 begin
   file_abort<=1;abort_is_probe<=is_probe;abort_error<=code;
   if(!is_probe) load_failed<=1;
   source_done<=0;write_done<=0;write_req<=0;
   if (load_retry_count < LOAD_RETRY_MAX) begin
     load_retry_count<=load_retry_count+1'b1;
     abort_terminal<=0;state<=C_ABORT;
   end else begin
     abort_terminal<=1;state<=C_ABORT;
   end

 end
endtask

always @(posedge clk or posedge rst) begin
 if (rst) begin
   state<=C_WAIT_SD; mount_start<=0;dir_start<=0;file_start<=0;dir_kicked<=0;
   file_first_cluster<=0;file_size<=0;file_read_limit<=0;catalog_count<=0;
   suffix_dot<=0;suffix_b<=0;suffix_bm<=0;suffix_bmp<=0;suffix_w<=0;suffix_wa<=0;suffix_wav<=0;entry_dir<=0;entry_cluster<=0;entry_size<=0;
   write_req<=0;probe_start<=0;probe_finished<=0;probe_success<=0;geometry_kicked<=0;
   mode_latched<=0;drain_age<=0;completion_credit<=0;load_success<=0;load_failed<=0;
   write_buf_idx<=0;disp_buf_idx<=0;display_valid<=0;current_index<=0;
   load_index<=0;pending_buf<=0;cat_addr<=0;source_done<=0;write_done<=0;wr_tgl_sync<=0;
   // ★ 自动轮播复位默认 = 0（原实现是 1，卡里 ≥2 张图时上电即每秒切图，
   //   与 README §4.8 的描述不符；本任务按用户决定改为默认关闭）。
   auto_count<=0;auto_five_sec<=0;auto_steps_left<=1;auto_enable<=0;next_pending<=0;pending_prev<=0;local_error<=0;
   ext_pending<=0;ext_load_ack<=0;ext_load_rejected<=0;
   load_retry_count<=0;soft_error_valid<=0;soft_error_count<=0;
   commit_age<=0;
   file_abort<=0;abort_is_probe<=0;abort_terminal<=0;abort_error<=0;
    catalog_aligned<=1;align_match<=0;align_last<=0;align_equal<=0;
   replay_pending<=0;presented_cluster<=0;presented_size<=0;
   emergency_found<=0;catalog_done<=0;emergency_cluster<=0;emergency_size<=0;
   overlay_found<=0;overlay_cluster<=0;overlay_size<=0;
   emergency_name_match<=0;emergency_name_length<=0;
   overlay_name_match<=0;overlay_name_length<=0;

 end else begin
   // 注意：dir_kicked 是跨拍粘滞位，不能放进每拍默认清零表，否则 dir_start 会连打。
   mount_start<=0;dir_start<=0;file_start<=0;file_abort<=0;
   probe_start<=0;load_success<=0;load_failed<=0;
   if(geometry_start) geometry_kicked<=1;
   if(state==C_PROBE && file_done) begin probe_finished<=1;probe_success<=file_ok;end
   if(state==C_LOAD && pipe_done) drain_age<=drain_age+1'b1;else drain_age<=0;
   // Completion checks the previous cycle's sink permission. Four drain
   // cycles already cover the final packed word's delivery; sampling here
   // isolates network occupancy/state from the transaction FSM timing path.
   completion_credit<=write_ready;
   ext_load_ack<=0;ext_load_rejected<=0;
   // ★ .WAV 转发是 1 拍脉冲：默认每拍清零（放在 C_DIR 门外，枚举结束/换态也干净）。
   //   曾经只在 dir_entry_end 里清——匹配条目之后 valid 保持 1 直到下一个条目
   //   结束，wav_playlist 把每拍都当成新条目，表被第一首的复制品填满
   //   （wav_cnt 饱和到 WAV_MAX），双击"下一首"永远取到第一首。

   wr_tgl_sync<={wr_tgl_sync[1:0],write_finish_toggle};
   if(replay_request) replay_pending<=1;

   if (soft_error_valid) begin
     if (soft_error_count==0) soft_error_valid<=0;
     else soft_error_count<=soft_error_count-1'b1;
   end
   // C_COMMIT 专用：3 秒无进展超时。进入 C_COMMIT 起计时；任何来自 render 的
   // 推进（write_finish_pulse / write_req_ack）都清零。动画约 0.5s，3s 宽裕；
   // 超时按失败处理（abort_then_retry_or_fail），保留旧图。
   if (state==C_COMMIT) begin
     if (write_finish_pulse || write_req_ack) commit_age<=0;
     else if (commit_age < COMMIT_TIMEOUT_CYCLES) commit_age<=commit_age+1'b1;
   end else commit_age<=0;

   //-------------------------------------------------------------------------
   // 目录条目捕获：★ 只在 C_DIR 生效。
   //   开机后 fat32_ro 的 dir 口会给文件浏览器复用（storage_service req/gnt），
   //   浏览器枚举时这里会看到串进来的 dir_* 脉冲。用 state==C_DIR 门控，
   //   既有语义（只有自己在枚举时才是自己的响应），又顺手挡掉串扰。
   //-------------------------------------------------------------------------
   if (state==C_DIR) begin
   if (dir_entry_start) begin
     suffix_dot<=0;suffix_b<=0;suffix_bm<=0;suffix_bmp<=0;suffix_w<=0;suffix_wa<=0;suffix_wav<=0;emergency_name_match<=1;emergency_name_length<=0;
     overlay_name_match<=1;overlay_name_length<=0;
     entry_dir<=dir_entry_is_dir;entry_cluster<=dir_entry_first_cluster;entry_size<=dir_entry_size;
   end
   if (dir_name_valid) begin
     suffix_dot<=fold(dir_name_char)==".";
     suffix_b<=suffix_dot && fold(dir_name_char)=="B";
     suffix_bm<=suffix_b && fold(dir_name_char)=="M";
     suffix_bmp<=suffix_bm && fold(dir_name_char)=="P";
     suffix_w<=suffix_dot && fold(dir_name_char)=="W";
     suffix_wa<=suffix_w && fold(dir_name_char)=="A";
     suffix_wav<=suffix_wa && fold(dir_name_char)=="V";
     if(emergency_name_length!=15) emergency_name_length<=emergency_name_length+1'b1;
     if(emergency_name_length>=9 || fold(dir_name_char)!=emergency_name_char(emergency_name_length)) emergency_name_match<=0;
     if(overlay_name_length!=31) overlay_name_length<=overlay_name_length+1'b1;
     if(overlay_name_length>=11 || fold(dir_name_char)!=overlay_name_char(overlay_name_length)) overlay_name_match<=0;
   end
   if (dir_entry_end && !entry_dir && is_overlay_entry) begin
     overlay_found<=1;overlay_cluster<=entry_cluster;overlay_size<=entry_size;
   end
   if (dir_entry_end && !entry_dir && !is_overlay_entry && suffix_bmp) begin
     if (catalog_count<CATALOG_MAX) begin
       catalog_count<=catalog_count+1;
     end
   end
   // .WAV 捕获：与 BMP 分支并列、同一拍判定（复用 suffix/fold）。
   // 只在匹配拍置 1（默认清零在每拍默认表里）⇒ 严格的 1 拍脉冲。
   if (dir_entry_end && !entry_dir && suffix_wav) begin
     if(emergency_name_match && emergency_name_length==9) begin
       emergency_found<=1;emergency_cluster<=entry_cluster;emergency_size<=entry_size;
     end

   end
   end

   // A replacement frame is an atomic operation.  计划扩展：加载或动画期间
   // 的切图按键合并为**一次待执行切换**（next_pending 置位，不累计次数），
   // 当前切换结束后执行。条件是已有有效图片且浏览器窗口关闭。
   //   · C_READY 时沿用既有语义（display_valid 即可排队）。
   //   · 加载/动画阶段（C_PROBE/C_WAIT_WR/C_LOAD/C_COMMIT）也允许置位，
   //     保证忙时按键不被吞掉。
   //   · 浏览器打开（ui_active）时不驱动新请求；已在途的 next_pending 保留，
   //     窗口关闭后继续执行。
   if ((key_next_pulse || action_next || action_prev) && display_valid && catalog_count!=0 && !ui_active &&
       ((state==C_READY) || (state==C_PROBE) || (state==C_WAIT_WR) ||
         (state==C_LOAD) || (state==C_COMMIT) || (state==C_ALIGN_ADDR) || (state==C_ALIGN_CHECK) ||
         (state==C_ALIGN_EVAL) || (state==C_ALIGN_DECIDE)))
     begin next_pending<=1;pending_prev<=action_prev;auto_count<=0;auto_five_sec<=0;auto_steps_left<=auto_interval_steps;end
   if (key_auto_pulse && catalog_count>1 && emergency_hold!==1'b1) begin auto_enable<=~auto_enable;auto_count<=0;auto_five_sec<=0;auto_steps_left<=auto_interval_steps;end
   // 浏览器窗口关闭时长按 KEY2 → 轮播开关翻转
   if (auto_toggle && catalog_count>1 && emergency_hold!==1'b1) begin auto_enable<=~auto_enable;auto_count<=0;auto_five_sec<=0;auto_steps_left<=auto_interval_steps;end
   // ★ ui_active 期间轮播暂停（只停计数器，不动 auto_enable，用户设定不丢）
   if (state==C_READY && display_valid && auto_enable && catalog_count>1 && !ui_active && !auto_audio_active && !auto_timer_hold) begin
     if (auto_second_tick) begin
       auto_count<=0;
       if(auto_five_sec==3'd4) begin
         auto_five_sec<=0;
         if(auto_steps_left<=1) auto_steps_left<=auto_interval_steps;
         else auto_steps_left<=auto_steps_left-1'b1;
         if(auto_tick && storage_hold===1'b1 && !action_prev && !action_next && !key_next_pulse) begin next_pending<=1;pending_prev<=0;end
       end else auto_five_sec<=auto_five_sec+1'b1;
     end else auto_count<=auto_count+1'b1;
   end else begin auto_count<=0;auto_five_sec<=0;end
   if((action_prev || action_next || key_next_pulse) && !ui_active) begin auto_count<=0;auto_five_sec<=0;auto_steps_left<=auto_interval_steps;end
   if(auto_interval_changed===1'b1) begin
     auto_count<=0;auto_five_sec<=0;auto_steps_left<=auto_interval_steps;
   end

   if ((state==C_LOAD)||(state==C_COMMIT)) begin
     if (write_finish_pulse) write_done<=1;
   end

   if(emergency_hold===1'b1) begin next_pending<=0;auto_count<=0;auto_five_sec<=0;end
   case(state)
     C_WAIT_SD: begin
       if (sd_init_error) begin local_error<=4'd1;state<=C_ERROR;end
       else if (sd_init_done) begin mount_start<=1;state<=C_MOUNT;end
     end
     C_MOUNT: if (mount_done) begin
       if (mount_ok) begin catalog_count<=0;dir_kicked<=0;overlay_found<=0;state<=C_DIR;end
       else begin local_error<=error_digit(fat_error_code);state<=C_ERROR;end
     end
     C_DIR: begin
       // 授权后才发 dir_start 一拍，避免与 file_browser 争用时脉冲被吞
       if (!dir_kicked && dir_gnt) begin
         dir_start<=1'b1;
         dir_kicked<=1'b1;
       end
       if (dir_done) begin
         catalog_done<=dir_ok;
         dir_kicked<=1'b0;
         if (!dir_ok) begin local_error<=error_digit(fat_error_code);state<=C_ERROR;end
         // 音频模式允许卡中只有 WAV、没有 BMP。目录枚举成功但 BMP 目录为空
         // 不是存储故障：进入 READY 后文件浏览器仍可重新枚举并选择 WAV。
         else if (catalog_count==0) begin local_error<=4'd0;state<=C_READY;end
         else queue_catalog_probe(8'd0);
       end
     end
     // Two registered stages implement the synchronous catalog RAM read.
     C_CAT_ADDR: state<=C_CAT_LOAD;
     C_CAT_LOAD: begin
       file_first_cluster<=cat_q[63:32];file_size<=cat_q[31:0];
       stream_lane_reset;
       state<=C_PROBE;
     end
     C_PROBE: if ((file_done && !file_ok) || (probe_finished && hdr_done && (!hdr_ok || (geometry_kicked && geometry_done)))) begin
       if ((file_done && !file_ok) || !probe_success) begin
         retry_probe_or_fail(error_digit(fat_error_code));
       end else if (!hdr_ok || !geometry_ok) begin
         // Header and geometry must both pass before opening a remote transaction.
         if (ext_pending) begin
           // ★ 软错误：外部（文件浏览器）选中的不是合法 BMP —— 回告拒绝并回到
           //   C_READY，**绝不进 C_ERROR**，否则用户点一次错文件就把图像层打死。
           ext_load_rejected<=1; ext_pending<=0; state<=C_READY;
         end else if (display_valid) begin
           // A bad later catalog entry must not kill an already running
           // slideshow.  Mark it consumed so the next press can skip it.
           local_error<=4'd4;soft_error_valid<=1;soft_error_count<=CLK_FREQ_HZ;
           current_index<=load_index;ext_pending<=0;state<=C_READY;
         end else begin
           local_error<=4'd4;state<=C_ERROR;
         end
       end else begin
         if (ext_pending) ext_load_ack<=1;   // 探测通过：接受这次加载
         pending_buf<=display_valid ? (disp_buf_idx==0?1:0) : 0;
         write_buf_idx<=display_valid ? (disp_buf_idx==0?1:0) : 0;
         write_req<=1;state<=C_WAIT_WR;
       end
     end else if (!probe_start && ((op_timeout_count>=LOAD_TIMEOUT_CYCLES-1) ||
                  (op_total_count>=LOAD_ABS_TIMEOUT_CYCLES-1)))
       abort_then_retry_or_fail(1'b1,4'd5);
      C_WAIT_WR: if (write_req_ack) begin
        write_req<=0;
        // The catalog record (or external request) was latched by the probe
        // path and remains stable for the following full-file read.
        file_read_limit<=0;file_start<=1;
        source_done<=0;write_done<=0;state<=C_LOAD;

     end else if (!probe_start && ((op_timeout_count>=LOAD_TIMEOUT_CYCLES-1) ||
                  (op_total_count>=LOAD_ABS_TIMEOUT_CYCLES-1)))
       abort_then_retry_or_fail(1'b0,4'd5);
     C_LOAD: if (pipe_failed || write_error || (file_done && !file_ok)) begin
       abort_then_retry_or_fail(1'b0,error_digit(fat_error_code));
     end else if(pipe_done && drain_age==4 && completion_credit) begin
       // Four drain cycles include the final packer/controller pipeline word.
       // Registered sink credit confirms the transaction survived that drain;
       // a link/session cancellation at the last pixel must not report success.
       // Commit gets its own deadline even if loading approached the 15s cap.
       load_success<=1;source_done<=1;state<=C_COMMIT;
     end else if (!probe_start && ((op_timeout_count>=LOAD_TIMEOUT_CYCLES-1) ||
                  (op_total_count>=LOAD_ABS_TIMEOUT_CYCLES-1)))
       abort_then_retry_or_fail(1'b0,4'd5);
     C_COMMIT: if (source_done&&(write_done||write_finish_pulse)) begin
       presented_cluster<=file_first_cluster;presented_size<=file_size;
       disp_buf_idx<=pending_buf;
       if (!ext_pending) current_index<=load_index;
       ext_pending<=0;
       display_valid<=1;
       source_done<=0;write_done<=0;state<=C_READY;load_retry_count<=0;
       if(ext_pending) begin cat_addr<=0;catalog_aligned<=0;if(catalog_count!=0) state<=C_ALIGN_ADDR;end
       else catalog_aligned<=1;
       soft_error_valid<=0;
     end else if (commit_age>=COMMIT_TIMEOUT_CYCLES-1)
       abort_then_retry_or_fail(1'b0,4'd5);
     C_ABORT: if (!file_busy) begin
       if (abort_terminal) begin
         if (display_valid) begin
           local_error<=abort_error;soft_error_valid<=1;soft_error_count<=CLK_FREQ_HZ;
           if (!ext_pending) current_index<=load_index;
           ext_pending<=0;state<=C_READY;
         end else begin
           local_error<=abort_error;state<=C_ERROR;
         end
       end else if (abort_is_probe) begin
         stream_lane_reset;
          state<=C_PROBE;
       end else begin
         write_req<=1;state<=C_WAIT_WR;
       end
     end
     C_ALIGN_ADDR:state<=C_ALIGN_CHECK;
      C_ALIGN_CHECK:begin
        align_equal[0]<=cat_q[15:0]==presented_size[15:0];
        align_equal[1]<=cat_q[31:16]==presented_size[31:16];
        align_equal[2]<=cat_q[47:32]==presented_cluster[15:0];
        align_equal[3]<=cat_q[63:48]==presented_cluster[31:16];
       align_last<={1'b0,cat_addr}+9'd1>=catalog_count;
        state<=C_ALIGN_EVAL;
     end
      C_ALIGN_EVAL:begin align_match<=&align_equal;state<=C_ALIGN_DECIDE;end
     C_ALIGN_DECIDE:begin
       if(align_match) begin
         current_index<=cat_addr;catalog_aligned<=1;state<=C_READY;
       end else if(align_last) state<=C_READY;
       else begin cat_addr<=cat_addr+1'b1;state<=C_ALIGN_ADDR;end
     end
     C_READY: if(storage_hold!==1'b1) begin
       if(replay_pending && display_valid) begin
         replay_pending<=0;
         file_first_cluster<=presented_cluster;file_size<=presented_size;
         stream_lane_reset;ext_pending<=1;state<=C_PROBE;
         source_done<=0;write_done<=0;load_retry_count<=0;
       end else if (ext_load_req) begin
         // 外部指定文件：复用 C_PROBE→C_WAIT_WR→C_LOAD→C_COMMIT 全链，写侧零改动。
         // ★ 显式选择图片优先：清除此前的待切图排队（计划要求）。
         next_pending<=0;
         begin_probe_ext;
       end else if (next_pending && !ui_active) begin
         // ★ 浏览器打开时不执行待切图；关闭后继续（next_pending 保留）。
         next_pending<=0;queue_catalog_probe(catalog_aligned ? next_index:(step_prev ? catalog_count-1'b1:8'd0));
       end else if (auto_enable && auto_tick && !ui_active) begin
         queue_catalog_probe(catalog_aligned ? next_index:8'd0);
       end
     end
     C_ERROR: begin
       if(storage_hold!==1'b1 && replay_pending && catalog_count!=0) begin replay_pending<=0;queue_catalog_probe(current_index);end
     end
     default:state<=C_WAIT_SD;
   endcase
   if(restore_selection===1'b1 && ((state==C_READY)||(state==C_ERROR))) begin
     presented_cluster<=restore_cluster;presented_size<=restore_size;display_valid<=1;
     file_first_cluster<=restore_cluster;file_size<=restore_size;
     cat_addr<=0;catalog_aligned<=0;next_pending<=0;auto_count<=0;auto_five_sec<=0;auto_steps_left<=auto_interval_steps;
     if(catalog_count!=0) state<=C_ALIGN_ADDR;else state<=C_READY;
   end
 end
end
endmodule
