//=============================================================================
// 文件名 : rtl/fft/audio_fft_osd.v
// 本文件含**两个**「频谱 OSD 前端」，端口完全一致，可直接互换：
//
//   audio_goertzel_osd  ★ 当前生产实现（2026-09-28 起）
//       12 带 Goertzel 频带估计器。只算 12 个指定频点的能量，不需要整块
//       256 点 FFT。头注释里有完整推导、位宽红线与扩展步骤。
//
//   audio_fft_osd       旧实现（保留供回退比对，顶层**不再例化**）
//       256 点纯 RTL FFT → α-β 幅值 → log2 压缩 → 12 带峰值。
//       实测占 1012 个 slice，是 2026-09-28 时序崩盘的直接原因
//       （见 doc/timing-diagnosis-2026-09-28.md）。
//
// ★ 为什么两个模块挤在同一个 .v 里：MultimediaSystem_v1.al 有硬约束
//   （TD 会用内存状态回写，手加的文件条目会被静默抹掉，表现为 HDL-8007）。
//   本文件已在 .al 中，所以新实现直接写进来，不新增文件条目。
//   将来若在 TD 里删掉旧 FFT 前端，可把本文件整体改名为 audio_goertzel_osd.v。
//=============================================================================
`include "../pkg/video_bmp_params.vh"

//=============================================================================
// module : audio_goertzel_osd
// 功  能 : 把「SD 卡 WAV 播放的 48 kHz PCM 流」变成 NBANDS 根频谱柱的高度。
//
//  ── 算法：Goertzel（DFT 的单点特例）────────────────────────────────────
//    只关心某个频点 k 时不必做完整 FFT。把该点的 DFT 写成二阶 IIR 谐振器
//    的递推（零除法、零查表）：
//
//        s0 = x[n] + c(k)·s1 − s2          c(k) = 2·cos(2π·k/BLOCK)
//        s2 ← s1 ,  s1 ← s0
//
//    块末（BLOCK 个样本后）|s1| 正比于该频点幅度，即 |X(k)|。
//    ★ 为什么 |s1| 就够：极点在单位圆上，块末状态正好是「幅度 A·BLOCK/2、
//      相位随机」的相量 ⇒ |s1| = |X(k)|。不需要再算 s1²+s2²−c·s1·s2
//      （省掉 3 次乘法和一个 ~44 位的宽累加器）。12 根柱子的显示
//      也用不着这个精度。
//
//  ── 位宽红线（改之前必读）──────────────────────────────────────────────
//    · c 用 Q1.14，且 |c_q| ≤ 32758 < 2^14·2 ⇒ 极点 |z| 严格为 1
//      （临界稳定），靠「每块末复位状态」收敛。**不要**让 |c_q| 达到 32768。
//    · 最坏情况（直流输入）|s[n]| ≤ n·|x|max = 256 × 32767 = 8.39e6 < 2^24，
//      故状态取 STW=25 位（含符号）在**最坏情况**下也不溢出；
//      中间量 c·s1 ≤ 2^25 ⇒ 乘积寄存器需 41 位（本文件用 STW+16）。
//      **不要**把 STW 降到 23，也不要缩短乘积寄存器。
//
//  ── 时分复用（省面积的关键）────────────────────────────────────────────
//    48 kHz 下每样本间隔 = 75 MHz / 48 kHz ≈ 1562 拍。NBANDS=12 时
//    递推占 12×3 = 36 拍，块末求幅值再 12×3 = 36 拍（每 256 样本一次）
//    ⇒ **一个乘法器顺序服务全部 12 个频带**，占用率约 2.4%。
//    窗乘（每样本 1 次）与递推乘共用同一个寄存器 `prod_r` ⇒ 复用同一个 DSP。
//    状态 s1/s2 存成两块 NBANDS×STW 的小 RAM（同步读 ⇒ LUTRAM 推断），
//    而不是 12 组展开寄存器。
//
//  ── 峰值/衰减去掉了什么（对比 fft_osd_bands）──────────────────────────
//    fft_osd_bands 是「并行」结构：12 个频带各有一套峰值比较 + 攻/衰选择。
//    这里频带本来就是顺序处理的，于是：
//      · 块末求幅值时用**移位寄存器**把 12 个高度拼成一条向量（零额外逻辑）；
//      · vs 沿的攻/衰只用一个 5 位比较器 + 一个 5 位减法器，12 拍顺序扫完
//        （vs 沿每帧一次，1.25M 拍/帧，扫 12 拍无所谓），
//        顺路把 peak 向量清成 0 交给下一帧。
//    顺序化的峰值保持：每拍读 shown/peak 的**最高 5 位**，算完从低位塞回去。
//    N 拍之后恰好还原成 [h0|h1|…|h(N-1)] 的原始排布（推导见 HOLD 段注释）。
//
//  ── 窗口：三角窗（无 ROM）──────────────────────────────────────────────
//    w[n] = 2·min(n, BLOCK−n)/BLOCK，Q1.15。旧 FFT 实现用 Hann（要一张
//    fft_trig_rom，约 190 个 LUT）。三角窗只有一次减法和一次移位，
//    副瓣 −26 dB 对 22 像素高的柱状显示与 Hann 无可见差别。
//    WIN_EN=0 可完全关掉窗口。
//
//  ── 扩展频点（按这 4 步走，前三步都在本文件/参数里）──────────────────
//    ① video_bmp_params.vh :
//         `VBP_OSD_BANDS（柱数）、`VBP_OSD_BAND_W（每柱像素列数，取 2 的幂）、
//         `VBP_OSD_ANIM_W 必须 = BANDS × BAND_W、`VBP_OSD_BAND_SH = log2(BAND_W)
//    ② 本文件 band_coef() 表按 band 序加一行（表里给出了每个中心 bin 与 Hz）
//    ③ osd_paint_anim / audio_osd_overlay 的 NBANDS/BAND_W/BAND_SH 参数
//       （由 video_bmp_params.vh 的宏自动传下去，一般不用手工改）
//    ④ osd_model_bus.vh 的 `OSD_M_SPEC 已按 16 带（80 bit）预留 ⇒ **≤16 带免改**；
//       要超过 16 带才需要整体加宽 `OSD_M_W 与 `OSD_M_SPEC_W。
//
//    ★ 频点定死是 Goertzel 的固有代价（相对 FFT）：想事后任意改频段就得回到
//      FFT 实现。band_coef() 那张表就是「频点清单」本身。
//
//  频率换算：FS = 48 kHz，BLOCK = 256 ⇒ bin 宽 = 187.5 Hz，中心频率 = 中心 bin × 187.5 Hz。
//=============================================================================
module audio_goertzel_osd #(
    parameter integer NBANDS  = `VBP_OSD_BANDS, // 频带数（12）
    parameter integer NBW     = 4,              // 频带计数器位宽（≤16 带 → 4）
    parameter integer BLOCK   = 256,            // 块长（样本）⇒ 分辨率 = FS/BLOCK
    parameter integer LOG2B   = 8,              // log2(BLOCK)
    parameter integer STW     = 25,             // 递推状态位宽（见位宽红线）
    parameter integer WIN_EN  = 1,              // 1 = 加三角窗；0 = 直通
    parameter integer LOG_OFF = 10,             // 显示标定：height = clamp((msb−10)×2, 0, 22)
    parameter integer HMAX    = 22              // 柱高上限（像素）
)(
    input  wire                 clk,            // video_clk
    input  wire                 rst,            // 高有效
    input  wire                 vs,             // 场同步（帧界攻/衰）
    input  wire                 pcm_valid,      // 1 拍脉冲（48 kHz）
    input  wire [23:0]          pcm_left,
    input  wire [23:0]          pcm_right,
    input  wire                 play_run,
    input  wire                 paused,
    input  wire                 stream_restart,
    output wire [NBANDS*5-1:0]  heights
);

    localparam integer SW = NBANDS*5;                  // heights 位宽
    localparam [NBW-1:0] LAST_B = NBANDS[NBW-1:0] - 1'b1;
    localparam [4:0]     LOFF   = LOG_OFF;
    localparam [5:0]     HMAX6  = HMAX;
    localparam integer   WSH    = 15 - LOG2B + 1;      // 三角窗移位量（256 → 8）

    //=========================================================================
    // 0) 频点表 ★扩展点
    //
    //    band | 中心 bin | 中心频率 | c(k) = 2cos(2π·bin/256) 的 Q1.14 值
    //    -----+----------+----------+--------------------------------
    //      0  |    1     |   188 Hz | 32758
    //      1  |    2     |   375 Hz | 32729
    //      2  |    3     |   562 Hz | 32679
    //      3  |    4     |   750 Hz | 32610
    //      4  |    6     |  1125 Hz | 32413
    //      5  |    8     |  1500 Hz | 32138
    //      6  |   12     |  2250 Hz | 31357
    //      7  |   18     |  3375 Hz | 29624
    //      8  |   27     |  5062 Hz | 25829
    //      9  |   39     |  7312 Hz | 18868
    //     10  |   56     | 10500 Hz |  6393
    //     11  |   87     | 16312 Hz | −17531
    //
    //    新增一行：c_q = round(2·cos(2π·bin/256) · 16384)，且必须落在
    //    (−32768, 32767] 区间内（否则极点跑出单位圆、状态会发散）。
    //=========================================================================
    function signed [15:0] band_coef;
        input integer n;
        begin
            case (n)
                0:  band_coef =  16'sd32758;
                1:  band_coef =  16'sd32729;
                2:  band_coef =  16'sd32679;
                3:  band_coef =  16'sd32610;
                4:  band_coef =  16'sd32413;
                5:  band_coef =  16'sd32138;
                6:  band_coef =  16'sd31357;
                7:  band_coef =  16'sd29624;
                8:  band_coef =  16'sd25829;
                9:  band_coef =  16'sd18868;
                10: band_coef =   16'sd6393;
                11: band_coef = -16'sd17531;
                default: band_coef = -16'sd17531;   // ≥12 带时先补最高带，扩展时再改
            endcase
        end
    endfunction

    //=========================================================================
    // 1) 显示条件 / 复位口径（与 audio_fft_osd + fft_osd_bands 保持同语义）
    //=========================================================================
    wire active       = play_run && !paused;
    wire clear_visual = stream_restart || !play_run;   // 清「显示」高度
    wire abort_frame  = !active || stream_restart;     // 丢弃未完成的累加
    wire s_valid      = pcm_valid && active;

    //=========================================================================
    // 2) 输入混单声道 + 三角窗
    //    与旧实现一致：取 24 bit 样本的高 16 位（[23:8]），左右相加取平均。
    //=========================================================================
    wire signed [16:0] mono_sum = {pcm_left[23],  pcm_left[23:8]} +
                                  {pcm_right[23], pcm_right[23:8]};
    wire signed [15:0] mono16   = mono_sum >>> 1;

    reg  [LOG2B-1:0]  smp_cnt;                          // 本块内的样本序号 0..BLOCK-1

    wire [LOG2B:0]    wn    = (smp_cnt <= BLOCK/2) ? {1'b0, smp_cnt}
                                                  : (BLOCK - smp_cnt);
    // ★ wn_hi 必须是 16 位：wn ≤ BLOCK/2 = 128，左移 WSH=8 后到 32768，
    //   若只给 9 位会被静默截断（窗系数变 0 ⇒ 整段无声）。历史坑，勿改窄。
    wire [15:0]       wn_hi = wn << WSH;
    // ★ w_tri 必须是 **signed**：mono16 是有符号样本，若窗系数是无符号，
    //   Verilog 会把整条乘法按无符号解释（负半周被算成"大正数"），
    //   结果是整流 + 宽带谐波，频谱全乱。历史坑，勿去掉 signed。
    wire signed [15:0] w_tri = (wn >= (BLOCK/2)) ? 16'sd32767 : wn_hi;

    //=========================================================================
    // 3) 状态 RAM + 流水寄存器
    //    读只在 P_G0/P_M0（rd_en），写只在 P_G2/P_M2（we）⇒ **同一拍绝不同时
    //    读写**，因此与工具「读优先/写优先」的推断无关，行为无歧义。
    //=========================================================================
    // Packed state uses three BRAM9K lanes instead of distributed state RAM.
    
    wire signed [STW-1:0]  s1q, s2q;                     // 同步读出口
    reg signed [STW-1:0] s1h;
    wire signed [STW-1:0] s2h;                     // P_G1 打拍给 P_G2 用
    reg signed [15:0]     coef_r;
    reg signed [STW+15:0] prod_r;                       // 窗乘 / 递推乘共用

    // 阶段编码
    localparam [3:0] P_IDLE = 4'd0,
                     P_WIN  = 4'd1,
                     P_G0   = 4'd2, P_G1 = 4'd3, P_G2 = 4'd4,
                     P_M0   = 4'd5, P_M1 = 4'd6, P_M2 = 4'd7,
                     P_HOLD = 4'd8;

    reg  [3:0]     ph;
    reg  [NBW-1:0] band, hold_b;
    reg  signed [15:0] x_go;                            // 本样本送进递推的值

    reg  mag_req, mag_abort, hold_req, decay_phase, decay_use, vs_d, abort_d;
    reg  [SW-1:0] shown_v, peak_v;

    wire [NBW-1:0] rd_a  = band;
    wire           rd_en = (ph == P_G0) || (ph == P_M0);
    wire           we    = (ph == P_G2) || (ph == P_M2);

    // ★ prod_r 只允许在**下面那个主状态机**里被赋值（P_IDLE 的窗乘、P_G1 的递推乘
    //   是同一个变量的两个源，靠互斥的相位区分）。
    //   曾经这里另起一个 always 块写 prod_r ⇒ HDL-8007「constantly driven from
    //   multiple places」：ModelSim 能过（同拍后写覆盖先写），综合器会直接判黑盒。
    //   勿再新增第二个驱动源。

    // prod >> 14（Q1.14 还原），截到 STW 位：位宽红线保证不溢出
    wire signed [STW-1:0] p14 = prod_r[STW+13 : 14];
    // Carry-save x_go + p14 + ~S2, with the subtraction's +1 in bit zero.
    // Only the final sum propagates carry through STW bits; truncation is
    // exactly the original two's-complement modulo-2**STW recurrence.
    wire signed [STW-1:0] x_state=x_go;
    wire [STW-1:0] inv_s2=~s2h;
    wire [STW-1:0] sum_bits=x_state ^ p14 ^ inv_s2;
    wire [STW-1:0] carry_bits=(x_state & p14) | (x_state & inv_s2) | (p14 & inv_s2);
    wire signed [STW-1:0] s0w=sum_bits+{carry_bits[STW-2:0],1'b1};

    wire signed [STW-1:0] wd1 = (ph == P_M2) ? {STW{1'b0}} : s0w;
    wire signed [STW-1:0] wd2 = (ph == P_M2) ? {STW{1'b0}} : s1h;

    localparam PACKED_HISTORY=(STW==25 && NBW==4 && NBANDS>=2 && NBANDS<=16);
    generate if(PACKED_HISTORY)begin: history
        wire [2*NBANDS-1:0] tags;
        wire [1:0] tag=tags[{band,1'b0} +:2];
        wire opposite=(ph==P_G1 || ph==P_G2);
        wire selected_bank=tag[0]^opposite;
        wire selected_valid=(ph==P_G2) || ((ph==P_G1) ? tag[1]:(|tag));
        // Word 32 is permanently zero, outside all writable band/bank words.
        wire [5:0] address=selected_valid ? {1'b0,selected_bank,band}:6'd32;
        wire enable=(ph==P_G0 || ph==P_G1 || ph==P_G2 || ph==P_M0);
        wire signed [24:0] state_q;
        assign s1q=state_q;assign s2q=state_q;assign s2h=state_q;
        resource_goertzel_history_ram u_ram(.clk(clk),.enable(enable),.write(ph==P_G2),
          .address(address),.din(wd1),.q(state_q));
        genvar g;
        for(g=0;g<NBANDS;g=g+1)begin: band_tag
            // No warm-reset input: the tag and its RAM words have one lifetime.
            reg [1:0] value=2'b00;
            assign tags[g*2+:2]=value;
            always @(posedge clk)if(band==g)begin
                if(ph==P_G2)value<={|value,!value[0]};
                else if(ph==P_M2)value<=2'b00;
            end
        end
    end else begin: legacy_state
        reg signed [STW-1:0] s2_registered;
        assign s2h=s2_registered;
        always @(posedge clk or posedge rst)
          if(rst)s2_registered<=0;else if(ph==P_G1)s2_registered<=s2q;
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(2*STW),.DATA_WIDTH_B(2*STW),
        .ADDR_WIDTH_A(NBW),.ADDR_WIDTH_B(NBW),.MODE("DP"),.IMPLEMENT("9K"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL")) u_state_ram(
        .clka(clk),.cea(we || rd_en),.ocea(1'b1),.rsta(1'b0),.wea(we),.bea(1'b1),
        .addra(band),.dia({wd2,wd1}),.doa({s2q,s1q}),
        .clkb(clk),.ceb(1'b0),.oceb(1'b1),.rstb(1'b0),.web(1'b0),.beb(1'b1),
        .addrb({NBW{1'b0}}),.dib({(2*STW){1'b0}}),.dob());
    end endgenerate


    //=========================================================================
    // 4) 块末求幅值：|s1| → 最高置位 → 高度
    //    用 msb 而不是 log2 查表：1 个 msb 单位 = 2 倍幅度 = 6 dB，
    //    再 <<1 就是 3 dB/像素，与旧实现 pixel_height() 的口径一致。
    //=========================================================================
    function [4:0] msb_of;                              // 最高置位位置（输入 0 → 0）
        input [STW-1:0] v;
        integer i;
        begin
            msb_of = 5'd0;
            for (i = 0; i < STW; i = i + 1)
                if (v[i]) msb_of = i[4:0];
        end
    endfunction

    // Test signed power-of-two thresholds directly. This is exactly the
    // original msb(abs(S1)) transfer function, without the STW-bit abs carry
    // chain after the synchronous history RAM. Negative minimum is included.
    function [4:0] signed_height;
        input signed [STW-1:0] value;
        reg signed [STW:0] extended,threshold;
        integer bit_index,height;
        begin
            signed_height=0;extended={value[STW-1],value};
            for(bit_index=1;bit_index<STW;bit_index=bit_index+1) begin
                if(bit_index>LOFF && bit_index<=LOFF+((HMAX6+1)/2)) begin
                    threshold={{STW{1'b0}},1'b1} << bit_index;
                    height=(bit_index-LOFF)*2;
                    if(extended>=threshold || extended<=-threshold)
                        signed_height=height>HMAX6 ? HMAX6[4:0]:height[4:0];
                end
            end
        end
    endfunction
    wire [4:0] h_new;
    generate if(STW<=32 && HMAX>=0 && HMAX<=31) begin: direct_height
        assign h_new=signed_height(s1q);
    end else begin: legacy_height
        wire [STW-1:0] magnitude=s1q[STW-1] ? (~s1q+1'b1):s1q;
        wire [4:0] level=msb_of(magnitude);
        wire [5:0] delta=(level>LOFF) ? ({1'b0,level}-{1'b0,LOFF}):6'd0;
        wire [5:0] height=delta<<1;
        assign h_new=height>HMAX6 ? HMAX6[4:0]:height[4:0];
    end endgenerate

    //=========================================================================
    // 5) 帧界攻/衰（顺序扫，只用一个比较器 + 一个减法器）
    //
    //    排布约定：向量低位 = 低编号频带，即 lane b 在 bits[b*5 +: 5]。
    //    每拍读**最高 5 位**、算完从**低位**塞回，则 N 拍后：
    //      第 1 拍读到 old[b=N-1]，塞进 lane0；第 2 拍读到 old[N-2]（已被左移 5 位
    //      顶上来），塞进 lane0；…… 第 N 拍读到 old[0]。
    //      结果向量 lane0 = new[0]、lane(N-1) = new[N-1] ⇒ 恰好还原原始排布。
    //    peak_v 同拍左移塞 0 ⇒ 扫完自动清零，交给下一帧。
    //=========================================================================
    wire [4:0] sh_top = shown_v[SW-1 -: 5];
    wire [4:0] pk_top = peak_v [SW-1 -: 5];
    wire [4:0] h_out  = paused ? sh_top
                     : ((pk_top > sh_top)                     ? pk_top
                     : ((decay_use && (sh_top > pk_top) && (sh_top != 5'd0))
                                                              ? (sh_top - 5'd1)
                     :                                          sh_top));

    //=========================================================================
    // 6) 主状态机
    //=========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ph <= P_IDLE; band <= {NBW{1'b0}}; hold_b <= {NBW{1'b0}};
            smp_cnt <= {LOG2B{1'b0}};
            mag_req <= 1'b0; mag_abort <= 1'b0; hold_req <= 1'b0;
            decay_phase <= 1'b0; decay_use <= 1'b0;
            vs_d <= 1'b0; abort_d <= 1'b0;
            shown_v <= {SW{1'b0}}; peak_v <= {SW{1'b0}};
            s1h <= {STW{1'b0}};  x_go <= 16'sd0;
            coef_r <= 16'sd0;
        end
        else begin
            vs_d    <= vs;
            abort_d <= abort_frame;

            // ---- 帧界 / 复位口径 ----
            if (vs & ~vs_d) begin
                hold_req  <= 1'b1;
                decay_use <= decay_phase;               // 用「旧值」判衰（同旧实现）
                if (!paused) decay_phase <= ~decay_phase;
            end
            if (clear_visual) begin
                shown_v     <= {SW{1'b0}};
                decay_phase <= 1'b0;
            end
            if (abort_frame & ~abort_d) begin
                smp_cnt   <= {LOG2B{1'b0}};             // 丢弃半块
                mag_req   <= 1'b1;
                mag_abort <= 1'b1;
            end

            // ---- 阶段机 ----
            case (ph)
            P_IDLE: begin
                if (hold_req) begin
                    hold_b <= LAST_B;                   // 先做显示，样本循环可等一下
                    ph     <= P_HOLD;
                end
                else if (mag_req) begin
                    band    <= LAST_B;                  // 幅值扫描必须降序（见第 5 节）
                    mag_req <= 1'b0;
                    ph      <= P_M0;
                end
                else if (s_valid) begin
                    if (WIN_EN != 0) begin
                        prod_r <= mono16 * w_tri;        // 窗乘共用同一个乘法器
                        ph     <= P_WIN;
                    end else begin
                        x_go <= mono16;
                        ph   <= P_G0;
                    end
                end
            end

            P_WIN: begin
                x_go <= prod_r >>> 15;                  // Q15 还原
                band <= {NBW{1'b0}};
                ph   <= P_G0;
            end

            // ---- 递推：每样本 3 拍/带 ----
            P_G0: begin
                coef_r <= band_coef(band);              // rd_en=1，读 s1[band]/s2[band]
                ph     <= P_G1;
            end
            P_G1: begin
                prod_r <= coef_r * s1q;
                s1h    <= s1q;
                
                ph     <= P_G2;
            end
            P_G2: begin                                 // we=1，写回 s1/s2
                if (band == LAST_B) begin
                    smp_cnt <= (smp_cnt == BLOCK-1) ? {LOG2B{1'b0}}
                                                    : (smp_cnt + 1'b1);
                    if (smp_cnt == BLOCK-1) mag_req <= 1'b1;
                    ph <= P_IDLE;
                end else begin
                    band <= band + 1'b1;
                    ph   <= P_G0;
                end
            end

            // ---- 块末幅值 + 状态复位：每带 3 拍 ----
            P_M0: ph <= P_M1;                           // rd_en=1，读 s1[band]
            P_M1: begin
                peak_v <= mag_abort ? {peak_v[SW-6:0], 5'd0}
                                    : {peak_v[SW-6:0], h_new};
                ph <= P_M2;
            end
            P_M2: begin                                 // we=1，写 0 复位两块 RAM
                if (band == {NBW{1'b0}}) begin
                    mag_abort <= 1'b0;
                    ph        <= P_IDLE;
                end else begin
                    band <= band - 1'b1;
                    ph   <= P_M0;
                end
            end

            // ---- 帧界攻/衰扫描：每带 1 拍 ----
            default: begin                              // P_HOLD
                shown_v <= {shown_v[SW-6:0], h_out};
                peak_v  <= {peak_v [SW-6:0], 5'd0};
                if (hold_b == {NBW{1'b0}}) begin
                    hold_req <= 1'b0;
                    ph       <= P_IDLE;
                end else begin
                    hold_b <= hold_b - 1'b1;
                    ph     <= P_HOLD;
                end
            end
            endcase
        end
    end

    assign heights = shown_v;

endmodule

//=============================================================================
// module : audio_fft_osd   【旧实现，顶层不再例化，保留供回退与比对】
// 功  能 : 256 点纯 RTL FFT → 12 带频谱柱高。
// ★ 面积实测 1012 个 slice（9729/9800 ≈ 99.20%），是 2026-09-28 时序崩盘的
//   直接原因。要回退成这一版，只需把顶层的 audio_goertzel_osd 换成
//   audio_fft_osd —— 端口一模一样。见 doc/timing-diagnosis-2026-09-28.md。
//=============================================================================
module audio_fft_osd #(
    parameter integer FFT_N = 256,
    parameter integer LOG2N = 8
)(
    input wire clk,
    input wire rst,
    input wire vs,
    input wire pcm_valid,
    input wire [23:0] pcm_left,
    input wire [23:0] pcm_right,
    input wire play_run,
    input wire paused,
    input wire stream_restart,
    output wire [59:0] heights
);
    wire signed [16:0] mono_sum =
        {pcm_left[23], pcm_left[23:8]} +
        {pcm_right[23], pcm_right[23:8]};
    wire signed [15:0] mono16 = mono_sum >>> 1;
    wire [23:0] mono24 = {mono16, 8'd0};
    wire active = play_run && !paused;
    wire abort_frame = !active || stream_restart;
    wire clear_visual = stream_restart || !play_run;
    wire fft_rst;
    reset_sync #(.STAGES(3)) u_reset (
        .clk(clk), .rst_in(rst | abort_frame), .rst_out(fft_rst)
    );

    wire log_valid;
    wire [LOG2N-1:0] log_idx;
    wire [15:0] log_value;
    audio_fft_analyzer #(
        .FFT_N(FFT_N), .LOG2N(LOG2N),
        .NMAX(256), .LOG2NMAX(8), .FS_HZ(48_000),
        .USE_WINDOW(1), .CORE_IP(0), .STORE_SPECTRUM(0)
    ) u_an (
        .clk(clk), .rst(fft_rst),
        .s_valid(pcm_valid && active),
        .s_left(mono24), .s_right(mono24),
        .en(active), .chan_sel(1'b0),
        .o_peak_bin(), .o_peak_mag(), .o_peak_freq_hz(),
        .o_frame_cnt(), .o_frame_valid(), .o_busy(), .o_ready(),
        .o_bin_en(), .o_bin_idx(), .o_bin_mag(),
        .o_bin_log(log_value),
        .o_bin_log_en(log_valid), .o_bin_log_idx(log_idx),
        .i_spec_addr({(LOG2N-1){1'b0}}), .o_spec_data()
    );
    fft_osd_bands #(.FFT_N(FFT_N), .LOG2N(LOG2N)) u_bands (
        .clk(clk), .rst(rst), .vs(vs), .pause(paused),
        .abort_frame(abort_frame), .clear_visual(clear_visual),
        .bin_valid(log_valid), .bin_idx(log_idx),
        .bin_log(log_value), .heights(heights)
    );
endmodule

// Two disjoint 16-bit port words implement one exact 25-bit synchronous word.
module resource_goertzel_history_ram(input wire clk,enable,write,
 input wire [5:0] address,input wire [24:0] din,output wire signed [24:0] q);
`ifdef DB_BEHAVIORAL_RAM
 reg [24:0] mem[0:63];reg [24:0] held;integer i;
 initial for(i=0;i<64;i=i+1)mem[i]=0;
 always @(posedge clk)if(enable)begin
   if(write)mem[address]<=din;
   held<=mem[address];
 end
 assign q=held;
`else
 wire [31:0] padded={7'd0,din};wire [31:0] held;
 assign q=held[24:0];
 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
  .INIT_02(256'd0),.INIT_42(256'd0)) u_state(
  .clka(clk),.addra({5'd0,address}),.dia(padded[15:0]),.doa(held[15:0]),
  .bytea(1'b0),.bytewea(1'b0),.csa(enable),.wea(write),.rsta(1'b0),.ocea(1'b1),
  .clkb(clk),.addrb({1'b1,4'd0,address}),.dib(padded[31:16]),.dob(held[31:16]),
  .byteb(1'b0),.byteweb(1'b0),.csb(enable),.web(write),.rstb(1'b0),.oceb(1'b1));
`endif
endmodule
