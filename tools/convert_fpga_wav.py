#!/usr/bin/env python3
"""convert_fpga_wav.py — 把任意常见音频转成 FPGA 可播的 WAV。

硬件约束（见 docs/compose/spec/multi-stream-wav.md / wav_header_parse）：
  - RIFF / WAVE
  - PCM (wFormatTag = 1)
  - 48000 Hz
  - 16 bit
  - 1 或 2 声道（单声道 / 立体声）

启动时在终端询问源文件路径；可选输出路径，默认写在源文件同目录
``<stem>_48k16.wav``。支持 wav / 有 Python 标准库能读的格式时仅 wav，
其它格式若装了标准库之外的解码器则尝试失败提示。

用法（工程 tools/ 目录或任意路径）：
  python tools/convert_fpga_wav.py
  python tools/convert_fpga_wav.py "D:\\music\\song.mp3"   # 有输入参数则跳过提问
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
import wave
from pathlib import Path

TARGET_RATE = 48000
TARGET_WIDTH = 2  # bytes per sample
TARGET_CHANNELS = (1, 2)


def ask_path(prompt: str) -> Path:
    raw = input(prompt).strip().strip('"')
    if not raw:
        raise SystemExit("未输入路径，已取消。")
    return Path(raw).expanduser()


def read_wav_frames(path: Path):
    """Return (nchannels, sampwidth_bytes, framerate, frames_bytes)."""
    with wave.open(str(path), "rb") as w:
        nch = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())
    if nch < 1:
        raise ValueError("无有效声道")
    if width not in (1, 2, 3, 4):
        raise ValueError(f"不支持的位深宽度: {width} 字节/样本")
    return nch, width, rate, frames


def to_float_samples(frames: bytes, nch: int, width: int) -> list[float]:
    """Decode to interleaved float in [-1, 1]."""
    if width == 1:  # unsigned 8
        out = [(b - 128) / 128.0 for b in frames]
        return out
    if width == 2:  # little-endian signed 16
        n = len(frames) // 2
        ints = struct.unpack(f"<{n}h", frames[: n * 2])
        return [x / 32768.0 for x in ints]
    if width == 3:  # little-endian signed 24 packed
        out = []
        for i in range(0, len(frames) - 2, 3):
            b0, b1, b2 = frames[i], frames[i + 1], frames[i + 2]
            val = b0 | (b1 << 8) | (b2 << 16)
            if val & 0x800000:
                val -= 0x1000000
            out.append(val / 8388608.0)
        return out
    # width == 4 signed 32
    n = len(frames) // 4
    ints = struct.unpack(f"<{n}i", frames[: n * 4])
    return [x / 2147483648.0 for x in ints]


def resample_float(samples: list[float], src_rate: int, dst_rate: int) -> list[float]:
    """Linear resample interleaved mono-or-multi as flat list (all channels)."""
    if src_rate == dst_rate or not samples:
        return list(samples)
    src_n = len(samples)
    # duration in samples (per channel sequence as flat count / nch is handled outside)
    # Caller resamples each channel separately — see convert().
    dst_n = int(math.floor(src_n * dst_rate / src_rate))
    if dst_n < 1:
        dst_n = 1
    out = [0.0] * dst_n
    ratio = (src_n - 1) / (dst_n - 1) if dst_n > 1 else 0.0
    for i in range(dst_n):
        pos = i * ratio
        i0 = int(pos)
        if i0 >= src_n - 1:
            out[i] = samples[src_n - 1]
        else:
            frac = pos - i0
            out[i] = samples[i0] * (1.0 - frac) + samples[i0 + 1] * frac
    return out


def float_to_s16(x: float) -> int:
    if x > 1.0:
        x = 1.0
    elif x < -1.0:
        x = -1.0
    return int(round(x * 32767.0))


def to_target_channels(flat: list[float], nch: int, target_ch: int) -> list[float]:
    if nch == target_ch:
        return flat
    if target_ch == 2 and nch == 1:
        # mono → stereo interleave
        out: list[float] = []
        for v in flat:
            out.append(v)
            out.append(v)
        return out
    if target_ch == 1 and nch >= 2:
        # downmix by averaging channels
        frames = len(flat) // nch
        out = []
        for f in range(frames):
            acc = 0.0
            base = f * nch
            for c in range(nch):
                acc += flat[base + c]
            out.append(acc / nch)
        return out
    # general: duplicate first / drop extras
    if target_ch < nch:
        frames = len(flat) // nch
        return [flat[f * nch] for f in range(frames)]
    frames = len(flat) // nch
    out = []
    for f in range(frames):
        base = f * nch
        for t in range(target_ch):
            out.append(flat[base + (t % nch)])
    return out


def write_wav_48k16(path: Path, samples_f: list[float], nch: int, rate: int) -> None:
    pcm = b"".join(struct.pack("<h", float_to_s16(v)) for v in samples_f)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(nch)
        w.setsampwidth(TARGET_WIDTH)
        w.setframerate(rate)
        w.writeframes(pcm)


def convert(src: Path, dst: Path | None, target_ch: int | None = None) -> Path:
    if not src.is_file():
        raise SystemExit(f"源文件不存在: {src}")

    # try wave first (stdlib)
    try:
        nch, width, rate, frames = read_wav_frames(src)
    except (wave.Error, EOFError) as e:
        raise SystemExit(
            f"无法用标准库读取 WAV（{e}）。\n"
            "请先转换为未压缩 PCM .wav，或安装 ffmpeg 后用外部工具处理。"
        ) from e

    if nch not in TARGET_CHANNELS and target_ch is None:
        # auto: 2 if >1 else 1
        target_ch = 2 if nch > 1 else 1
    if target_ch is None:
        target_ch = nch if nch in TARGET_CHANNELS else (2 if nch > 1 else 1)

    flat = to_float_samples(frames, nch, width)
    # split channels for independent resample? linear on interleaved with same rate
    # is equivalent per sample index only if we resample each channel.
    chans: list[list[float]] = [[] for _ in range(nch)]
    for i, v in enumerate(flat):
        chans[i % nch].append(v)

    resampled_chans = [resample_float(c, rate, TARGET_RATE) for c in chans]

    # channel map to target
    if nch == target_ch:
        final = []
        length = len(resampled_chans[0])
        for i in range(length):
            for c in range(nch):
                final.append(resampled_chans[c][i])
    elif target_ch == 2 and nch == 1:
        s = resampled_chans[0]
        final = []
        for v in s:
            final.append(v)
            final.append(v)
    elif target_ch == 1:
        length = len(resampled_chans[0])
        final = []
        for i in range(length):
            acc = sum(resampled_chans[c][i] for c in range(nch)) / nch
            final.append(acc)
    else:
        # fallback flatten best effort
        final = to_target_channels(
            [x for c in resampled_chans for x in c], nch * len(resampled_chans[0]),
            target_ch,
        )
        # rebuild properly
        length = len(resampled_chans[0])
        final = []
        for i in range(length):
            for t in range(target_ch):
                final.append(resampled_chans[t % nch][i])

    if dst is None:
        dst = src.with_name(f"{src.stem}_48k16.wav")
    dst.parent.mkdir(parents=True, exist_ok=True)

    write_wav_48k16(dst, final, target_ch, TARGET_RATE)

    # verify with wave
    with wave.open(str(dst), "rb") as w:
        ok = (
            w.getnchannels() in TARGET_CHANNELS
            and w.getsampwidth() == 2
            and w.getframerate() == TARGET_RATE
        )
    if not ok:
        raise SystemExit("输出校验失败。")
    return dst


def main() -> None:
    p = argparse.ArgumentParser(
        description="将音频转为 FPGA 支持的 48 kHz / 16-bit / PCM WAV"
    )
    p.add_argument(
        "src",
        nargs="?",
        help="输入音频路径（省略则启动后询问）",
    )
    p.add_argument(
        "-o",
        "--out",
        nargs="?",
        default=None,
        help="输出 WAV 路径（默认源同目录 *_48k16.wav）",
    )
    p.add_argument(
        "--ch",
        type=int,
        choices=(1, 2),
        default=None,
        help="强制输出声道：1=单声道 2=立体声（默认与源一致，非法则 1/2）",
    )
    args = p.parse_args()

    print("FPGA 音频格式: RIFF/WAVE · PCM · 48000 Hz · 16 bit · mono/stereo")
    if args.src:
        src = Path(args.src).expanduser()
    else:
        src = ask_path("请输入待转换音频路径: ")

    dst = Path(args.out).expanduser() if args.out else None
    if dst is None and not args.src:
        # still allow optional output on interactive path
        more = input("输出路径(回车=自动 <名字>_48k16.wav): ").strip().strip('"')
        if more:
            dst = Path(more).expanduser()

    out = convert(src, dst, target_ch=args.ch)
    print(f"完成: {out}")
    print("将该文件放到 SD 卡 FAT32 根目录，用 KEY3 浏览器选中即可播放。")


if __name__ == "__main__":
    main()
