`include "pkg/video_bmp_params.vh"
`include "pkg/osd_model_bus.vh"
`include "pkg/text_osd_model.vh"
module render_core(
    input wire [32:0] clock_live,clock_draft,input wire [2:0] clock_focus,input wire clock_editing,
    output wire clock_editor_ready,output wire emergency_view_vs,
    input wire emergency_view_enable,input wire [2:0] emergency_sources,input wire [8:0] emergency_groups,
    input wire [143:0] emergency_timestamps,
    input wire [1:0] emergency_mode,input wire emergency_audio_allowed,
    input wire [31:0] emergency_audio_epoch,audio_epoch,
    input wire emergency_restore_valid,emergency_image_idle,input wire [1:0] emergency_restore_index,
    output wire emergency_picture_restored,
    input wire subtitle_session_reset,subtitle_start,input wire [31:0] subtitle_revision,output wire subtitle_start_ready,
    input wire subtitle_data_valid,input wire [31:0] subtitle_data,input wire subtitle_last,output wire subtitle_data_ready,
    output wire subtitle_applied,input wire subtitle_applied_ready,output wire [31:0] subtitle_applied_revision,output wire [1:0] subtitle_applied_result,
    input wire [31:0] display_image_id,
    input wire clk,rst,input wire mem_clk,mem_clk_sft,mem_rst,
    input wire video_clk,video_5x_clk,video_rst,
    input wire image_write_req,image_write_abort,image_write_en,input wire [31:0] image_write_data,
    input wire [1:0] image_write_index,image_display_index,input wire image_display_valid,
    // ---- 交叉淡化事务邮箱（网络域 → 视频域，字段保持稳定）----
    input wire transition_req,input wire [1:0] transition_new_index,transition_cur_index,transition_req_mode,
    output wire transition_ack,transition_done,transition_failed,
    output wire image_write_ack,image_abort_ack,image_write_full,image_write_ready,image_write_finish_toggle,
    output wire [1:0] image_read_index,output wire image_read_handoff_toggle,
    input wire volume_valid,volume_hint,volume_cancel,input wire [4:0] volume_level,
    input wire [4:0] contrast_level,input wire [4:0] saturation_level,input wire [3:0] brightness_level,output wire [1:0] brightness_mode,
    input wire text_osd_page,input wire [3:0] ui_page,
    input wire [`TEXT_OSD_META_W-1:0] text_osd_metadata,input wire [31:0] text_osd_revision,
    output wire [7:0] text_osd_edit_addr,input wire [7:0] text_osd_edit_data,
    input wire ui_active,ui_cursor_en,ui_commit_toggle,input wire [3:0] ui_cursor_row,
    input wire ui_wr_en,input wire [8:0] ui_wr_addr,input wire [7:0] ui_wr_data,output wire ui_commit_seen,
    input wire [3:0] diag,input wire link_up,
    input wire overlay_write_en,input wire [10:0] overlay_write_addr,input wire [31:0] overlay_write_data,
    input wire overlay_prepare_toggle,overlay_commit_toggle,output wire overlay_prepare_ack,overlay_commit_ack,
    input wire audio_valid,input wire [23:0] audio_left,audio_right,
    input wire [31:0] audio_position,audio_total,input wire audio_playing,audio_paused,audio_restart,
    output wire vs,
    output wire HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P,inout wire HDMI_DDC_SCL,HDMI_DDC_SDA,
    output wire VGA_HS,VGA_VS,output wire [7:0] VGA_R,VGA_G,VGA_B
);
    localparam MEM_DATA_BITS=32,ADDR_BITS=21;
    localparam H_ACTIVE=`VBP_H_ACTIVE,H_FRONT=`VBP_H_FRONT,H_SYNC=`VBP_H_SYNC,H_BACK=`VBP_H_BACK;
    localparam V_ACTIVE=`VBP_V_ACTIVE,V_FRONT=`VBP_V_FRONT,V_SYNC=`VBP_V_SYNC,V_BACK=`VBP_V_BACK;
    localparam LINE_WORDS=`VBP_LINE_WORDS,FRAME_WORDS=`VBP_FRAME_WORDS;
    localparam [20:0] BUF0_ADDR=`VBP_BUF0_ADDR,BUF1_ADDR=`VBP_BUF1_ADDR;
    function [9:0] ease_slide_rows;
        input [4:0] k;
        begin case(k)
            0:ease_slide_rows=0;1:ease_slide_rows=47;2:ease_slide_rows=93;3:ease_slide_rows=137;
            4:ease_slide_rows=179;5:ease_slide_rows=220;6:ease_slide_rows=259;7:ease_slide_rows=297;
            8:ease_slide_rows=333;9:ease_slide_rows=367;10:ease_slide_rows=400;11:ease_slide_rows=431;
            12:ease_slide_rows=461;13:ease_slide_rows=489;14:ease_slide_rows=515;15:ease_slide_rows=540;
            16:ease_slide_rows=563;17:ease_slide_rows=585;18:ease_slide_rows=605;19:ease_slide_rows=623;
            20:ease_slide_rows=640;21:ease_slide_rows=655;22:ease_slide_rows=669;23:ease_slide_rows=681;
            24:ease_slide_rows=691;25:ease_slide_rows=700;26:ease_slide_rows=707;27:ease_slide_rows=713;
            28:ease_slide_rows=717;29:ease_slide_rows=719;default:ease_slide_rows=720;
        endcase end
    endfunction
    wire ext_mem_clk=mem_clk,ext_mem_clk_sft=mem_clk_sft,rst_mem=mem_rst;
    wire sd_card_clk=clk,rst_sd=rst,rst_video=video_rst,hdmi_5x_clk=video_5x_clk;
    (* async_reg="true" *) reg [1:0] em_active_sync,em_voice_sync,em_restore_sync;
    // Synchronize levels, not a two-bit state transition (01 -> 10).
    wire [1:0] em_mode2=em_active_sync[1] ? (em_restore_sync[1] ? 2'd2:2'd1):2'd0;
    (* async_reg="true" *) reg em_allow1,em_allow2;
    (* async_reg="true" *) reg em_idle1,em_idle2;
    reg [31:0] em_epoch1,em_epoch2;
    always @(posedge video_clk or posedge video_rst) begin
        if(video_rst) begin em_active_sync<=0;em_voice_sync<=0;em_restore_sync<=0;
            em_allow1<=0;em_allow2<=0;em_epoch1<=0;em_epoch2<=0;em_idle1<=0;em_idle2<=0;end
        else begin
            em_active_sync<={em_active_sync[0],emergency_mode===2'd1 || emergency_mode===2'd2};
            em_voice_sync<={em_voice_sync[0],emergency_mode===2'd1};
            em_restore_sync<={em_restore_sync[0],emergency_mode===2'd2};
            em_allow1<=emergency_audio_allowed;em_allow2<=em_allow1;
            em_epoch1<=emergency_audio_epoch;em_epoch2<=em_epoch1;
            em_idle1<=emergency_image_idle;em_idle2<=em_idle1;
        end
    end
    wire em_audio_ok=em_allow2 && audio_epoch==em_epoch2;
    wire em_mute=em_mode2==2 || (em_mode2==1 && !em_audio_ok);
    // ---- 显示索引：由切换事务控制器仲裁 ----
    // seam_render 的提交邮箱（image_display_index/valid）给出**提交意图**；
    // 事务控制器在动画期间保持旧图扫描（disp_index_out 不变），动画结束时
    // 把显示切到新图。无动画时事务控制器输出直通提交意图，基线行为不变。
    wire display_valid;
    wire [1:0] disp_buf_idx;
    wire [1:0] write_buf_idx=image_write_index;
    wire sd_write_req=image_write_req;
    wire sd_write_req_ack,video_write_sector_ready;
    wire packed_write_en=image_write_en;wire [31:0] packed_write_data=image_write_data;
    wire frame_write_finish;
    reg frame_write_toggle_mem;
    always @(posedge mem_clk or posedge mem_rst)
        if(mem_rst) frame_write_toggle_mem<=0;else if(frame_write_finish) frame_write_toggle_mem<=~frame_write_toggle_mem;
    assign image_write_finish_toggle=frame_write_toggle_mem;
    wire br_ui_active=ui_active,br_cursor_en=ui_cursor_en,br_ui_commit=ui_commit_toggle,br_ui_wr_en=ui_wr_en;
    wire [3:0] br_cursor_row=ui_cursor_row;wire [8:0] br_ui_wr_addr=ui_wr_addr;wire [7:0] br_ui_wr_data=ui_wr_data;
    wire [`OSD_M_W-1:0] osd_model;
    // Hide the playback card and its spectrum on all non-playback scenes.
    // Masking the existing SHOW bit keeps the audio OSD interface and model
    // payload unchanged while preserving the spectrum values during playback.
    wire audio_osd_scene_active = link_frame && !err_show && !frame_black &&
        !ui_active_frame && !emergency_view_enable && !emergency_frame_active;
    wire [`OSD_M_W-1:0] audio_osd_model = {
        osd_model[`OSD_M_W-1:`OSD_M_SHOW+1],
        (osd_model[`OSD_M_SHOW] && audio_osd_scene_active),
        osd_model[`OSD_M_SHOW-1:0]
    };
    wire [`OSD_M_SPEC_W-1:0] fft_heights;
    wire sdr_init_done;
    wire sdr_init_ref_vld;
    wire sdr_busy;
    // sdram.v 共享 App_* 口（经 sdram_app_arb）
    wire app_rd_en;
    wire [ADDR_BITS-1:0] app_rd_addr;
    wire sdr_rd_en;
    wire [MEM_DATA_BITS-1:0] sdr_rd_dout;
    wire app_wr_en;
    wire [ADDR_BITS-1:0] app_wr_addr;
    wire [MEM_DATA_BITS-1:0] app_wr_din;
    wire [3:0] app_wr_dm;
    // frame_read_write 帧侧 App_*（高优先）
    wire frm_app_rd_en;
    wire [ADDR_BITS-1:0] frm_app_rd_addr;
    wire frm_sdr_rd_en;
    wire [MEM_DATA_BITS-1:0] frm_sdr_rd_dout;
    wire frm_app_wr_en;
    wire [ADDR_BITS-1:0] frm_app_wr_addr;
    wire [MEM_DATA_BITS-1:0] frm_app_wr_din;
    wire [3:0] frm_app_wr_dm;
    // audio_burst_to_app 音频侧 App_*：ENABLE_AUDIO=0，a_* 输入在实例处直接绑 0。
    // E0：曾有的 aud_app_* 线网已删——输入无驱动、输出无消费者，悬空 z 会
    // 经 sdram_app_arb 的无门控 mux（空闲拍选 a_App_*）传播到 SDRAM 口。

    wire video_read_req;
    wire video_read_req_ack_mem;
    (* async_reg="true" *) reg [1:0] read_ack_sync;
    wire video_read_req_ack=read_ack_sync[1];
    wire read_dual_mem;
    (* async_reg="true" *) reg [2:0] handoff_sync,trans_req_sync;
    (* async_reg="true" *) reg [1:0] dual_sync;
    reg [1:0] selected_sync1,selected_sync2;
    always @(posedge video_clk or posedge video_rst) begin
        if(video_rst) begin
            read_ack_sync<=0;handoff_sync<=0;trans_req_sync<=0;dual_sync<=0;
            selected_sync1<=0;selected_sync2<=0;
        end else begin
            read_ack_sync<={read_ack_sync[0],video_read_req_ack_mem};
            handoff_sync<={handoff_sync[1:0],image_read_handoff_toggle};
            trans_req_sync<={trans_req_sync[1:0],transition_req};
            dual_sync<={dual_sync[0],read_dual_mem};
            selected_sync1<=image_read_index;selected_sync2<=selected_sync1;
        end
    end
    wire video_read_en;
    wire [31:0] video_read_data;
    wire video_read_empty;

    // ---- 第二路（新图）读通路：交叉淡化动画期使用 ----
    wire video_read_en1;
    wire [31:0] video_read_data1;
    wire video_read_empty1;
    wire video_read_ready;
    wire mix_active;                        // 动画进行中（禁写两张缓存）
    wire mix_lane1_en;                      // 本帧是否读第二路
    wire [1:0] lane1_buf_idx;               // 新图缓存索引
    wire [ADDR_BITS-1:0] lane1_buf_addr = (2'd0 == lane1_buf_idx) ? BUF0_ADDR : BUF1_ADDR;
    // lane1 未使能时把读使能钉死为 0，避免 FIFO 被误取空
    wire video_read_en1_g = mix_lane1_en ? video_read_en1 : 1'b0;

    wire video_write_full;
    reg  write_fifo_overflow_sticky;
    wire hs_raw;
    wire vs_raw;
    wire de_raw;
    wire hs_pix;
    wire vs_pix;
    wire de_pix;
    wire [23:0] rgb_raw;
    // 无图时先给黑底，再由 error_overlay / ui_text_overlay 决定叠加什么。
    // （rgb_base 在混合器之后定义，见下方 pixel_mixer 段）

    video_timing_data #(
        .H_ACTIVE(H_ACTIVE), .H_FRONT(H_FRONT), .H_SYNC(H_SYNC), .H_BACK(H_BACK),
        .V_ACTIVE(V_ACTIVE), .V_FRONT(V_FRONT), .V_SYNC(V_SYNC), .V_BACK(V_BACK),
        .HS_POL(1'b1), .VS_POL(1'b1)
    ) u_video_timing (
        .video_clk(video_clk), .rst(rst_video),
        .read_req(video_read_req), .read_req_ack(video_read_req_ack),
        .hs(hs_raw), .vs(vs_raw), .de(de_raw)
    );

    wire display_underflow_sticky;
    wire old_pixel_valid;
    rgb888_word_reader u_rgb888_word_reader (
        .clk(video_clk), .rst(rst_video),
        .frame_start(video_read_req_ack),
        .hs_in(hs_raw), .vs_in(vs_raw), .de_in(de_raw),
        .fifo_empty(video_read_empty), .fifo_read_en(video_read_en),
        .fifo_read_data(video_read_data),
        .hs_out(hs_pix), .vs_out(vs_pix), .de_out(de_pix), .pixel_rgb(rgb_raw),
        .underflow_sticky(display_underflow_sticky),
        .pixel_valid(old_pixel_valid)
    );

    // ---- 第二路解包：新图，与旧图共用同一帧开始与视频时序 ----
    // 两路 frame_start / hs / vs / de 完全同源，因此同一坐标的两路像素同拍输出。
    wire hs_pix1, vs_pix1, de_pix1, new_pixel_valid, new_underflow_sticky;
    wire [23:0] rgb_raw1;
    rgb888_word_reader u_rgb888_word_reader1 (
        .clk(video_clk), .rst(rst_video),
        .frame_start(video_read_req_ack),
        .hs_in(hs_raw), .vs_in(vs_raw), .de_in(de_raw),
        .fifo_empty(video_read_empty1), .fifo_read_en(video_read_en1),
        .fifo_read_data(video_read_data1),
        .hs_out(hs_pix1), .vs_out(vs_pix1), .de_out(de_pix1), .pixel_rgb(rgb_raw1),
        .underflow_sticky(new_underflow_sticky),
        .pixel_valid(new_pixel_valid)
    );

    // ---- α 推进器 + 切换事务控制器（阶段 3）----
    // 事务控制器在视频域持有动画状态机：帧界启动双路 → α 0→256 →
    // 完整输出一帧新图 → 切新图单路 → 排空旧读 → done/failed。
    wire [8:0] mix_alpha;
    wire [4:0] mix_step;
    wire mix_busy, mix_done, mix_start, mix_fail;
    wire [1:0] active_transition_mode;
    wire trans_ack, trans_done, trans_failed;
    wire [1:0] trans_new_idx = transition_new_index;
    wire [1:0] trans_cur_idx = transition_cur_index;
    wire trans_req = trans_req_sync[2];
    assign transition_ack    = trans_ack;
    assign transition_done   = trans_done;
    assign transition_failed = trans_failed;

    mix_alpha_ctrl u_mix_alpha_ctrl (
        .clk(video_clk), .rst(rst_video),
        .vs(vs_raw), .start(mix_start), .fail(mix_fail),
        .alpha(mix_alpha), .busy(mix_busy), .done(mix_done),.progress_step(mix_step)
    );

    // ---- 像素混合：接在 error_overlay / 各 OSD 之前 ----
    wire [23:0] rgb_mixed;
    wire mix_pair_ok;
    reg [7:0] grid_x_local,pixel_x_local;
    reg [6:0] grid_y_local,pixel_y_local;
    reg [2:0] grid_x_cell,grid_y_cell;
    reg de_raw_d,grid_vs_d;
    reg [2:0] pixel_x_cell,pixel_y_cell;
    reg [3:0] pixel_delay_precomputed;
    wire grid_effect_active=mix_active && active_transition_mode==2'd2;
    always @(posedge video_clk or posedge rst_video) begin
        if(rst_video) begin
            grid_x_local<=0;grid_y_local<=0;grid_x_cell<=0;grid_y_cell<=0;de_raw_d<=0;grid_vs_d<=0;
            pixel_x_local<=0;pixel_y_local<=0;pixel_x_cell<=0;pixel_y_cell<=0;pixel_delay_precomputed<=0;
        end else if(!grid_effect_active) begin
            grid_x_local<=0;grid_y_local<=0;grid_x_cell<=0;grid_y_cell<=0;de_raw_d<=0;grid_vs_d<=vs_raw;
            pixel_x_local<=0;pixel_y_local<=0;pixel_x_cell<=0;pixel_y_cell<=0;pixel_delay_precomputed<=0;
        end else begin
            de_raw_d<=de_raw;grid_vs_d<=vs_raw;
            if(vs_raw && !grid_vs_d) begin grid_y_local<=0;grid_y_cell<=0;end
            if(de_raw) begin
                pixel_x_local<=grid_x_local;pixel_y_local<=grid_y_local;
                pixel_x_cell<=grid_x_cell;pixel_y_cell<=grid_y_cell;
                pixel_delay_precomputed<=grid_delay({grid_y_cell,grid_x_cell});
                if(grid_x_local==8'd159) begin
                    grid_x_local<=0;
                    if(grid_x_cell==3'd7) grid_x_cell<=0;else grid_x_cell<=grid_x_cell+1'b1;
                end else grid_x_local<=grid_x_local+1'b1;
            end
            if(de_raw_d && !de_raw) begin
                grid_x_local<=0;grid_x_cell<=0;
                if(grid_y_local==7'd119) begin
                    grid_y_local<=0;
                    if(grid_y_cell==3'd5) grid_y_cell<=0;else grid_y_cell<=grid_y_cell+1'b1;
                end else grid_y_local<=grid_y_local+1'b1;
            end
        end
    end
    function [3:0] grid_delay;
        input [5:0] cell_id;
        begin case(cell_id)
            0:grid_delay=0;1:grid_delay=9;2:grid_delay=3;3:grid_delay=13;4:grid_delay=6;5:grid_delay=2;6:grid_delay=11;7:grid_delay=5;
            8:grid_delay=12;9:grid_delay=4;10:grid_delay=14;11:grid_delay=7;12:grid_delay=1;13:grid_delay=10;14:grid_delay=5;15:grid_delay=13;
            16:grid_delay=3;17:grid_delay=8;18:grid_delay=0;19:grid_delay=12;20:grid_delay=6;21:grid_delay=14;22:grid_delay=2;23:grid_delay=9;
            24:grid_delay=4;25:grid_delay=11;26:grid_delay=7;27:grid_delay=1;28:grid_delay=13;29:grid_delay=5;30:grid_delay=10;31:grid_delay=3;
            32:grid_delay=14;33:grid_delay=6;34:grid_delay=0;35:grid_delay=8;36:grid_delay=12;37:grid_delay=4;38:grid_delay=9;39:grid_delay=2;
            40:grid_delay=11;41:grid_delay=1;42:grid_delay=7;43:grid_delay=13;44:grid_delay=5;45:grid_delay=10;46:grid_delay=3;default:grid_delay=14;
        endcase end
    endfunction
    wire [5:0] pixel_cell_id={pixel_y_cell, pixel_x_cell};
    wire [3:0] pixel_grid_delay=pixel_delay_precomputed;
    // Two grid stages plus three mixer stages, with the entire pixel bundle.
    wire [4:0] elapsed_unclamped = mix_step>{1'b0,pixel_grid_delay} ?
        mix_step-{1'b0,pixel_grid_delay}:5'd0;
    reg [4:0] elapsed_s1;
    reg [7:0] x_s1,x_s2;
    reg [6:0] y_s1,y_s2;
    reg [29:0] bounds_s2;
    reg [8:0] alpha_s1,alpha_s2,grid_alpha_s2;
    reg [1:0] mode_s1,mode_s2;
    reg [23:0] old_s1,old_s2,new_s1,new_s2;
    reg [1:0] old_ok_pipe,new_ok_pipe;
    reg [4:0] mix_enable_pipe,hs_mix_pipe,vs_mix_pipe,de_mix_pipe;
    function [29:0] grid_bounds;
        input [4:0] elapsed;
        begin case(elapsed)
            5'd0:grid_bounds={8'd0,8'd160,7'd0,7'd120};
            5'd1:grid_bounds={8'd5,8'd155,7'd4,7'd116};
            5'd2:grid_bounds={8'd10,8'd150,7'd8,7'd112};
            5'd3:grid_bounds={8'd15,8'd145,7'd11,7'd109};
            5'd4:grid_bounds={8'd20,8'd140,7'd15,7'd105};
            5'd5:grid_bounds={8'd25,8'd135,7'd19,7'd101};
            5'd6:grid_bounds={8'd30,8'd130,7'd23,7'd97};
            5'd7:grid_bounds={8'd35,8'd125,7'd26,7'd94};
            5'd8:grid_bounds={8'd40,8'd120,7'd30,7'd90};
            5'd9:grid_bounds={8'd45,8'd115,7'd34,7'd86};
            5'd10:grid_bounds={8'd50,8'd110,7'd38,7'd82};
            5'd11:grid_bounds={8'd55,8'd105,7'd41,7'd79};
            5'd12:grid_bounds={8'd60,8'd100,7'd45,7'd75};
            5'd13:grid_bounds={8'd65,8'd95,7'd49,7'd71};
            5'd14:grid_bounds={8'd70,8'd90,7'd53,7'd67};
            5'd15:grid_bounds={8'd75,8'd85,7'd56,7'd64};
            5'd16:grid_bounds={8'd80,8'd80,7'd60,7'd60};
            default:grid_bounds={8'd80,8'd80,7'd60,7'd60};
        endcase end
    endfunction
    always @(posedge video_clk or posedge rst_video) begin
        if(rst_video) begin
            elapsed_s1<=0;x_s1<=0;x_s2<=0;y_s1<=0;y_s2<=0;bounds_s2<=0;
            alpha_s1<=0;alpha_s2<=0;grid_alpha_s2<=0;mode_s1<=0;mode_s2<=0;
            old_s1<=0;old_s2<=0;new_s1<=0;new_s2<=0;
            old_ok_pipe<=0;new_ok_pipe<=0;mix_enable_pipe<=0;
            hs_mix_pipe<=0;vs_mix_pipe<=0;de_mix_pipe<=0;
        end else begin
            elapsed_s1<=elapsed_unclamped>16 ? 5'd16:elapsed_unclamped;
            bounds_s2<=grid_bounds(elapsed_s1);
            grid_alpha_s2<={elapsed_s1,4'b0000};
            x_s1<=pixel_x_local;x_s2<=x_s1;y_s1<=pixel_y_local;y_s2<=y_s1;
            alpha_s1<=mix_alpha;alpha_s2<=alpha_s1;
            mode_s1<=active_transition_mode;mode_s2<=mode_s1;
            old_s1<=display_valid ? rgb_raw:24'd0;old_s2<=old_s1;
            new_s1<=rgb_raw1;new_s2<=new_s1;
            old_ok_pipe<={old_ok_pipe[0],!display_valid || old_pixel_valid};
            new_ok_pipe<={new_ok_pipe[0],new_pixel_valid};
            mix_enable_pipe<={mix_enable_pipe[3:0],mix_lane1_en};
            hs_mix_pipe<={hs_mix_pipe[3:0],hs_pix};
            vs_mix_pipe<={vs_mix_pipe[3:0],vs_pix};
            de_mix_pipe<={de_mix_pipe[3:0],de_pix};
        end
    end
    wire grid_inside=x_s2>=bounds_s2[29:22] && x_s2<bounds_s2[21:14] &&
                     y_s2>=bounds_s2[13:7] && y_s2<bounds_s2[6:0];
    wire [8:0] pixel_alpha=mode_s2==2'd1 ? 9'd0:
        mode_s2==2'd2 ? (grid_inside ? grid_alpha_s2:9'd256):alpha_s2;
    pixel_mixer u_pixel_mixer (
        .clk(video_clk),.rst(rst_video),.mix_en(mix_enable_pipe[1]),.alpha(pixel_alpha),
        .old_rgb(old_s2),.old_valid(old_ok_pipe[1]),
        .new_rgb(new_s2),.new_valid(new_ok_pipe[1]),
        .mixed_rgb(rgb_mixed),.pair_ok(mix_pair_ok)
    );
    wire hs_mix=hs_mix_pipe[4],vs_mix=vs_mix_pipe[4],de_mix=de_mix_pipe[4];
    assign mix_fail=mix_enable_pipe[4] && !mix_pair_ok && de_mix;

    wire [1:0] trans_disp_idx;
    wire trans_disp_valid;
    mix_transition_ctrl u_mix_transition_ctrl (
        .restore_req(em_restore_sync[1] && em_idle2 && !trans_req),.restore_valid(emergency_restore_valid),
        .restore_index(emergency_restore_index),.restore_done(emergency_picture_restored),
        .clk(video_clk), .rst(rst_video), .vs(vs_raw),
        .transition_req(trans_req), .req_new_idx(trans_new_idx), .req_cur_idx(trans_cur_idx),
        .req_mode(transition_req_mode),
        .req_ack(trans_ack),
        .mix_active(mix_active), .lane1_en(mix_lane1_en), .lane1_idx(lane1_buf_idx),
        .alpha_start(mix_start),
        .active_mode(active_transition_mode),
        .alpha(mix_alpha), .alpha_busy(mix_busy), .alpha_done(mix_done),
        .read_handoff(handoff_sync[2]), .read_index(selected_sync2),
        .read_dual_active(dual_sync[1]), .mix_fail_in(mix_fail),
        .disp_index_out(trans_disp_idx), .disp_valid_out(trans_disp_valid),
        .transition_done(trans_done), .transition_failed(trans_failed)
    );
    // The video-domain transaction controller owns scanout selection in both
    // single-image and dual-image modes. seam_render keeps the committed copy.
    assign disp_buf_idx=trans_disp_idx;
    assign display_valid=trans_disp_valid;
    wire [23:0] rgb_base=(display_valid || mix_active) ? rgb_mixed:24'd0;

    // A complete UI commit supplies a stable configuration mailbox. The UI
    // consumer acknowledges on the VS leading edge; contrast applies at the
    // trailing edge, before active pixels. The algorithm itself knows no UI.
    reg contrast_commit_seen;
    always @(posedge video_clk or posedge rst_video)
        if(rst_video) contrast_commit_seen<=0;
        else contrast_commit_seen<=ui_commit_seen;
    wire hs_contrast,vs_contrast,de_contrast;
    wire [23:0] rgb_contrast;
    contrast_adjust u_contrast_adjust (
        .clk(video_clk),.rst(rst_video),
        .cfg_valid(ui_commit_seen!=contrast_commit_seen),.cfg_level(contrast_level),
        .enable(display_valid || mix_active),
        .hs_in(hs_mix),.vs_in(vs_mix),.de_in(de_mix),.rgb_in(rgb_base),
        .hs_out(hs_contrast),.vs_out(vs_contrast),.de_out(de_contrast),.rgb_out(rgb_contrast)
    );

    wire hs_saturation,vs_saturation,de_saturation;
    wire [23:0] rgb_saturation;
    saturation_adjust u_saturation_adjust (
        .clk(video_clk),.rst(rst_video),
        .cfg_valid(ui_commit_seen!=contrast_commit_seen),.cfg_level(saturation_level),
        .enable(display_valid || mix_active),
        .hs_in(hs_contrast),.vs_in(vs_contrast),.de_in(de_contrast),.rgb_in(rgb_contrast),
        .hs_out(hs_saturation),.vs_out(vs_saturation),.de_out(de_saturation),.rgb_out(rgb_saturation)
    );

    //--------------------------------------------------------------------------
    // 【诊断上屏】没显示出来时，把"卡在哪个环节"直接以 ERROR n 画在屏幕上
    //   显示链（两个叠加器是**串联的兄弟模块**，端口契约一致）：
    //     rgb_base → contrast_adjust → error_overlay → ui_text_overlay → rgb → HDMI
    //   文件浏览器窗口在下游，优先级最高；ui_active 时把 error_overlay 的 show
    //   抑制为 0 作兜底，避免"诊断横幅穿过窗口"。
    //--------------------------------------------------------------------------
    wire [3:0]  err_code_show;
    wire        err_show;
    wire        frame_black;
    wire [23:0] rgb_err_comb;
    wire [23:0] rgb_err;
    wire [23:0] rgb;
    wire hs_err, vs_err, de_err;
    wire hs_err_pipe, vs_err_pipe, de_err_pipe;
    wire hs, de;

    reg [3:0] diag_frame;
    reg link_frame,vs_status_d;
    always @(posedge video_clk or posedge rst_video)
        if(rst_video) begin diag_frame<=0;link_frame<=0;vs_status_d<=0;end
        else begin vs_status_d<=vs_pix;if(vs_pix && !vs_status_d) begin diag_frame<=diag;link_frame<=link_up;end end
    // Diagnostic build only: expose the local scanout fault that peer status hides.
    reg [3:0] local_image_fault;
    reg fault_req_d,old_pair_valid,new_pair_valid;
    reg [1:0] retire_frames;
    always @(posedge video_clk or posedge rst_video) begin
        if(rst_video) begin
            local_image_fault<=0;fault_req_d<=0;old_pair_valid<=1;new_pair_valid<=0;retire_frames<=0;
        end else begin
            fault_req_d<=trans_req;
            if(!mix_active || mix_lane1_en) retire_frames<=0;
            else if(vs_pix && !vs_status_d && retire_frames!=3) retire_frames<=retire_frames+1'b1;
            old_pair_valid<=!display_valid || old_pixel_valid;
            new_pair_valid<=new_pixel_valid;
            if(trans_req && !fault_req_d) local_image_fault<=0;
            else if(local_image_fault==0) begin
                if(mix_fail) begin
                    if(!old_pair_valid && !new_pair_valid) local_image_fault<=9;
                    else if(!old_pair_valid) local_image_fault<=8;
                    else if(!new_pair_valid) local_image_fault<=7;
                    else local_image_fault<=6;
                end else if(trans_failed) local_image_fault<=6;
                else if(mix_active && !mix_lane1_en && retire_frames>=2) local_image_fault<=4;
                else if(display_valid && !mix_lane1_en && de_pix && !old_pixel_valid) local_image_fault<=5;
            end
        end
    end
    assign err_code_show=local_image_fault!=0 ? local_image_fault:(link_frame ? diag_frame:4'd14);
    assign err_show=local_image_fault!=0 || !link_frame || diag_frame!=15;
    error_overlay #(
        .TEXT_X(`VBP_TEXT_X), .TEXT_Y(`VBP_TEXT_Y)
    ) u_error_overlay (
        .video_clk (video_clk),
        .rst       (rst_video),
        .hs        (hs_saturation),
        .vs        (vs_saturation),
        .de        (de_saturation),
        .pix_in    (rgb_saturation),
        .code      (err_code_show),
        .show      (err_show),
        .hs_out    (hs_err),
        .vs_out    (vs_err),
        .de_out    (de_err),
        .pix_out   (rgb_err_comb),
        .frame_black(frame_black)
    );

    // The synchronous diagnostic row ROM now occupies this existing stage.
    // Error overlay + former register still has two clocks total, including bypass.
    assign hs_err_pipe=hs_err;assign vs_err_pipe=vs_err;assign de_err_pipe=de_err;
    assign rgb_err=rgb_err_comb;

    wire hs_overlay,vs_overlay,de_overlay;wire [23:0] rgb_overlay;
    wire emergency_frame_active;
    image_overlay_64 u_image_overlay_64(
        .wr_clk(clk),.wr_en(overlay_write_en),.wr_addr(overlay_write_addr),.wr_data(overlay_write_data),
        .video_clk(video_clk),.video_rst(rst_video),.hs_in(hs_err_pipe),.vs_in(vs_err_pipe),.de_in(de_err_pipe),.rgb_in(rgb_err),
        .enable_in(link_frame && !err_show && !ui_active && !emergency_view_enable && !emergency_frame_active &&
                   (image_display_valid || mix_active)),
        .prepare_toggle(overlay_prepare_toggle),.commit_toggle(overlay_commit_toggle),
        .prepare_ack(overlay_prepare_ack),.commit_ack(overlay_commit_ack),
        .hs_out(hs_overlay),.vs_out(vs_overlay),.de_out(de_overlay),.rgb_out(rgb_overlay));

    // 文件浏览器窗口：通用文本叠加器（不知道文件/SD/按键为何物）
    wire [3:0] brightness_frame,brightness_rgb_level;
    // Declare the frame-latched brightness signals before their first use.
    // Keeping these declarations above the UI/audio instantiation avoids
    // Verilog's implicit-net warning in TD and makes the reset-domain intent
    // explicit.
    reg [3:0] brightness_rgb_frame;
    reg brightness_vs_d;
    wire [23:0] rgb_ui_comb;
    wire hs_ui,vs_ui,de_ui;
    wire ui_active_frame,text_osd_page_frame;wire [3:0] ui_page_frame;
    wire [6:0] menu_font_char,text_font_char;
    wire [3:0] menu_font_x,menu_font_y,text_font_x,text_font_y;
    wire [1:0] shared_font_alpha;
    // Normal menu and editor/banner are mutually exclusive for the whole
    // active frame. Select requests, preserving each overlay's own phase.
    wire use_menu_font=ui_active_frame && !text_osd_page_frame;
    wire [6:0] volume_font_char;wire [3:0] volume_font_x,volume_font_y;wire [1:0] volume_font_alpha;
    wire [6:0] clock_font_char;wire [3:0] clock_font_x,clock_font_y;wire clock_font_request;
    wire [1:0] port_b_alpha;
    font_rom #(.SECOND_PORT(1)) u_shared_font(.clk(video_clk),
        .char_code_b(clock_font_request ? clock_font_char:volume_font_char),
        .gx_b(clock_font_request ? clock_font_x:volume_font_x),.gy_b(clock_font_request ? clock_font_y:volume_font_y),.alpha_b(port_b_alpha),
        .char_code(use_menu_font ? menu_font_char:text_font_char),
        .gx(use_menu_font ? menu_font_x:text_font_x),
        .gy(use_menu_font ? menu_font_y:text_font_y),.alpha(shared_font_alpha));
    assign volume_font_alpha=port_b_alpha;
    ui_text_overlay #(
        .WIN_X0(`VBP_WIN_X0), .WIN_Y0(`VBP_WIN_Y0),.EXTERNAL_FONT(1)
    ) u_ui_text_overlay (
        .font_char(menu_font_char),.font_x(menu_font_x),.font_y(menu_font_y),.font_alpha(shared_font_alpha),
        .brightness_level(brightness_level),.brightness_frame(brightness_frame),
        .video_clk        (video_clk),
        .rst              (rst_video),
        .hs               (hs_overlay),
        .vs               (vs_overlay),
        .de               (de_overlay),
        .pix_in           (rgb_overlay),
        .pix_out          (rgb_ui_comb),
        .hs_out           (hs_ui),.vs_out(vs_ui),.de_out(de_ui),
        .text_osd_page(text_osd_page),.ui_active_frame(ui_active_frame),.text_osd_page_frame(text_osd_page_frame),.ui_page_frame(ui_page_frame),
        .ui_page        (ui_page),
        .contrast_level (contrast_level),.saturation_level(saturation_level),.volume_level(volume_level),.osd_enabled(text_osd_metadata[`TEXT_OSD_VIEW_ENABLE]),
        .ui_active        (br_ui_active),
        .ui_commit_toggle (br_ui_commit),
        .cursor_row       (br_cursor_row),
        .cursor_en        (br_cursor_en),
        .wr_clk           (sd_card_clk),
        .wr_en            (br_ui_wr_en),
        .wr_addr          (br_ui_wr_addr),
        .wr_data          (br_ui_wr_data),
        .dbg_commit_seen  (ui_commit_seen)
    );

    //--------------------------------------------------------------------------
    // 【音频播放 OSD】进度条 + 时间文本 + 节拍动画 + 播放/暂停图标
    //   ★ 插在 ui_text_overlay **之后**（最下游 ⇒ 优先级最高）。这样：
    //     · 面板可以盖住浏览器窗口（两者几何上不重叠，优先级定死更稳）
    //     · 一定在 error_overlay **下游** ⇒ 不影响它内部的 frame_black 全黑检测
    //       （那个检测统计的是它自己的上游 pix_in）
    //   ★ 本模块必须是**纯组合输出**（与 ui_text_overlay 同）。若它把 rgb 寄存一级，
    //     就会比 hs/vs/de 滞后一拍、整链相位错位；所以它不自带流水级，
    //     后面照旧接原来的末级 video_stream_reg。
    //--------------------------------------------------------------------------
    // OSD 内部有一级决策流水（见 audio_osd_overlay.v 头部"流水结构"）：
    // pix 决策与 hs/vs/de 同步延迟 1 拍，末级 reg 收口后相位对齐不变。
    wire [23:0] rgb_osd_comb;
    wire        hs_osd, vs_osd, de_osd;
    audio_osd_overlay u_audio_osd_overlay (
        .video_clk (video_clk),
        .rst       (rst_video),
        .hs        (hs_ui),
        .vs        (vs_ui),
        .de        (de_ui),
        .pix_in    (rgb_ui_comb),
        .i_model   (audio_osd_model),
        .hs_out    (hs_osd),
        .vs_out    (vs_osd),
        .de_out    (de_osd),
        .pix_out   (rgb_osd_comb)
    );

    wire [`TEXT_OSD_META_W-1:0] text_osd_view;
    wire [7:0] text_osd_addr;wire [7:0] text_osd_data;
    wire [`TEXT_OSD_META_W-1:0] sd_subtitle_metadata;
    wire sd_subtitle_selected;wire [7:0] sd_subtitle_data;
    wire local_text_commit,sd_subtitle_commit;
    sd_subtitle_view u_sd_subtitle(.clk(clk),.rst(rst),.session_reset(subtitle_session_reset),
      .start(subtitle_start),.revision(subtitle_revision),.start_ready(subtitle_start_ready),
      .data_valid(subtitle_data_valid),.data(subtitle_data),.last(subtitle_last),.data_ready(subtitle_data_ready),
      .applied(subtitle_applied),.applied_ready(subtitle_applied_ready),.applied_revision(subtitle_applied_revision),.applied_result(subtitle_applied_result),
      .video_clk(video_clk),.video_rst(rst_video),.vs(vs_osd),.display_image_id(display_image_id),.image_valid(image_display_valid),.mix_active(mix_active),
      .text_addr(text_osd_addr),.text_data(sd_subtitle_data),.metadata(sd_subtitle_metadata),.selected(sd_subtitle_selected),.video_commit(sd_subtitle_commit));
    text_osd_view_cdc u_text_osd_cdc(
        .clk(clk),.rst(rst),.metadata(text_osd_metadata),.revision(text_osd_revision),
        .edit_addr(text_osd_edit_addr),.edit_data(text_osd_edit_data),
        .text_addr(text_osd_addr),.text_data(text_osd_data),
        .video_clk(video_clk),.video_rst(rst_video),.vs(vs_osd),.view(text_osd_view),.video_commit(local_text_commit));
    wire [23:0] rgb_text_osd;
    wire hs_text_osd,vs_text_osd,de_text_osd;
    wire use_sd_subtitle=!text_osd_page_frame && sd_subtitle_selected;
    text_osd_overlay #(.EXTERNAL_FONT(1)) u_text_osd_overlay(
        .font_char(text_font_char),.font_x(text_font_x),.font_y(text_font_y),.font_alpha(shared_font_alpha),
        .clk(video_clk),.rst(rst_video),.hs(hs_osd),.vs(vs_osd),.de(de_osd),.pix_in(rgb_osd_comb),
        .ui_active_frame(ui_active_frame),.text_osd_page_frame(text_osd_page_frame),
        .diag_show(err_show || emergency_view_enable || emergency_frame_active),.banner_source(use_sd_subtitle),
        .view(use_sd_subtitle ? sd_subtitle_metadata:text_osd_view),
        .banner_reset(use_sd_subtitle ? sd_subtitle_commit:local_text_commit),.text_addr(text_osd_addr),
        .text_data(use_sd_subtitle ? sd_subtitle_data:text_osd_data),.hs_out(hs_text_osd),.vs_out(vs_text_osd),.de_out(de_text_osd),.pix_out(rgb_text_osd));

    wire [4:0] volume_video,volume_display;wire volume_event,volume_show;
    volume_view_cdc u_volume_cdc(.clk(clk),.rst(rst),.cfg_valid(volume_valid),
        .cfg_level(volume_level),.cfg_hint(volume_hint),.cancel(volume_cancel),
        .video_clk(video_clk),.video_rst(rst_video),.vs(vs_text_osd),.level(volume_video),.hint_event(volume_event));
    volume_hint_controller #(.CLK_HZ(`VBP_PIX_CLK_HZ)) u_volume_hint(
        .clk(video_clk),.rst(rst_video),.vs(vs_text_osd),.trigger(volume_event),
        .suppress(ui_active_frame || err_show || !link_frame),.level(volume_video),
        .show(volume_show),.display_level(volume_display));
    wire [23:0] rgb_volume;wire hs_volume,vs_volume,de_volume;
    volume_overlay u_volume_overlay(.clk(video_clk),.rst(rst_video),
        .hs(hs_text_osd),.vs(vs_text_osd),.de(de_text_osd),.pix_in(rgb_text_osd),
        .show(volume_show),.level(volume_display),.font_char(volume_font_char),
        .font_x(volume_font_x),.font_y(volume_font_y),.font_alpha(volume_font_alpha),
        .hs_out(hs_volume),.vs_out(vs_volume),.de_out(de_volume),.pix_out(rgb_volume));
    wire audio_volume_valid;wire [23:0] audio_volume_left,audio_volume_right;
    // Snapshot the complete audio bundle before its DSP multiply. The epoch
    // comparator and mute mux no longer share a cycle with the multiplier.
    reg gain_valid_q,gain_unity_q;
    reg [23:0] gain_left_q,gain_right_q;
    reg [4:0] gain_level_q;
    always @(posedge video_clk or posedge rst_video) begin
        if(rst_video) begin gain_valid_q<=0;gain_unity_q<=0;gain_left_q<=0;gain_right_q<=0;gain_level_q<=20;end
        else begin
            gain_valid_q<=audio_valid;gain_left_q<=em_mute ? 24'd0:audio_left;
            gain_right_q<=em_mute ? 24'd0:audio_right;gain_level_q<=volume_video;
            gain_unity_q<=em_voice_sync[1] && em_active_sync[1] && em_audio_ok;
        end
    end
    audio_volume_gain u_volume_gain(.clk(video_clk),.rst(rst_video),.level(gain_level_q),.unity(gain_unity_q),
        .in_valid(gain_valid_q),.in_left(gain_left_q),.in_right(gain_right_q),
        .out_valid(audio_volume_valid),.out_left(audio_volume_left),.out_right(audio_volume_right));
    // Separate glyph coverage/palette selection from the brightness multiplier.
    // RGB and all stream controls cross the same register boundary.
    wire [23:0] rgb_composited;
    wire hs_composited,vs_composited,de_composited;
    video_stream_reg u_pipe_after_text (
        .clk(video_clk),.rst(rst_video),
        .hs_in(hs_volume),.vs_in(vs_volume),.de_in(de_volume),.rgb_in(rgb_volume),
        .hs_out(hs_composited),.vs_out(vs_composited),.de_out(de_composited),.rgb_out(rgb_composited)
    );
    wire hs_normal,vs_normal,de_normal;wire [23:0] rgb_normal;
    brightness_scale u_pipe_after_ui (
        .level(brightness_rgb_frame),
        .clk(video_clk), .rst(rst_video),
        .hs_in(hs_composited), .vs_in(vs_composited), .de_in(de_composited), .rgb_in(rgb_composited),
        .hs_out(hs_normal), .vs_out(vs_normal), .de_out(de_normal), .rgb_out(rgb_normal)
    );
    assign emergency_view_vs=vs_normal;
    wire hs_emergency,vs_emergency,de_emergency;wire [23:0] rgb_emergency;
    emergency_overlay #(.FRAME_TIMESTAMPS(1)) u_emergency_overlay(.clk(video_clk),.rst(rst_video),
        .hs(hs_normal),.vs(vs_normal),.de(de_normal),.rgb_in(rgb_normal),.enable(emergency_view_enable===1'b1),
        .sources(emergency_sources),.groups(emergency_groups),.timestamps(emergency_timestamps),
        .frame_active(emergency_frame_active),
        .hs_out(hs_emergency),.vs_out(vs_emergency),.de_out(de_emergency),.rgb_out(rgb_emergency));
    wire [47:0] clock_live_digits,clock_draft_digits;wire [2:0] clock_video_focus;wire clock_video_editing;
    wire clock_editor_visible=clock_video_editing && ui_active_frame && ui_page_frame==7 && !emergency_frame_active;
    (* async_reg="true" *) reg clock_visible1,clock_visible2;
    assign clock_editor_ready=clock_visible2;
    always @(posedge clk or posedge rst) begin
        if(rst) begin clock_visible1<=0;clock_visible2<=0;end
        else begin clock_visible1<=clock_editor_visible;clock_visible2<=clock_visible1;end
    end
    clock_view_cdc u_clock_view(.clk(clk),.rst(rst),.live(clock_live),.draft(clock_draft),
        .focus(clock_focus),.editing(clock_editing),.video_clk(video_clk),.video_rst(rst_video),.vs(vs_emergency),
        .live_digits(clock_live_digits),.draft_digits(clock_draft_digits),.video_focus(clock_video_focus),.video_editing(clock_video_editing));
    clock_overlay #(.FRAME_DIGITS(1)) u_clock_overlay(.clk(video_clk),.rst(rst_video),.hs(hs_emergency),.vs(vs_emergency),.de(de_emergency),.rgb_in(rgb_emergency),
        .live_digits(clock_live_digits),.draft_digits(clock_draft_digits),.focus(clock_video_focus),
        .editing(clock_editor_visible),
        .font_request(clock_font_request),.font_char(clock_font_char),.font_x(clock_font_x),.font_y(clock_font_y),.font_alpha(port_b_alpha),
        .hs_out(hs),.vs_out(vs),.de_out(de),.rgb_out(rgb));

    frame_read_write #(
        .WRITE_V_FLIP(`VBP_WRITE_V_FLIP), .FRAME_WIDTH(LINE_WORDS), .FRAME_HEIGHT(V_ACTIVE)
    ) u_frame_read_write (
        .mem_clk(ext_mem_clk), .rst(rst_mem),
        .Sdr_init_done(sdr_init_done),
        .Sdr_init_ref_vld(sdr_init_ref_vld), .Sdr_busy(sdr_busy),
        .App_rd_en(frm_app_rd_en), .App_rd_addr(frm_app_rd_addr),
        .Sdr_rd_en(frm_sdr_rd_en), .Sdr_rd_dout(frm_sdr_rd_dout),
        .read_clk(video_clk), .read_req(video_read_req),
        .read_req_ack(video_read_req_ack_mem), .read_dual_active(read_dual_mem), .read_finish(),
        .read_selected_index(image_read_index), .read_handoff_toggle(image_read_handoff_toggle),
        .read_addr_0(BUF0_ADDR), .read_addr_1(BUF1_ADDR),
        .read_addr_2({ADDR_BITS{1'b0}}), .read_addr_3({ADDR_BITS{1'b0}}),
        .read_addr_index(disp_buf_idx), .read_len(FRAME_WORDS),
        .read_en(video_read_en), .read_data(video_read_data), .read_empty(video_read_empty),
        // ---- 第二路（新图）读接口：交叉淡化动画期使用 ----
        .read_en1(video_read_en1_g), .read_data1(video_read_data1), .read_empty1(video_read_empty1),
        .read_addr_lane1(lane1_buf_addr), .read_index_lane1(lane1_buf_idx),
        .read_lane1_en(mix_lane1_en), .read_slide_en(mix_lane1_en && active_transition_mode==2'd1),
        .read_slide_rows(ease_slide_rows(mix_step)), .read_ready(video_read_ready),
        .write_block(mix_active),
        .App_wr_en(frm_app_wr_en), .App_wr_addr(frm_app_wr_addr),
        .App_wr_din(frm_app_wr_din), .App_wr_dm(frm_app_wr_dm),
        .write_clk(sd_card_clk), .write_req(sd_write_req),
        .write_req_ack(sd_write_req_ack), .write_abort(image_write_abort), .write_abort_ack(image_abort_ack), .write_finish(frame_write_finish),
        .write_addr_0(BUF0_ADDR), .write_addr_1(BUF1_ADDR),
        .write_addr_2({ADDR_BITS{1'b0}}), .write_addr_3({ADDR_BITS{1'b0}}),
        .write_addr_index(write_buf_idx), .write_len(FRAME_WORDS),
        .write_en(packed_write_en && !video_write_full), .write_data(packed_write_data),
        .write_full(video_write_full), .write_sector_ready(video_write_sector_ready)
    );

    // App_* 字口仲裁：帧高优先；ENABLE_AUDIO=0 从结构上禁止音频进 App_* 口
    //（frame_fifo_read 的 rd_delay==10 判定无法容忍插入，见 sdram_app_arb 头注释）。
    // 音频数据通路走 wav_play_glue 8KB 弹性环，不落 SDRAM。
    sdram_app_arb #(
        .MEM_DATA_BITS(MEM_DATA_BITS), .ADDR_BITS(ADDR_BITS), .TAG_AW(9),
        .ENABLE_AUDIO(0)
    ) u_sdram_app_arb (
        .clk(ext_mem_clk), .rst(rst_mem), .sdr_busy(sdr_busy),
        .f_App_wr_en(frm_app_wr_en), .f_App_wr_addr(frm_app_wr_addr),
        .f_App_wr_din(frm_app_wr_din), .f_App_wr_dm(frm_app_wr_dm),
        .f_App_rd_en(frm_app_rd_en), .f_App_rd_addr(frm_app_rd_addr),
        .f_Sdr_rd_en(frm_sdr_rd_en), .f_Sdr_rd_dout(frm_sdr_rd_dout),
        .a_App_wr_en(1'b0), .a_App_wr_addr({ADDR_BITS{1'b0}}),
        .a_App_wr_din({MEM_DATA_BITS{1'b0}}), .a_App_wr_dm(4'b0000),
        .a_App_rd_en(1'b0), .a_App_rd_addr({ADDR_BITS{1'b0}}),
        .a_Sdr_rd_en(), .a_Sdr_rd_dout(),
        .a_wr_gnt(), .a_rd_gnt(),
        .App_wr_en(app_wr_en), .App_wr_addr(app_wr_addr),
        .App_wr_din(app_wr_din), .App_wr_dm(app_wr_dm),
        .App_rd_en(app_rd_en), .App_rd_addr(app_rd_addr),
        .Sdr_rd_en(sdr_rd_en), .Sdr_rd_dout(sdr_rd_dout)
    );

    sdram u_sdram (
        .Clk(ext_mem_clk), .Clk_sft(ext_mem_clk_sft), .Rst(rst_mem),
        .Sdr_init_done(sdr_init_done), .Sdr_init_ref_vld(sdr_init_ref_vld),
        .Sdr_busy(sdr_busy), .App_wr_en(app_wr_en),
        .App_wr_addr(app_wr_addr), .App_wr_dm(app_wr_dm),
        .App_wr_din(app_wr_din), .App_rd_en(app_rd_en),
        .App_rd_addr(app_rd_addr), .Sdr_rd_en(sdr_rd_en),
        .Sdr_rd_dout(sdr_rd_dout)
    );

    wire [`VBP_OSD_BANDS*5-1:0] gz_heights;
    localparam integer GZ_PADW = `OSD_M_SPEC_W - `VBP_OSD_BANDS*5;
    audio_goertzel_osd #(
        .NBANDS (`VBP_OSD_BANDS)
    ) u_audio_goertzel_osd (
        .clk(video_clk), .rst(rst_video), .vs(vs_err_pipe),
        .pcm_valid(audio_valid), .pcm_left(audio_left), .pcm_right(audio_right),
        .play_run(audio_playing),
        .paused(audio_paused), .stream_restart(audio_restart),
        .heights(gz_heights)
    );
    // 模型里频谱字段按 16 柱（80 bit）预留，当前只用低 60 bit，高位补 0。
    assign fft_heights = { {GZ_PADW{1'b0}}, gz_heights };

    // Backend gain changes only during vertical blanking.
    always @(posedge video_clk or posedge rst_video)
        if(rst_video) begin brightness_rgb_frame<=10;brightness_vs_d<=0;end
        else begin brightness_vs_d<=vs_osd;if(vs_osd && !brightness_vs_d) brightness_rgb_frame<=brightness_rgb_level;end
    wire video_locked;
    hdmi_audio_driver #(
        .DEVICE("EG"),
        .H_ACTIVE(H_ACTIVE), .H_FRONT(H_FRONT), .H_SYNC(H_SYNC), .H_BACK(H_BACK),
        .V_ACTIVE(V_ACTIVE), .V_FRONT(V_FRONT), .V_SYNC(V_SYNC), .V_BACK(V_BACK),
        .VIDEO_VIC(4), .AUDIO_SAMPLE_RATE("48K"),
        .ACR_N(6144), .IIC_SCL_DIV(750)
    ) u_hdmi_audio_driver (
        .brightness_level(brightness_frame),.brightness_rgb_level(brightness_rgb_level),.brightness_mode(brightness_mode),
        .pixel_clk(video_clk), .pixel_clk_5x(hdmi_5x_clk),
        .rst_n(~rst_video), .vga_hs(hs), .vga_vs(vs), .vga_de(de),
        .vga_rgb(rgb), .audio_valid(audio_volume_valid),
        .audio_left(audio_volume_left), .audio_right(audio_volume_right),
        .hdmi_ddc_scl(HDMI_DDC_SCL), .hdmi_ddc_sda(HDMI_DDC_SDA),
        .hdmi_clk_p(HDMI_CLK_P), .hdmi_d2_p(HDMI_D2_P),
        .hdmi_d1_p(HDMI_D1_P), .hdmi_d0_p(HDMI_D0_P),
        .video_locked(video_locked)
    );


    db_audio_model u_audio_model(.clk(video_clk),.rst(rst_video),.vs(vs_err_pipe),
        .position(audio_position),.total(audio_total),.playing(audio_playing),.paused(audio_paused),
        .spectrum(fft_heights),.model(osd_model));
    assign image_write_ack=sd_write_req_ack;assign image_write_full=video_write_full;
    assign image_write_ready=video_write_sector_ready;
    assign VGA_HS=hs;assign VGA_VS=vs;
    assign VGA_R=rgb[23:16];assign VGA_G=rgb[15:8];assign VGA_B=rgb[7:0];
endmodule
