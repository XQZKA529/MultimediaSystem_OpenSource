#!/usr/bin/env python3
"""gen_fft_trig.py — 生成 rtl/fft/fft_trig_rom.v 的余弦查找表。

为什么需要生成：
  FFT 引擎与 Hann 窗都要 cos/sin。工程惯例（见 rtl/ui/font_rom.v）是
  「常量 case 函数」而不是 `initial` + 数组，这样不依赖综合器对
  initialized RAM 的推断能力。但 case 表必须由脚本产出，手抄必错。

表的压缩方式（四分之一波 + 象限恒等式）：
  只存 T[i] = cos(2*pi*i/NMAX)，i = 0..NMAX/4（共 NMAX/4+1 项）。
  任意 k ∈ [0, NMAX/2] 都能由 T 推出：
      k <= NMAX/4 :  cos = T[k]                , sin = T[NMAX/4 - k]
      k >  NMAX/4 :  kk = k - NMAX/4
                     cos = -T[NMAX/4 - kk]     , sin = T[kk]
  （由 cos(a+pi/2) = -sin(a)、sin(a+pi/2) = cos(a) 推得；见 .v 头注释。）
  这样一张表 257 项就覆盖了 1024 点 FFT 全部 N/2 个旋转因子。

用法：
  python tools/gen_fft_trig.py            # 默认 NMAX=1024
  python tools/gen_fft_trig.py 2048       # 换点数（同时要改 .v 里的 NMAX 参数）
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "rtl" / "fft" / "fft_trig_rom.v"


def q15(x: float) -> int:
    """float -> Q1.15 有符号 16bit（饱和到 +32767，避免 1.0 溢出）。"""
    v = int(round(x * 32767.0))
    if v > 32767:
        v = 32767
    if v < -32768:
        v = -32768
    return v


def s16(v: int) -> str:
    """16bit 有符号十进制字面量（负数直接写负号，Verilog 可解析）。"""
    return f"-16'sd{abs(v)}" if v < 0 else f"16'sd{v}"


def emit(nmax: int) -> str:
    log2nmax = int(math.log2(nmax))
    quarter = nmax // 4
    rows = []
    for i in range(quarter + 1):
        c = q15(math.cos(2.0 * math.pi * i / nmax))
        rows.append(f"                {log2nmax}'d{i} : c = {s16(c)};"
                    f"  // cos(2*pi*{i}/{nmax})")

    body = "\n".join(rows)
    return f'''//=============================================================================
// module : fft_trig_rom
// 文件名 : rtl/fft/fft_trig_rom.v
// 功  能 : 余弦查找表（Q1.15，2^15 = 1.0）——
//          表里只存 T[i] = cos(2*pi*i/{nmax})，i = 0..{quarter}，
//          任意 k 的 cos/sin 都用象限恒等式推出，一张表覆盖 {nmax} 点 FFT 全部旋转因子。
//
//  ★ 本文件必须加入 TD 工程源文件清单（Project → Add Source Files）。
//    TD 会在打开/构建工程时用内存里的工程状态回写 `MultimediaSystem_v1.al`，
//    所以在 TD 开着的时候手改 `.al` 是不生效的（会被静默抹掉）。
//
//  ★ 表由 tools/gen_fft_trig.py 生成，不要手改。
//    换 NMAX（即换最大 FFT 点数）：python tools/gen_fft_trig.py <NMAX>，
//    同时改本模块的 NMAX / LOG2NMAX 参数默认值。
//
//  象限恒等式（推导）：
//    记 a = 2*pi*kk/{nmax}，则 2*pi*k/{nmax} = a + pi/2（当 k = kk + {quarter}）
//        cos(a + pi/2) = -sin(a) = -T[{quarter} - kk]
//        sin(a + pi/2) =  cos(a) =  T[kk]
//    因此 k ∈ [0, NMAX/2] 的全部 cos/sin 都只依赖 T[0..NMAX/4]。
//
//  端口时序：同步读口，**2 拍延迟**（本拍给 k，第 3 拍出 cos_q / sin_q）。
//    ★ 为什么是 2 拍而不是 1 拍：TD 综合时，如果"象限运算 + 257 项常量表"
//      和上游的相位索引挤在同一拍，关键路径会到 16 级逻辑 / 18.4 ns，
//      75 MHz（13.333 ns）直接过不去：
//        Begin: u_core/s_reg[0] → End: u_trig/cos_q_reg[14],  Level 16
//      所以内部把表地址也打一拍，把一条长路径切成两条短的：
//        路径① k → 象限（加减/选符号）→ q_idx_r/s_idx_r   （约 4 级）
//        路径② q_idx_r → 常量表 mux → cos_q               （约 5 级）
//    - fft_radix2_burst：twk_acc 是寄存器、整个蝶形期间稳定 ⇒ ph0 给 k，
//      象限在 ph0 算出、ph1 结束寄存好表数据、**ph2 正好做复数乘**。
//    - fft_window_hann：cap_cnt 常驻驱动 k（样本间隔 >> 3 拍），用到时早已稳定。
//
//  精度说明：Q1.15 无法表示 +1.0，cos(0) 取 32767（误差 3.05e-5）。
//    旋转因子按「系数固定、数据可缩放」约定使用，因此此误差只会
//    给频谱带来约 -90 dB 量级的底噪，不影响工程分析用途。
//=============================================================================
module fft_trig_rom #(
    parameter integer NMAX      = {nmax},         // 最大 FFT 点数
    parameter integer LOG2NMAX  = {log2nmax}          // log2(NMAX)
)(
    input  wire                    clk,

    // ---- 相位索引：k 等分一圈，取值 0 .. NMAX/2 ----
    // ★ 契约：k 必须 <= NMAX/2（本模块靠"四分之一波 + 象限恒等式"还原）。
    //   越界时已在内部**饱和钳位到 NMAX/2**（第 0 级），不再静默输出 0；
    //   但钳位后的值仍然是错的 —— 换 NMAX / FFT_N 时务必重新确认调用方满足契约
    //   （sim/tb_fft_elab.v 有参数一致性检查，sim/tb_fft_robust.v 有钳位行为测试）。
    input  wire [LOG2NMAX-1:0]     k,

    // ---- 同步读输出（相对 k 延迟 1 拍）----
    output reg  signed [15:0]      cos_q,       // cos(2*pi*k/NMAX)  Q1.15
    output reg  signed [15:0]      sin_q        // sin(2*pi*k/NMAX)  Q1.15
);
    localparam integer TBW = LOG2NMAX;          // 表索引位宽（0..NMAX/2 可表示）

    //-------------------------------------------------------------------------
    // T[i] = cos(2*pi*i/NMAX)，i = 0 .. NMAX/4        —— 由脚本生成的常量表
    //-------------------------------------------------------------------------
    function signed [15:0] cos_tab;
        input [TBW-1:0] i;
        reg signed [15:0] c;
        begin
            case (i)
{body}
                default : c = 16'sd0;
            endcase
            cos_tab = c;
        end
    endfunction

    // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    // 局部常量：QUARTER = NMAX/4；HALF = NMAX/2
    // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    localparam [TBW-1:0] QUARTER_C = {quarter};
    localparam [TBW-1:0] HALF_C    = {nmax // 2};

    //-------------------------------------------------------------------------
    // 第 0 级：越界饱和（防御性，不是功能路径）
    //   契约要求 k <= NMAX/2。一旦上游给大了，(HALF_C - k) 会下溢，
    //   查表直接落到 default，**静默输出 0**（不是 X，比 X 更隐蔽）。
    //   这里先把 k 钳到 NMAX/2：越界时输出退化为 cos(pi)=-32767/sin=0，
    //   虽然是错的，但有界、可观测（波形上不会"一片 0"骗人）。
    //   ★ 真正的防线在 sim/tb_fft_elab.v 的参数一致性检查 + 调用方契约上，
    //     钳位只是最后一道保险。代价：k 上多一级比较器 + 一级 mux。
    //-------------------------------------------------------------------------
    wire [TBW-1:0] k_raw = k;
    wire [TBW-1:0] k10   = (k_raw > HALF_C) ? HALF_C : k_raw;

    //-------------------------------------------------------------------------
    // 第 1 级：象限运算（只有加减与选符号，无乘法）
    //   cos(2*pi*k/NMAX)：k <= QUARTER ? T[k] : -T[HALF-k]
    //   sin(2*pi*k/NMAX) = cos(2*pi*|QUARTER-k|/NMAX)   （cos 是偶函数）
    //   ↑ 把这一步与下面的查表分成两级，是为了切断 TD 的长组合路径
    //-------------------------------------------------------------------------
    wire           in_quad = (k10 <= QUARTER_C);
    wire [TBW-1:0] idx_q   = in_quad ? k10 : (HALF_C - k10);
    wire [TBW-1:0] diff_k  = (k10 >= QUARTER_C) ? (k10 - QUARTER_C)
                                               : (QUARTER_C - k10);
    wire [TBW-1:0] idx_s   = diff_k;      // diff_k 恒 <= QUARTER（已证）

    reg            neg_r;
    reg [TBW-1:0]  qi_r, si_r;

    always @(posedge clk) begin
        neg_r <= ~in_quad;
        qi_r  <= idx_q;
        si_r  <= idx_s;
    end

    //-------------------------------------------------------------------------
    // 第 2 级：常量表查表（输出寄存）
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        cos_q <= neg_r ? -cos_tab(qi_r) : cos_tab(qi_r);
        sin_q <= cos_tab(si_r);
    end

endmodule
'''


def main() -> None:
    nmax = int(sys.argv[1]) if len(sys.argv) > 1 else 1024
    if nmax < 16 or (nmax & (nmax - 1)) != 0:
        raise SystemExit("NMAX 必须是 >=16 的 2 的幂")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(emit(nmax), encoding="utf-8")
    print(f"生成 {OUT}  (NMAX={nmax}, 表项 {nmax // 4 + 1})")


if __name__ == "__main__":
    main()
