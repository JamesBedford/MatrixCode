#!/usr/bin/env python3
"""Renders the MatrixCode DMG window backdrop.

Deterministic: regenerating always produces identical bytes. Shares its palette
and drawing helpers with generate_native_icons.py so the disk image, the app
icon and the web icons stay one visual family.

Two things about Finder drive the output format:

* Finder maps one image *pixel* to one *point* — it does not scale a backdrop to
  fit the window. A 2x image therefore renders at double size and is cropped, so
  the 1x representation must be exactly CANVAS_W x CANVAS_H pixels.
* Retina crispness comes from a multi-representation TIFF instead: `tiffutil
  -cathidpicheck` packs the 1x and 2x renders into one file, and Finder picks
  the representation matching the display.

Usage: python3 scripts/generate_dmg_background.py
"""
from __future__ import annotations

import random
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from generate_native_icons import (
    BACKGROUND,
    BRIGHT,
    HEAD,
    HEAD_GLYPHS,
    HEAVY_FONTS,
    LIGHT_FONTS,
    RAIN_GLYPHS,
    font_path,
    radial_layer,
    safe_composite,
    trail_color,
)

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "macos" / "MatrixCodeScreenSaver" / "Resources" / "DMG"
OUT_PATH = OUT_DIR / "background.tiff"

# Backdrop canvas, in points. Finder's WindowBounds height covers the title bar
# and — when the user has it switched on — the tab bar, so the content area is
# always shorter than the window and by an amount this side cannot control.
#
# Three constants keep that from clipping anything:
#   WINDOW_H     the nominal window box the composition is laid out against
#   SAFE_H       every element sits inside this, so it stays visible even in the
#                shortest case (title bar + tab bar both present)
#   WINDOW_BOUNDS_H  the window height to request, chosen so the content area
#                clears SAFE_H even with both bars showing
WINDOW_W = 700
WINDOW_H = 560
SAFE_H = 450
WINDOW_BOUNDS_H = 580

# Finder draws the backdrop at a fixed size, anchored top-left, and never scales
# it. A window larger than the artwork therefore exposes bare white to the right
# and below — which happens whenever macOS resizes the window, notably when it is
# dragged between displays of differing backing scale. The canvas is drawn well
# past the window so that overflow shows more rain instead. Only the rain bleeds:
# every composed element stays inside WINDOW_W x WINDOW_H.
CANVAS_W = 1200
CANVAS_H = 950

# Representations packed into the TIFF: 1x for non-Retina, 2x for Retina.
SCALES = (1, 2)

# Icon centres in window points. Task 2 reads these so artwork and layout agree.
ICON_POSITIONS = {
    "Matrix Code.app": (180, 190),
    "Applications": (520, 190),
    "Matrix Code.saver": (350, 330),
}

SEED = 0x4D58444D  # "MXDM"
CELL = 26          # glyph cell size in points
TITLE = "MATRIX CODE"
CAPTION = "Double-click to install the screen saver"

# Finder draws icon labels in the system text colour — black in Light Mode — and
# offers no way to override it. Each icon therefore sits on a pale plate so both
# the label and the dark rain-on-black app icon stay legible in either mode.
PLATE = (206, 240, 212)
PLATE_ALPHA = 210
PLATE_W = 148
PLATE_H = 156


