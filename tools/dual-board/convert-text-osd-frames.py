"""Convert full Text OSD simulation frames to PNGs and inspection crops."""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
FRAME_DIR = ROOT / "build" / "ui-text-osd-sim" / "frames"

if not FRAME_DIR.exists():
    raise SystemExit(f"missing simulation frame directory: {FRAME_DIR}")

for ppm in sorted(FRAME_DIR.glob("text_osd_*_frame.ppm")):
    image = Image.open(ppm).convert("RGB")
    png = ppm.with_suffix(".png")
    image.save(png, optimize=True)
    # Keep the original frame and add focused crops for visual inspection.
    image.crop((380, 0, 900, 70)).resize((1040, 140), Image.Resampling.NEAREST).save(
        ppm.with_name(ppm.stem + "_banner_crop.png"), optimize=True
    )
    image.crop((430, 270, 850, 450)).resize((840, 360), Image.Resampling.NEAREST).save(
        ppm.with_name(ppm.stem + "_editor_crop.png"), optimize=True
    )
    print(png)
