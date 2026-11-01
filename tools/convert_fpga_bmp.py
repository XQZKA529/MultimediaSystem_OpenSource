#!/usr/bin/env python3
"""Convert an image to the exact BMP format accepted by this FPGA project."""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

try:
    from PIL import Image, ImageColor, ImageOps
except ImportError as exc:  # pragma: no cover - only used for a friendly CLI error
    raise SystemExit(
        "缺少 Pillow。请先执行：python -m pip install Pillow"
    ) from exc


TARGET_SIZE = (1280, 720)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "把 JPG/PNG/BMP 等图片转换为 FPGA 可读取的 "
            "1280x720、24bpp、BI_RGB、bottom-up BMP。"
        )
    )
    parser.add_argument(
        "input",
        type=Path,
        nargs="?",
        help="输入图片路径；省略时在终端中询问",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="输出 BMP；默认写到输入文件旁边，文件名追加 _fpga_1280x720",
    )
    parser.add_argument(
        "--mode",
        choices=("contain", "cover", "stretch"),
        default="contain",
        help=(
            "缩放方式：contain=完整保留并补边（默认）；"
            "cover=铺满后居中裁剪；stretch=直接拉伸"
        ),
    )
    parser.add_argument(
        "--background",
        default="#000000",
        help="contain 模式的补边颜色，如 #000000（默认黑色）",
    )
    return parser.parse_args()


def flatten_to_rgb(image: Image.Image, background: tuple[int, int, int]) -> Image.Image:
    """Apply EXIF orientation and flatten transparency onto a solid RGB canvas."""
    image = ImageOps.exif_transpose(image)
    if image.mode in ("RGBA", "LA") or "transparency" in image.info:
        rgba = image.convert("RGBA")
        canvas = Image.new("RGBA", rgba.size, (*background, 255))
        return Image.alpha_composite(canvas, rgba).convert("RGB")
    return image.convert("RGB")


def resize_image(
    image: Image.Image,
    mode: str,
    background: tuple[int, int, int],
) -> Image.Image:
    if mode == "stretch":
        return image.resize(TARGET_SIZE, Image.Resampling.LANCZOS)

    if mode == "cover":
        return ImageOps.fit(
            image,
            TARGET_SIZE,
            method=Image.Resampling.LANCZOS,
            centering=(0.5, 0.5),
        )

    contained = ImageOps.contain(image, TARGET_SIZE, Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", TARGET_SIZE, background)
    x = (TARGET_SIZE[0] - contained.width) // 2
    y = (TARGET_SIZE[1] - contained.height) // 2
    canvas.paste(contained, (x, y))
    return canvas


def verify_fpga_bmp(path: Path) -> dict[str, int]:
    """Validate every BMP header field used by fat_bmp_controller.v."""
    with path.open("rb") as stream:
        header = stream.read(54)

    if len(header) < 54:
        raise ValueError("输出文件短于标准 54 字节 BMP 头")

    signature = header[0:2]
    file_size = struct.unpack_from("<I", header, 2)[0]
    pixel_offset = struct.unpack_from("<I", header, 10)[0]
    dib_size = struct.unpack_from("<I", header, 14)[0]
    width = struct.unpack_from("<i", header, 18)[0]
    height = struct.unpack_from("<i", header, 22)[0]
    planes = struct.unpack_from("<H", header, 26)[0]
    bit_count = struct.unpack_from("<H", header, 28)[0]
    compression = struct.unpack_from("<I", header, 30)[0]
    actual_size = path.stat().st_size
    row_stride = (width * 3 + 3) & ~3
    required_size = pixel_offset + row_stride * height

    checks = {
        "文件标识必须是 BM": signature == b"BM",
        "DIB 头至少 40 字节": dib_size >= 40,
        "宽度必须是 1280": width == TARGET_SIZE[0],
        "高度必须是正 720（bottom-up）": height == TARGET_SIZE[1],
        "颜色平面数必须是 1": planes == 1,
        "位深必须是 24 bpp": bit_count == 24,
        "压缩方式必须是 BI_RGB(0)": compression == 0,
        "像素偏移必须不小于 54": pixel_offset >= 54,
        "头内文件长度必须等于实际长度": file_size == actual_size,
        "文件必须包含完整像素数据": actual_size >= required_size,
    }
    failed = [name for name, ok in checks.items() if not ok]
    if failed:
        raise ValueError("；".join(failed))

    return {
        "width": width,
        "height": height,
        "bit_count": bit_count,
        "compression": compression,
        "pixel_offset": pixel_offset,
        "file_size": actual_size,
    }


def main() -> int:
    args = parse_args()
    if args.input is None:
        try:
            entered = input("请输入要转换的图片路径：").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n已取消转换。", file=sys.stderr)
            return 2
        # Windows 中从资源管理器复制路径时，用户常会连同双引号一起粘贴。
        entered = entered.strip('"').strip("'")
        if not entered:
            print("错误：没有输入图片路径。", file=sys.stderr)
            return 2
        args.input = Path(entered)

    input_path = args.input.expanduser().resolve()
    if not input_path.is_file():
        print(f"错误：找不到输入图片：{input_path}", file=sys.stderr)
        return 2

    output_path = (
        args.output.expanduser().resolve()
        if args.output
        else input_path.with_name(f"{input_path.stem}_fpga_1280x720.bmp")
    )
    if output_path == input_path:
        print("错误：输出路径不能覆盖输入文件，请指定另一个 -o 路径。", file=sys.stderr)
        return 2

    try:
        background = ImageColor.getcolor(args.background, "RGB")
    except ValueError as exc:
        print(f"错误：补边颜色无效：{args.background}", file=sys.stderr)
        return 2

    output_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        with Image.open(input_path) as source:
            rgb = flatten_to_rgb(source, background)
            converted = resize_image(rgb, args.mode, background)
            # RGB mode makes Pillow emit a 24-bit uncompressed BMP. Pillow writes
            # positive-height BMP rows bottom-up, matching frame_fifo_write's flip.
            converted.save(output_path, format="BMP")
        info = verify_fpga_bmp(output_path)
    except (OSError, ValueError) as exc:
        print(f"转换失败：{exc}", file=sys.stderr)
        return 1

    print("转换成功，并已通过 FPGA 格式自检：")
    print(f"  输入：{input_path}")
    print(f"  输出：{output_path}")
    print(f"  缩放：{args.mode}")
    print(
        "  格式："
        f"{info['width']}x{info['height']}，{info['bit_count']} bpp，"
        f"BI_RGB={info['compression']}，bottom-up，像素偏移 {info['pixel_offset']}"
    )
    print(f"  大小：{info['file_size']} 字节")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