def _rain_layer(size: tuple[int, int], scale: int, rng: random.Random) -> Image.Image:
    """Columns of glyphs with exponentially decaying trails, as in the rain sim."""
    w, h = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cell = CELL * scale
    glyph_font = ImageFont.truetype(str(font_path(LIGHT_FONTS)), int(cell * 0.86))
    head_font = ImageFont.truetype(str(font_path(HEAVY_FONTS)), int(cell * 0.86))

    for col in range(0, w // cell + 1):
        x = col * cell
        head_row = rng.uniform(-14, h / cell + 6)
        trail = rng.randint(7, 20)
        for i in range(trail):
            row = head_row - i
            y = row * cell
            if y < -cell or y > h:
                continue
            t = 1.0 - (i / trail)
            is_head = i == 0
            glyph = rng.choice(HEAD_GLYPHS if is_head else RAIN_GLYPHS)
            color = HEAD if is_head else trail_color(t)
            # Trails fade out; the head stays bright.
            alpha = 245 if is_head else int(235 * (t ** 1.5))
            draw.text((x, y), glyph, font=head_font if is_head else glyph_font,
                      fill=color + (alpha,))
    return layer


def _icon_plates(size: tuple[int, int], scale: int) -> Image.Image:
    """Soft pale cards beneath each icon, carrying its Finder label."""
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    plate = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(plate)
    for cx, cy in ICON_POSITIONS.values():
        px, py = cx * scale, (cy + 12) * scale
        half_w, half_h = PLATE_W * scale // 2, PLATE_H * scale // 2
        draw.rounded_rectangle(
            (px - half_w, py - half_h, px + half_w, py + half_h),
            radius=20 * scale, fill=PLATE + (PLATE_ALPHA,),
        )
    layer.alpha_composite(plate.filter(ImageFilter.GaussianBlur(2 * scale)))
    return layer


def _wordmark(size: tuple[int, int], scale: int) -> Image.Image:
    """Glowing MATRIX CODE title centred in the upper band."""
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    font = ImageFont.truetype(str(font_path(HEAVY_FONTS)), 34 * scale)
    box = draw.textbbox((0, 0), TITLE, font=font)
    x = (WINDOW_W * scale - (box[2] - box[0])) // 2 - box[0]
    draw.text((x, 40 * scale), TITLE, font=font, fill=BRIGHT + (255,))

    glow = layer.filter(ImageFilter.GaussianBlur(9 * scale))
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    out.alpha_composite(glow)
    out.alpha_composite(glow)
    out.alpha_composite(layer)
    return out


def _arrow(size: tuple[int, int], scale: int) -> Image.Image:
    """Chevron pointing from the app icon toward the Applications folder."""
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    y = ICON_POSITIONS["Matrix Code.app"][1] * scale
    x0 = (ICON_POSITIONS["Matrix Code.app"][0] + 88) * scale
    x1 = (ICON_POSITIONS["Applications"][0] - 88) * scale
    draw.line([(x0, y), (x1 - 16 * scale, y)], fill=BRIGHT + (190,), width=3 * scale)
    draw.polygon(
        [(x1, y), (x1 - 18 * scale, y - 11 * scale), (x1 - 18 * scale, y + 11 * scale)],
        fill=BRIGHT + (225,),
    )
    return layer


def _caption(size: tuple[int, int], scale: int) -> Image.Image:
    """The saver has no drag target, so the gesture is spelled out instead."""
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    font = ImageFont.truetype(str(font_path(LIGHT_FONTS)), 13 * scale)
    box = draw.textbbox((0, 0), CAPTION, font=font)
    x = (WINDOW_W * scale - (box[2] - box[0])) // 2 - box[0]
    # Below the saver plate, and inside SAFE_H so it is never clipped.
    draw.text((x, 432 * scale), CAPTION, font=font, fill=BRIGHT + (215,))
    return layer


def render(scale: int = 1) -> Image.Image:
    """The backdrop at `scale`x. Seeded per call so every scale shares a layout."""
    size = (CANVAS_W * scale, CANVAS_H * scale)
    rng = random.Random(SEED)

    base = Image.new("RGBA", size, BACKGROUND + (255,))
    safe_composite(base, _rain_layer(size, scale, rng), (0, 0))

    # Dim the middle so the plates and caption sit on a calm field.
    base.alpha_composite(
        radial_layer(size, (WINDOW_W * scale / 2, WINDOW_H * scale / 2),
                     WINDOW_W * scale * 0.62, BACKGROUND, 215, falloff=1.5)
    )
    base.alpha_composite(_icon_plates(size, scale))
    base.alpha_composite(_wordmark(size, scale))
    base.alpha_composite(_arrow(size, scale))
    base.alpha_composite(_caption(size, scale))
    return base.convert("RGB")


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        reps = []
        for scale in SCALES:
            png = Path(tmp) / f"background@{scale}x.png"
            tiff = Path(tmp) / f"background@{scale}x.tiff"
            render(scale).save(png)
            subprocess.run(["sips", "-s", "format", "tiff", str(png), "--out", str(tiff)],
                           check=True, capture_output=True)
            reps.append(str(tiff))
        # -cathidpicheck marks the second representation as the HiDPI variant.
        subprocess.run(["tiffutil", "-cathidpicheck", *reps, "-out", str(OUT_PATH)],
                       check=True, capture_output=True)
    print(f"DMG background written to {OUT_PATH} ({OUT_PATH.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
