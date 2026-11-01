//=============================================================================
// module : wav_playlist
// 文件名 : rtl/audio/wav_playlist.v
// 功  能 : 【WAV 曲目表 + 游标】记住开机枚举到的所有 .WAV，维护"当前第几首"，
//          收到"下一首"请求时给出下一首的 {first_cluster, size} 并发起播放请求。
//
//  设计取舍：
//    · 曲目表来自 fat_bmp_controller 开机那次 C_DIR 枚举的 **.WAV 捕获流**
//      （本模块只建表，不做任何目录枚举 ⇒ 不新增目录口争用、不新增卡死面）。
//      副作用：开机后才放进卡里的文件不进表（本工程本就不支持热插拔重扫）。
//    · "当前第几首"不靠传下标，而是用 **first_cluster 反查**：浏览器选曲时把
//      选中条目的 cluster 发过来，本模块在表里线性扫一遍定位。这样图像链
//      （fat_bmp_controller）与播放链（fat_wav_controller）都不必懂"第几首"。
//    · "下一首"= 游标 +1、越界回绕 0 —— 与"下一张图"（fat_bmp_controller 的
//      next_index）完全同一套语义，用户心智一致。
//
//  ★★ 资源红线（2026-09-25 两次上板血的教训，改本模块前必读）★★
//    1) 存储阵列的**地址位宽必须与深度严格一致**（clog2(WAV_MAX) 位）。
//       曾经 16 条的表用 7 位地址访问：TD 把阵列撑到地址空间大小
//       （SYN-5042 Failed to infer as BRAM），摊成 751 LUT + 1189 触发器，
//       把器件挤到 96.84% 利用率 ⇒ 布线拥塞（最差路径连线延迟占 90%）⇒
//       75MHz 视频域只做到 47.5MHz ⇒ **整屏黑屏**。
//    2) 建表计数 wav_cnt 的唯一驱动源在下面的 FSM 块里（含复位）——
//       别在别的 always 块再写它（HDL-8007 多驱动，只有综合会报）。
//    3) 同步读的装载拍：S_NXT_ADDR / S_SCAN_ADDR 是"给地址后隔一拍再用
//       tab_q"的装载拍，别当冗余优化掉。
//    4) WAV_MAX 必须是 2 的幂（clog2 寻址假设）。
//=============================================================================
module wav_playlist #(
    parameter integer WAV_MAX = 64        // 最多记 64 首（64×64bit = 1 块 BRAM）
)(
    input  wire        clk,
    input  wire        rst,               // 高有效

    // ---- 来自 fat_bmp_controller 的开机 .WAV 捕获流（1 拍脉冲/条目）----
    input  wire        i_entry_valid,
    input  wire [31:0] i_entry_cluster,
    input  wire [31:0] i_entry_size,

    // ---- "当前在播"记录：选曲请求（浏览器确认/其它来源）----
    input  wire        i_play_req,        // 1 拍
    input  wire [31:0] i_play_cluster,    // 该请求的 first_cluster
    input wire i_restore_req,input wire [31:0] i_restore_cluster,

    // ---- "下一首"请求（来自 audio_transport 双击）----
    input  wire        i_next_req,        // 1 拍
    input  wire        i_ui_active,       // 1 = 浏览器打开（让位，不发请求）

    // ---- 发起的播放请求（顶层 OR 进 fat_wav_controller.ext_play_*）----
    output reg         o_ext_play_req,    // 1 拍
    output reg  [31:0] o_ext_play_cluster,
    output reg  [31:0] o_ext_play_size
);

    // clog2：地址宽度与阵列深度严格一致（见头部资源红线 1）
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
        end
    endfunction
    localparam integer TAB_AW = clog2(WAV_MAX);

    //-------------------------------------------------------------------------
    // 曲目表：{cluster, size} 一条 64 bit
    //  ★ 写口与读口分属两个 always 块（简单双口样式，与 catalog_mem 一致，
    //    TD 实测可推断成 BRAM）；地址位宽 = TAB_AW（见头部红线 1）。
    //-------------------------------------------------------------------------
    reg [63:0] tab [0:WAV_MAX-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [TAB_AW:0]  wav_cnt;               // 已收录条目数（0..WAV_MAX，含饱和值故 +1 位）
    reg [TAB_AW-1:0] cur_idx;              // 当前在播条目序号
    reg [TAB_AW-1:0] tab_addr;
    reg [63:0] tab_q;

    wire tab_full = (wav_cnt == WAV_MAX[TAB_AW:0]);

    always @(posedge clk) begin
        if (i_entry_valid && !tab_full) begin
            tab[wav_cnt[TAB_AW-1:0]] <= {i_entry_cluster, i_entry_size};
            // ★ wav_cnt 的自增放在下面 FSM 那个 always 块里（含复位）。
            //   一个 reg 只允许一个驱动源：这里再写一次就是 HDL-8007 多驱动。
        end
    end

    always @(posedge clk) begin
        tab_q <= tab[tab_addr];            // 同步读（1 拍）
    end

    //-------------------------------------------------------------------------
    // 状态机
    //  ★ tab_q 是**同步读**（本拍给地址、下拍末才出数据），所以"设地址"与
    //    "用 tab_q"之间必须隔一整拍。S_NXT_ADDR / S_SCAN_ADDR 就是这个装载拍
    //    —— 别把它们当冗余优化掉，优化掉就是"用到上一条的簇号"。
    //-------------------------------------------------------------------------
    localparam [2:0] S_IDLE      = 3'd0;
    localparam [2:0] S_NXT_ADDR  = 3'd1;   // 设下一首地址（装载拍）
    localparam [2:0] S_NXT_LOAD  = 3'd2;   // tab_q 已就绪，发起请求
    localparam [2:0] S_SCAN_ADDR = 3'd3;   // 设反查地址（装载拍）
    localparam [2:0] S_SCAN_CMP  = 3'd4;   // tab_q 已就绪，比对

    reg [2:0]  state;
    reg restore_scan;
    reg [TAB_AW-1:0] scan_idx;
    reg [TAB_AW-1:0] nxt_r;
    reg play_req_pending;
    reg [31:0] play_cluster_r;

    // 下标 +1 的全宽比较（防截断：wav_cnt 含饱和值，比 cur_idx 宽 1 位）
    wire [TAB_AW:0] scan_w = {1'b0, scan_idx} + {{TAB_AW{1'b0}}, 1'b1};
    wire [TAB_AW:0] cur_w  = {1'b0, cur_idx}  + {{TAB_AW{1'b0}}, 1'b1};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= S_IDLE;restore_scan<=0;
            scan_idx         <= {TAB_AW{1'b0}};
            nxt_r            <= {TAB_AW{1'b0}};
            cur_idx          <= {TAB_AW{1'b0}};
            play_req_pending <= 1'b0;
            play_cluster_r   <= 32'd0;
            tab_addr         <= {TAB_AW{1'b0}};
            wav_cnt          <= {(TAB_AW+1){1'b0}};  // ★ 必须复位：否则建表条件 X ⇒ 表永远建不起来
            o_ext_play_req   <= 1'b0;
            o_ext_play_cluster <= 32'd0;
            o_ext_play_size    <= 32'd0;
        end else begin
            o_ext_play_req <= 1'b0;        // 默认单拍

            // 曲目表填充计数：与上面建表块的 tab 写入同拍同条件。
            // ★ 本 reg 的唯一驱动源在这里（含复位），别再在别的 always 块里写它。
            if (i_entry_valid && !tab_full)
                wav_cnt <= wav_cnt + 1'b1;

            // Capture browser/subtitle selection locally before starting the
            // BRAM scan. This keeps the high-fanout request net out of the
            // scan-index and cursor update logic.
            if (i_restore_req===1'b1) begin
                play_req_pending <= 1'b0;
            end else if (state==S_IDLE && !play_req_pending && i_play_req) begin
                play_req_pending <= 1'b1;
                play_cluster_r <= i_play_cluster;
            end else if (play_req_pending) begin
                play_req_pending <= 1'b0;
            end

            case (state)
            S_IDLE: begin
                if (play_req_pending) begin
                    // 用 cluster 反查"当前第几首"；找不到就回退到第 0 首
                    scan_idx <= {TAB_AW{1'b0}};
                    tab_addr <= {TAB_AW{1'b0}};
                    state    <= S_SCAN_ADDR;
                end else if (!i_play_req && i_next_req && !i_ui_active && (wav_cnt != {(TAB_AW+1){1'b0}})) begin
                    // 游标 +1、越界回绕 0（与"下一张图"同一语义）
                    nxt_r    <= (cur_w >= wav_cnt) ? {TAB_AW{1'b0}} : cur_w[TAB_AW-1:0];
                    tab_addr <= (cur_w >= wav_cnt) ? {TAB_AW{1'b0}} : cur_w[TAB_AW-1:0];
                    state    <= S_NXT_ADDR;
                end
            end

            S_NXT_ADDR: state <= S_NXT_LOAD;   // 装载拍：tab_q 本拍末 = tab[nxt]

            S_NXT_LOAD: begin
                o_ext_play_req     <= 1'b1;
                o_ext_play_cluster <= tab_q[63:32];
                o_ext_play_size    <= tab_q[31:0];
                cur_idx            <= nxt_r;       // 自己发起的跳转直接记下标
                state              <= S_IDLE;
            end

            S_SCAN_ADDR: state <= S_SCAN_CMP;  // 装载拍：tab_q 本拍末 = tab[scan_idx]

            S_SCAN_CMP: begin
                if (tab_q[63:32] == (restore_scan ? i_restore_cluster:play_cluster_r)) begin
                    cur_idx <= scan_idx;               // 找到
                    state   <= S_IDLE;
                end else begin
                    scan_idx <= scan_w[TAB_AW-1:0];
                    tab_addr <= scan_w[TAB_AW-1:0];
                    if (scan_w >= wav_cnt) begin
                        cur_idx <= {TAB_AW{1'b0}};     // 没找到 ⇒ 回退第 0 首
                        state   <= S_IDLE;
                    end else begin
                        state <= S_SCAN_ADDR;          // 继续扫（先给装载拍）
                    end
                end
            end

            default: state <= S_IDLE;
            endcase
            if(state==S_IDLE) restore_scan<=0;
            if(i_restore_req===1'b1) begin
                restore_scan<=1;scan_idx<=0;tab_addr<=0;state<=S_SCAN_ADDR;o_ext_play_req<=0;
            end
        end
    end

endmodule
