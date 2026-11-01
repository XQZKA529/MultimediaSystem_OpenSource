"""Convert HDL frames and independently check every pixel of the date/time plate."""
import hashlib
import json
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
FRAMES = ROOT / "build/clock-v1/frames"
PREVIEW = ROOT / "build/clock-v1/preview"
PREVIEW.mkdir(parents=True, exist_ok=True)
atlas = [int(token, 16) for token in (ROOT / "render/sim/aa-font/atlas.hex").read_text().split()]


def coverage(character, x, y):
    if 0 <= x < 10 and 0 <= y < 14:
        return atlas[(ord(character) - 32) * 140 + y * 10 + x]
    return 0


def clock_pixel(x, y, background):
    value = tuple(c // 2 for c in background)
    if x in (8, 143) or y in (8, 59):
        return (148, 148, 148)
    text, dx, dy = "", 0, 0
    if 16 <= x < 136 and 16 <= y < 32:
        text, dx, dy = "2026-10-14", x - 16, y - 16
    elif 16 <= x < 112 and 36 <= y < 52:
        text, dx, dy = "12:34:56", x - 16, y - 36
    if text:
        a = coverage(text[dx // 12], dx % 12, dy)
        weight = (0, 1, 3, 4)[a]
        value = tuple((255 * weight + c * (4 - weight)) // 4 for c in value)
    return value


records = []
for case in range(11):
    path = FRAMES / f"clock_case_{case}.ppm"
    frame = Image.open(path).convert("RGB")
    assert frame.size == (1280, 720), path
    count = 0
    for y in range(8, 60):
        for x in range(8, 144):
            background = (0, 0, 0) if 1 <= case <= 7 else (x & 255, y & 255, 165)
            expected = clock_pixel(x, y, background)
            actual = frame.getpixel((x, y))
            assert actual == expected, (case, x, y, actual, expected)
            count += 1
    frame.save(path.with_suffix(".png"), optimize=True)
    records.append({"case": case, "size": list(frame.size), "clock_pixels_checked": count,
                    "ppm_sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
for path in FRAMES.glob("text_osd_*_frame.ppm"):
    frame = Image.open(path).convert("RGB")
    assert frame.size == (1280, 720)
    frame.save(path.with_suffix(".png"), optimize=True)
# UI exports have a photographic base, independent of the synthetic cases.
for name, target in (("ui_settings_frame.ppm", "settings.png"), ("ui_clock_editor_frame.ppm", "editor.png")):
    frame = Image.open(ROOT / name).convert("RGB")
    assert frame.size == (1280, 720)
    frame.save(PREVIEW / target, optimize=True)
    frame.save(FRAMES / Path(name).with_suffix(".png").name, optimize=True)
Image.open(FRAMES / "clock_case_0.png").crop((0, 0, 160, 72)).resize((640, 288)).save(PREVIEW / "clock-crop.png")
Image.open(PREVIEW / "editor.png").crop((430, 270, 850, 450)).resize((840, 360)).save(PREVIEW / "editor-crop.png")
sheet = Image.new("RGB", (1280, 4 * 210), (24, 24, 24))
draw = ImageDraw.Draw(sheet)
for case in range(8):
    x, y = (case % 2) * 640, (case // 2) * 210
    draw.text((x + 8, y + 4), "NORMAL + CLOCK" if case == 0 else f"EMERGENCY MASK {case} + CLOCK", fill="white")
    thumb = Image.open(FRAMES / f"clock_case_{case}.png").resize((320, 180))
    sheet.paste(thumb, (x, y + 24))
    crop = Image.open(FRAMES / f"clock_case_{case}.png").crop((0, 0, 160, 72)).resize((320, 144))
    sheet.paste(crop, (x + 320, y + 24))
sheet.save(PREVIEW / "clock-scenes.png", optimize=True)
report = {"pass": True, "frames": records, "total_clock_pixels_checked": sum(r["clock_pixels_checked"] for r in records)}
(ROOT / "build/clock-v1/visual-check.json").write_text(json.dumps(report, indent=2) + "\n")
print("PASS: 11 complete frames,", report["total_clock_pixels_checked"], "independent date/time pixels; PNG previews exported")
