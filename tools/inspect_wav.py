#!/usr/bin/env python3
"""inspect_wav.py — 一眼看清"给 FPGA 播的 WAV"是否合规、以及会播多久。

用法：
  python tools/inspect_wav.py                     # 扫仓库 test_audio/*.wav
  python tools/inspect_wav.py D:\\music\\a.wav ...  # 指定文件

为什么需要它（见 doc/audio-playback-stop-diagnosis.md）：
  · 硬件只接受 48000 Hz / 16 bit / PCM / 单或双声道，且**单声道有已知缺陷**：
    环的 burst-credit 按立体声（每 2 扇区 256 字）预留，单声道却是 512 字/突发
    ⇒ 环溢出、静默丢样、文件被按 ~1.96 倍速消耗 ⇒ 名义时长 D 的文件会在
    D/1.96 处静音（5:20 的单声道 ≈ 2:40 静音）。
  · 所以转换完必须确认声道数；本脚本直接给出"预计静音时刻"。
"""

from __future__ import annotations

import sys
import wave
from pathlib import Path

BYTES_PER_SEC_48K16 = {1: 96000, 2: 192000}
# 单声道缺陷下的实际消耗倍率（credit 只认 260 字/突发，实际 512 字/突发）
MONO_SPEEDUP = 512 / 260.0
DEFAULT_GLOB = "test_audio/*.wav"


def hms(sec: float) -> str:
    sign = "-" if sec < 0 else ""
    sec = abs(sec)
    return f"{sign}{int(sec // 60)}:{sec % 60:04.1f}"


def report(path: Path) -> None:
    size = path.stat().st_size
    with wave.open(str(path), "rb") as w:
        nch = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()
        nframes = w.getnframes()

    dur = nframes / rate
    nom = BYTES_PER_SEC_48K16.get(nch)
    print(f"== {path.name}")
    print(f"   大小 {size} B ({size / 1048576:.2f} MiB) | {nch}ch {width * 8}bit {rate} Hz"
          f" | {nframes} 帧")
    print(f"   时长 {dur:.3f} s = {hms(dur)} | 扇区 {size / 512:.0f}")

    ok = (rate == 48000 and width == 2 and nch in (1, 2))
    print(f"   硬件格式: {'OK' if ok else '★ 不合规（只接受 48k/16bit/PCM/1~2ch）'}")

    if nch == 1:
        stop = dur / MONO_SPEEDUP
        print(f"   ★ 单声道：会静默丢样、按 {MONO_SPEEDUP:.2f}x 消耗，"
              f"预计 {hms(stop)} 处静音（听感也会像快放/发噪）")
    elif nch == 2:
        print(f"   立体声：credit 恰好够（256 字/突发 ≤ 260），按实时播放")

    if nom:
        for label, b in (("32 MiB/2^16 扇区", 65536 * 512),):
            print(f"   {label} = {b / nom:.1f} s = {hms(b / nom)}"
                  f"（旧 16 位 nsec 回绕点，仅作对照）")


def main() -> None:
    args = sys.argv[1:]
    if args:
        paths = [Path(a).expanduser() for a in args]
    else:
        root = Path(__file__).resolve().parent.parent
        paths = sorted(root.glob(DEFAULT_GLOB))
    if not paths:
        raise SystemExit("没找到 WAV。用法：python tools/inspect_wav.py <a.wav> [...]")
    for p in paths:
        if p.is_file():
            report(p)
        else:
            print(f"== {p}  (不存在)")


if __name__ == "__main__":
    main()
