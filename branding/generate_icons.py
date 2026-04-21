#!/usr/bin/env python3
"""Generate branded icon assets for The Alley Mattermost deployment.

Produces dark-background icons with a warm amber/gold "A" letter.
All output goes to the same directory as this script.
"""

import os
from PIL import Image, ImageDraw, ImageFont

OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))

BG_COLOR = (11, 17, 24)        # #0b1118
ACCENT_COLOR = (215, 154, 82)  # #d79a52


def make_icon(size: int) -> Image.Image:
    """Create a single icon at the given pixel size."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Rounded rect background
    radius = max(size // 5, 2)
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=BG_COLOR)

    # Choose font size ~60% of icon size
    font_size = int(size * 0.62)
    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf", font_size)
    except (OSError, IOError):
        try:
            font = ImageFont.truetype("/usr/share/fonts/truetype/liberation/LiberationSerif-Bold.ttf", font_size)
        except (OSError, IOError):
            font = ImageFont.load_default()

    # Center the "A"
    bbox = draw.textbbox((0, 0), "A", font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = (size - tw) / 2 - bbox[0]
    y = (size - th) / 2 - bbox[1]
    draw.text((x, y), "A", fill=ACCENT_COLOR, font=font)

    return img


def main():
    sizes = {
        "favicon-16x16.png": 16,
        "favicon-32x32.png": 32,
        "icon_40x40.png": 40,
        "icon_57x57.png": 57,
        "icon_60x60.png": 60,
        "icon_72x72.png": 72,
        "icon_76x76.png": 76,
        "icon_96x96.png": 96,
        "apple-touch-icon-120x120.png": 120,
        "apple-touch-icon-152x152.png": 152,
    }

    for fname, sz in sizes.items():
        img = make_icon(sz)
        img.save(os.path.join(OUTPUT_DIR, fname), "PNG")
        print(f"  {fname}")

    # favicon.ico with multiple frames
    ico_frames = [make_icon(s) for s in (16, 32, 48)]
    ico_frames[0].save(
        os.path.join(OUTPUT_DIR, "favicon.ico"),
        format="ICO",
        sizes=[(s, s) for s in (16, 32, 48)],
        append_images=ico_frames[1:],
    )
    print("  favicon.ico")
    print("Done.")


if __name__ == "__main__":
    main()
