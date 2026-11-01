#!/usr/bin/env python3
"""Resize an image to the FPGA's fixed 64x64, 24-bit OVERLAY.BMP format."""
from __future__ import annotations

import argparse
import struct
from pathlib import Path
from typing import Optional

from PIL import Image


WIDTH = HEIGHT = 64
ROW_BYTES = WIDTH * 3
PIXEL_BYTES = ROW_BYTES * HEIGHT
FILE_BYTES = 54 + PIXEL_BYTES


def write_bmp(source: Image.Image, output: Path) -> None:
    rgb = source.convert("RGB").resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS)
    with output.open("wb") as f:
        f.write(struct.pack("<2sIHHI", b"BM", FILE_BYTES, 0, 0, 54))
        f.write(struct.pack("<IiiHHIIiiII", 40, WIDTH, HEIGHT, 1, 24, 0,
                            PIXEL_BYTES, 2835, 2835, 0, 0))
        pixels = rgb.load()
        for y in range(HEIGHT - 1, -1, -1):
            for x in range(WIDTH):
                r, g, b = pixels[x, y]
                f.write(bytes((b, g, r)))


def clean_path(value: str) -> Path:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        value = value[1:-1]
    return Path(value).expanduser()


def prompt_path(label: str, default: Optional[Path] = None) -> Path:
    hint = f" [{default}]" if default is not None else ""
    while True:
        value = input(f"{label}{hint}: ").strip()
        if not value and default is not None:
            return default
        if value:
            return clean_path(value)
        print("请输入文件路径。")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", help="source PNG/JPEG/BMP; omitted to enter it in the terminal")
    parser.add_argument("output", nargs="?", help="output BMP; defaults to OVERLAY.BMP")
    args = parser.parse_args()
    interactive = args.source is None
    source_path = clean_path(args.source) if args.source is not None else prompt_path("请输入源图片地址（PNG/JPG/BMP）")
    output_path = (
        clean_path(args.output) if args.output is not None else
        prompt_path("请输入输出文件地址，直接回车使用 OVERLAY.BMP", Path("OVERLAY.BMP")) if interactive else
        Path("OVERLAY.BMP")
    )
    if not source_path.is_file():
        parser.error(f"源图片不存在或不是文件: {source_path}")
    if not output_path.parent.exists():
        parser.error(f"输出目录不存在: {output_path.parent}")
    try:
        with Image.open(source_path) as image:
            write_bmp(image, output_path)
    except OSError as exc:
        parser.error(f"无法读取图片或写入 BMP: {exc}")
    print(f"已生成 {output_path}（{FILE_BYTES} 字节，64×64，24 位 BMP）")


if __name__ == "__main__":
    main()
