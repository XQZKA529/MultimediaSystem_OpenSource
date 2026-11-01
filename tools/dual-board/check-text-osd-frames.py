"""Pixel-level sanity checks for the rendered Text OSD visual artifacts."""
from pathlib import Path
import json
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
FRAME_DIR = ROOT / "build" / "ui-text-osd-sim" / "frames"
checks = []

def check(name, condition, detail):
    checks.append({"name": name, "pass": bool(condition), "detail": detail})
    if not condition:
        raise AssertionError(f"{name}: {detail}")

banner = Image.open(FRAME_DIR / "text_osd_banner_short_frame.png").convert("RGB")
threshold = Image.open(FRAME_DIR / "text_osd_banner_threshold75_frame.png").convert("RGB")
editor = Image.open(FRAME_DIR / "text_osd_editor_normal_frame.png").convert("RGB")
long_banner = Image.open(FRAME_DIR / "text_osd_banner_long_frame.png").convert("RGB")
max_banner = Image.open(FRAME_DIR / "text_osd_banner_max256_frame.png").convert("RGB")
focus = Image.open(FRAME_DIR / "text_osd_editor_focus_frame.png").convert("RGB")

for image in (banner, threshold, long_banner, max_banner, editor, focus):
    check("720p_dimensions", image.size == (1280, 720), str(image.size))

# Verify every banner pixel against the independent AA atlas and input image.
# This checks both white coverage and the one-pixel right shadow, including
# all inter-glyph gaps and the region outside the text bounds.
atlas = [int(token, 16) for token in
         (ROOT / "render/sim/aa-font/atlas.hex").read_text().split()]

def image_pixel(x, y):
    return (24 + x // 8, 42 + y // 4, (92 + (x + y) // 8) & 255)

def alpha(index, gx, gy):
    if 0 <= gx < 10 and 0 <= gy < 14:
        return atlas[((ord("A") + index % 26) - 32) * 140 + gy * 10 + gx]
    return 0

def blend(fg, bg, coverage):
    return tuple((f * coverage + b * (3 - coverage) + 1) // 3
                 for f, b in zip(fg, bg))

for rendered, length in ((banner, 24), (threshold, 75), (long_banner, 106), (max_banner, 256)):
    left = 192 if length > 74 else (1280 - 12 * length) // 2
    width = 896 if length > 74 else 12 * length
    gap_pixels = shadow_pixels = aa_pixels = 0
    for y in range(64, 80):
        for x in range(1280):
            expected = image_pixel(x, y)
            if left <= x < left + width:
                dx = x - left
                cell, gx = divmod(dx, 12)
                previous_cell, previous_gx = divmod(dx - 1, 12)
                previous = alpha(previous_cell, previous_gx, y - 64) if x > left else 0
                current = alpha(cell, gx, y - 64)
                if previous:
                    expected = blend((32, 37, 44), expected, 1)
                if current == 0 and previous == 0:
                    gap_pixels += 1
                if current == 0 and previous:
                    shadow_pixels += 1
                if current in (1, 2):
                    aa_pixels += 1
                expected = blend((245, 247, 250), expected, current)
            actual = rendered.getpixel((x, y))
            if actual != expected:
                raise AssertionError(f"banner length={length} ({x},{y}): {actual} != {expected}")
    check(f"banner_{length}_exact_20480_pixels", gap_pixels > 100 and shadow_pixels > 0 and aa_pixels > 0,
          f"gaps={gap_pixels} shadows={shadow_pixels} AA={aa_pixels}")

# The first banner cell contains white glyph pixels and colorful gap pixels.
white = sum(1 for y in range(64, 80) for x in range(496, 784)
            if min(banner.getpixel((x, y))) > 220)
gap = banner.getpixel((506, 72))
check("banner_glyph_visible", white > 100, str(white))
check("banner_gap_not_black_panel", max(gap) > 40 and gap != (20, 23, 27), str(gap))

border = editor.getpixel((446, 286))
outside = editor.getpixel((440, 300))
body = editor.getpixel((500, 350))
focused = focus.getpixel((500, 386))
normal_same = editor.getpixel((500, 386))
check("editor_border", border == (214, 219, 225), str(border))
check("editor_translucent_body", body != (20, 23, 27) and body != outside, f"body={body} outside={outside}")
check("editor_focus_layer", focused != normal_same, f"focus={focused} normal={normal_same}")

report = FRAME_DIR.parent / "visual-check.json"
report.write_text(json.dumps({"checks": checks}, indent=2), encoding="utf-8")
print(report)
