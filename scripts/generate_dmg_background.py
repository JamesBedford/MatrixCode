#!/usr/bin/env python3
"""Renders the MatrixCode DMG window backdrop.

Deterministic: regenerating always produces identical bytes. Shares its palette
and drawing helpers with generate_native_icons.py so the disk image, the app
icon and the web icons stay one visual family.

Usage: python3 scripts/generate_dmg_background.py
"""
from __future__ import annotations

import random
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
OUT_PATH = OUT_DIR / "background.png"

# Finder window content area, in points. The PNG is rendered at 2x so it stays
# crisp on Retina; Finder scales it to the window.
WINDOW_W = 700
WINDOW_H = 520
SCALE = 2

# Icon centres in window points. Task 2 reads these so artwork and layout agree.
ICON_POSITIONS = {
    "MatrixCode.app": (180, 235),
    "Applications": (520, 235),
    "MatrixCode.saver": (350, 400),
}

SEED = 0x4D58444D  # "MXDM"
CELL = 26          # glyph cell size in points
TITLE = "MATRIX CODE"
CAPTION = "Double-click to install the screen saver"


def _rain_layer(size: tuple[int, int], rng: random.Random) -> Image.Image:
    """Columns of glyphs with exponentially decaying trails, as in the rain sim."""
    w, h = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cell = CELL * SCALE
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
            alpha = int(235 * (t ** 1.5)) if not is_head else 245
            draw.text((x, y), glyph, font=head_font if is_head else glyph_font,
                      fill=color + (alpha,))
    return layer


def _wordmark(size: tuple[int, int]) -> Image.Image:
    """Glowing MATRIX CODE title centred in the upper band."""
    w, _ = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    font = ImageFont.truetype(str(font_path(HEAVY_FONTS)), 34 * SCALE)
    box = draw.textbbox((0, 0), TITLE, font=font)
    x = (w - (box[2] - box[0])) // 2 - box[0]
    y = 52 * SCALE
    draw.text((x, y), TITLE, font=font, fill=BRIGHT + (255,))

    glow = layer.filter(ImageFilter.GaussianBlur(9 * SCALE))
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    out.alpha_composite(glow)
    out.alpha_composite(glow)
    out.alpha_composite(layer)
    return out


def _arrow(size: tuple[int, int]) -> Image.Image:
    """Chevron pointing from the app icon toward the Applications folder."""
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    y = ICON_POSITIONS["MatrixCode.app"][1] * SCALE
    x0 = (ICON_POSITIONS["MatrixCode.app"][0] + 78) * SCALE
    x1 = (ICON_POSITIONS["Applications"][0] - 78) * SCALE
    draw.line([(x0, y), (x1 - 16 * SCALE, y)], fill=BRIGHT + (170,), width=3 * SCALE)
    draw.polygon(
        [(x1, y), (x1 - 18 * SCALE, y - 11 * SCALE), (x1 - 18 * SCALE, y + 11 * SCALE)],
        fill=BRIGHT + (210,),
    )
    return layer


def _caption(size: tuple[int, int]) -> Image.Image:
    """The saver has no drag target, so the gesture is spelled out instead."""
    w, _ = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    font = ImageFont.truetype(str(font_path(LIGHT_FONTS)), 13 * SCALE)
    box = draw.textbbox((0, 0), CAPTION, font=font)
    x = (w - (box[2] - box[0])) // 2 - box[0]
    # Clears the saver icon's own filename label, which Finder draws directly
    # beneath the 100pt icon centred at ICON_POSITIONS["MatrixCode.saver"].
    draw.text((x, 488 * SCALE), CAPTION, font=font, fill=BRIGHT + (200,))
    return layer


def _icon_pads(size: tuple[int, int]) -> Image.Image:
    """Soft dark pools beneath each icon.

    The app and saver icons are themselves dark rain on black, so without this
    they sink into the backdrop and the glyph columns run straight through them.
    Each pad clears a stage so the icon and its Finder label read cleanly.
    """
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    for cx, cy in ICON_POSITIONS.values():
        layer.alpha_composite(
            radial_layer(size, (cx * SCALE, cy * SCALE), 104 * SCALE,
                         BACKGROUND, 242, falloff=1.35)
        )
    return layer


def render() -> Image.Image:
    size = (WINDOW_W * SCALE, WINDOW_H * SCALE)
    rng = random.Random(SEED)

    base = Image.new("RGBA", size, BACKGROUND + (255,))
    safe_composite(base, _rain_layer(size, rng), (0, 0))

    # Dim the middle so icon labels stay legible over the rain.
    base.alpha_composite(
        radial_layer(size, (size[0] / 2, size[1] / 2), size[0] * 0.62,
                     BACKGROUND, 215, falloff=1.5)
    )
    base.alpha_composite(_icon_pads(size))
    base.alpha_composite(_wordmark(size))
    base.alpha_composite(_arrow(size))
    base.alpha_composite(_caption(size))
    return base.convert("RGB").convert("RGBA")


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    render().convert("RGB").save(OUT_PATH)
    print(f"DMG background written to {OUT_PATH}")


if __name__ == "__main__":
    main()
