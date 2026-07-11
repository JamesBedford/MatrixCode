#!/usr/bin/env python3
"""Generate macOS app/screen-saver icons.

Two size classes, both derived from the classic Matrix palette
(src/config/colorPresets.ts):

- Small icons (canvas <= 64 px) rasterize the web favicon model parsed from
  public/favicon.svg, so Finder-list/tab sizes stay pixel-crisp and identical
  to the browser favicon.
- Large icons (canvas >= 128 px) render a cinematic digital-rain scene:
  a Big Sur-style inset rounded rectangle with a drop shadow, three depth
  layers of stationary-grid rain (blurred far field, mid field, and hero
  columns with bloomed white-green heads), ambient glow, vignette, and
  scanlines echoing the app's post-process. The scene is deterministic
  (seeded RNG), rendered once at high resolution and downscaled per size.

Usage:
    python3 scripts/generate_native_icons.py            # write real assets
    python3 scripts/generate_native_icons.py --preview DIR   # preview PNGs only
"""

from __future__ import annotations

import json
import math
import random
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SVG_PATH = ROOT / "public" / "favicon.svg"
RESOURCES = ROOT / "macos" / "MatrixCodeScreenSaver" / "Resources"
APPICONSET = RESOURCES / "Assets.xcassets" / "AppIcon.appiconset"
ICONSET = RESOURCES / "MatrixCode.iconset"
ICNS_PATH = RESOURCES / "MatrixCode.icns"
WEB_ICONS = ROOT / "public" / "icons"

# Classic preset colors (keep in sync with src/config/colorPresets.ts).
BACKGROUND = (0x0D, 0x02, 0x08)
TAIL = (0x00, 0x3B, 0x00)
BODY = (0x00, 0x8F, 0x11)
BRIGHT = (0x00, 0xFF, 0x41)
HEAD = (0xDE, 0xFF, 0xE4)

# Half-width katakana dominate with a sprinkle of digits, mirroring the
# rain glyph mix in src/sim/glyphSet.ts.
RAIN_GLYPHS = [chr(cp) for cp in range(0xFF66, 0xFF9E)] + list("0357")
# Hero heads draw from visually distinctive katakana only — a dash or
# dot-like glyph as the brightest point in the icon reads as a mistake.
HEAD_GLYPHS = list("ｱｶｷｸｻｼﾂﾃﾈﾊﾎﾒﾓﾗﾜﾝ")

# Deterministic composition; regenerating always yields the same artwork.
SEED = 0x3A7C0DE

# macOS Big Sur icon grid: an 824 px rounded rect centered in a 1024 px
# canvas, corner radius ~185 px, with a soft drop shadow below.
ART_FRACTION = 824 / 1024
CORNER_FRACTION = 185.4 / 824
MASTER_ART_PX = 1648  # artwork master resolution (824 @2x), downscaled per size

HEAVY_FONTS = [
    Path("/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"),
    Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
]
LIGHT_FONTS = [
    Path("/System/Library/Fonts/ヒラギノ角ゴシック W4.ttc"),
    Path("/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"),
    Path("/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"),
    Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
]

Rgb = tuple[int, int, int]


# --------------------------------------------------------------------------
# Shared helpers
# --------------------------------------------------------------------------


def font_path(candidates: list[Path]) -> Path:
    for path in candidates:
        if path.exists():
            return path
    raise FileNotFoundError("No suitable Japanese-capable macOS font found")


def mix(a: Rgb, b: Rgb, t: float) -> Rgb:
    return (
        round(a[0] + (b[0] - a[0]) * t),
        round(a[1] + (b[1] - a[1]) * t),
        round(a[2] + (b[2] - a[2]) * t),
    )


def trail_color(t: float) -> Rgb:
    """Piecewise ramp through tail -> body -> bright -> head for t in [0, 1]."""
    stops: list[tuple[float, Rgb]] = [(0.0, TAIL), (0.45, BODY), (0.82, BRIGHT), (1.0, HEAD)]
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t <= t1:
            span = t1 - t0
            return mix(c0, c1, 0.0 if span == 0 else (t - t0) / span)
    return HEAD


def rounded_mask(size: int, radius_fraction: float) -> Image.Image:
    """Anti-aliased rounded-rect mask rendered at 4x supersample."""
    ss = 4
    big = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        (0, 0, size * ss - 1, size * ss - 1), radius=radius_fraction * size * ss, fill=255
    )
    return big.resize((size, size), Image.LANCZOS)


def radial_layer(size: tuple[int, int], center: tuple[float, float], radius: float,
                 color: Rgb, peak_alpha: int, invert: bool = False, falloff: float = 1.0) -> Image.Image:
    """A radial-gradient RGBA layer: peak alpha at the center fading to 0 at
    `radius` (or the reverse when invert=True, for vignettes)."""
    w, h = size
    # Compute a small distance-true circular falloff and upscale it; Pillow's
    # built-in radial_gradient normalizes to the box corners, which leaves
    # visible alpha at the box edges and reads as rectangular seams.
    n = 129
    stamp = Image.new("L", (n, n), 0)
    px = stamp.load()
    c = (n - 1) / 2
    for yy in range(n):
        for xx in range(n):
            t = min(1.0, math.hypot(xx - c, yy - c) / c)
            a = t ** falloff if invert else (1.0 - t) ** falloff
            px[xx, yy] = round(peak_alpha * a)
    stamp = stamp.resize((round(radius * 2), round(radius * 2)), Image.BILINEAR)
    # Outside the stamp the value saturates at the t=1 level (0 for glows,
    # peak for vignettes), keeping the layer continuous.
    edge = round(peak_alpha) if invert else 0
    alpha = Image.new("L", (w, h), edge)
    alpha.paste(stamp, (round(center[0] - radius), round(center[1] - radius)))
    layer = Image.new("RGBA", (w, h), color + (0,))
    layer.putalpha(alpha)
    return layer


def safe_composite(base: Image.Image, tile: Image.Image, pos: tuple[int, int]) -> None:
    """alpha_composite that tolerates tiles overlapping the image edges."""
    x, y = pos
    left, top = max(0, -x), max(0, -y)
    right = min(tile.width, base.width - x)
    bottom = min(tile.height, base.height - y)
    if left >= right or top >= bottom:
        return
    base.alpha_composite(tile.crop((left, top, right, bottom)), (x + left, y + top))


# --------------------------------------------------------------------------
# Small sizes: rasterize the favicon SVG model (kept in sync with the web)
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class FaviconGlyph:
    x: float
    y: float
    fill: Rgb
    text: str
    glow: bool


def parse_hex(color: str) -> Rgb:
    match = re.fullmatch(r"#([0-9a-fA-F]{6})", color)
    if not match:
        raise ValueError(f"Unsupported SVG color: {color}")
    raw = match.group(1)
    return (int(raw[0:2], 16), int(raw[2:4], 16), int(raw[4:6], 16))


def load_favicon_model() -> tuple[Rgb, list[FaviconGlyph]]:
    root = ET.parse(SVG_PATH).getroot()
    namespace = {"svg": "http://www.w3.org/2000/svg"}
    rect = root.find("svg:rect", namespace)
    if rect is None:
        raise ValueError(f"{SVG_PATH} does not contain a background rect")
    background = parse_hex(rect.attrib["fill"])
    glyphs: list[FaviconGlyph] = []
    for node in root.findall(".//svg:text", namespace):
        glyphs.append(
            FaviconGlyph(
                x=float(node.attrib["x"]),
                y=float(node.attrib["y"]),
                fill=parse_hex(node.attrib["fill"]),
                text=node.text or "",
                glow="filter" in node.attrib,
            )
        )
    if not glyphs:
        raise ValueError(f"{SVG_PATH} does not contain any glyphs")
    return background, glyphs


def render_small_icon(size: int) -> Image.Image:
    """Favicon model drawn inside the standard macOS inset rounded rect."""
    background, glyphs = load_favicon_model()
    art_px = max(1, round(size * ART_FRACTION))
    art = Image.new("RGBA", (art_px, art_px), background + (255,))
    draw = ImageDraw.Draw(art)
    scale = art_px / 64
    font = ImageFont.truetype(str(font_path(HEAVY_FONTS)), max(1, round(13 * scale)))
    for glyph in glyphs:
        xy = (glyph.x * scale, glyph.y * scale)
        fill = glyph.fill + (255,)
        if glyph.glow:
            glow = Image.new("RGBA", (art_px, art_px), (0, 0, 0, 0))
            ImageDraw.Draw(glow).text(xy, glyph.text, font=font, fill=fill, anchor="mm")
            art.alpha_composite(glow.filter(ImageFilter.GaussianBlur(radius=1.1 * scale)))
        draw.text(xy, glyph.text, font=font, fill=fill, anchor="mm")
    return compose_canvas(art, size)


# --------------------------------------------------------------------------
# Large sizes: cinematic rain scene
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class RainLayer:
    columns: int
    glyph_frac: float      # glyph size as a fraction of the artwork side
    min_run: int
    max_run: int
    peak: float            # trail-ramp cap: 1.0 = white head, lower = duller
    alpha: float
    blur_frac: float       # depth-of-field blur as a fraction of the side
    fill_chance: float     # chance a column exists at all
    hero: bool = False


FAR = RainLayer(columns=13, glyph_frac=0.046, min_run=3, max_run=9, peak=0.55,
                alpha=0.6, blur_frac=0.0045, fill_chance=0.8)
MID = RainLayer(columns=9, glyph_frac=0.066, min_run=4, max_run=9, peak=0.74,
                alpha=0.85, blur_frac=0.0015, fill_chance=0.75)
HERO = RainLayer(columns=5, glyph_frac=0.104, min_run=5, max_run=9, peak=1.0,
                 alpha=1.0, blur_frac=0.0, fill_chance=1.0, hero=True)


def glyph_tile(glyph: str, font: ImageFont.FreeTypeFont, color: Rgb, alpha: int,
               mirrored: bool) -> Image.Image:
    pad = round(font.size * 0.35)
    side = font.size + pad * 2
    tile = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    ImageDraw.Draw(tile).text((side / 2, side / 2), glyph, font=font,
                              fill=color + (alpha,), anchor="mm")
    if mirrored:
        tile = tile.transpose(Image.FLIP_LEFT_RIGHT)
    return tile


def draw_layer(art: Image.Image, layer: RainLayer, rng: random.Random,
               font_file: Path) -> None:
    side = art.width
    surface = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    glow_surface = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    glyph_px = round(layer.glyph_frac * side)
    font = ImageFont.truetype(str(font_file), glyph_px)
    cell_h = glyph_px * 1.22
    col_w = side / layer.columns
    rows = int(side / cell_h) + 2

    # Stratified hero head heights: one shuffled slot per column guarantees
    # the bright anchors spread vertically instead of clustering in a band.
    head_band = (0.60, 0.88)
    strata = list(range(layer.columns))
    rng.shuffle(strata)

    for col in range(layer.columns):
        if rng.random() > layer.fill_chance:
            continue
        x = (col + 0.5) * col_w + rng.uniform(-0.08, 0.08) * col_w
        run = rng.randint(layer.min_run, layer.max_run)
        # Hero heads land at a free pixel height in the lower band, clear of
        # the bottom mask edge (a clipped head reads as a mistake), with the
        # trail stacked up the column grid above; trails may run off the top.
        # Background layers sit on the shared grid and bleed past the edges,
        # which the rounded-rect mask crops naturally.
        if layer.hero:
            band_lo, band_hi = head_band
            slot = (band_hi - band_lo) / layer.columns
            lo = band_lo + strata[col] * slot
            head_y = side * rng.uniform(lo, lo + slot)
        else:
            head_row = rng.randint(2, rows - 1)
            head_y = (head_row + 0.5 + rng.uniform(0.0, 1.0)) * cell_h

        for i in range(run):
            y = head_y - i * cell_h
            if y < -cell_h:
                break
            if i > 0 and rng.random() < 0.06:  # irregular dropouts, film-style
                continue
            if y > side + cell_h:
                continue
            # Steep falloff keeps heads dominant; hero trails stay hotter longer.
            decay = (1.0 - i / run) ** (1.15 if layer.hero else 1.4)
            shimmer = 1.0 if layer.hero and i == 0 else rng.uniform(0.88, 1.0)
            t = decay * layer.peak * shimmer
            color = trail_color(t)
            alpha = round(255 * layer.alpha * (0.35 + 0.65 * decay))
            glyph = rng.choice(HEAD_GLYPHS if layer.hero and i == 0 else RAIN_GLYPHS)
            mirrored = rng.random() < 0.4
            tile = glyph_tile(glyph, font, color, alpha, mirrored)
            pos = (round(x - tile.width / 2), round(y - tile.height / 2))
            safe_composite(surface, tile, pos)

            if layer.hero and i == 0:
                # Double-strike the head so it stays hot inside its own bloom.
                safe_composite(surface, tile, pos)
                # Phosphor-point halo behind the head, then glyph-shaped bloom:
                # a tight hot core plus progressively wider, dimmer halos,
                # echoing the renderer's multi-level bloom.
                safe_composite(glow_surface, radial_layer(
                    (round(glyph_px * 2.0),) * 2, (glyph_px, glyph_px),
                    glyph_px, mix(BRIGHT, HEAD, 0.4), 120, falloff=2.0),
                    (round(x - glyph_px), round(y - glyph_px)))
                for radius_frac, halo_alpha, halo_color in (
                    (0.06, 255, HEAD),
                    (0.22, 230, mix(BRIGHT, HEAD, 0.5)),
                    (0.6, 120, BRIGHT),
                ):
                    halo = glyph_tile(glyph, font, halo_color, halo_alpha, mirrored)
                    margin = round(glyph_px * radius_frac * 3)
                    padded = Image.new("RGBA", (halo.width + margin * 2,) * 2, (0, 0, 0, 0))
                    padded.alpha_composite(halo, (margin, margin))
                    padded = padded.filter(
                        ImageFilter.GaussianBlur(radius=glyph_px * radius_frac))
                    safe_composite(glow_surface, padded, (pos[0] - margin, pos[1] - margin))

    if layer.blur_frac > 0:
        surface = surface.filter(ImageFilter.GaussianBlur(radius=layer.blur_frac * side))
    art.alpha_composite(glow_surface)
    art.alpha_composite(surface)


def render_master_art() -> Image.Image:
    """The 824@2x cinematic artwork, downscaled per output size."""
    side = MASTER_ART_PX
    rng = random.Random(SEED)
    art = Image.new("RGBA", (side, side), BACKGROUND + (255,))

    # Atmosphere: darker up top, a soft green ambient glow low-center where
    # the hero heads live.
    top_shade = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    shade_draw = ImageDraw.Draw(top_shade)
    fade_rows = round(side * 0.4)
    for y in range(fade_rows):
        a = round(75 * (1.0 - y / fade_rows) ** 1.6)
        shade_draw.line((0, y, side, y), fill=(0, 0, 0, a))
    art.alpha_composite(top_shade)
    art.alpha_composite(radial_layer(
        (side, side), (side * 0.5, side * 0.62), side * 0.66, BRIGHT, 34, falloff=1.6))

    light_font = font_path(LIGHT_FONTS)
    for layer in (FAR, MID, HERO):
        draw_layer(art, layer, rng, light_font)

    # Post: scanlines then a corner vignette, echoing the app's post-process.
    scan = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    scan_draw = ImageDraw.Draw(scan)
    for y in range(0, side, 6):
        scan_draw.line((0, y, side, y), fill=(0, 0, 0, 26))
    art.alpha_composite(scan)
    art.alpha_composite(radial_layer(
        (side, side), (side * 0.5, side * 0.48), side * 0.9, (0, 0, 0), 120,
        invert=True, falloff=2.6))

    # A whisper of a top rim highlight, like macOS icon material edges.
    rim = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle(
        (0, 0, side - 1, side - 1), radius=CORNER_FRACTION * side,
        outline=(255, 255, 255, 28), width=max(1, side // 400))
    fade = Image.new("L", (side, side), 0)
    fade_draw = ImageDraw.Draw(fade)
    rim_rows = round(side * 0.35)
    for y in range(rim_rows):
        fade_draw.line((0, y, side, y), fill=round(255 * (1.0 - y / rim_rows) ** 1.5))
    rim.putalpha(ImageChops.multiply(rim.getchannel("A"), fade))
    art.alpha_composite(rim)
    return art


def compose_canvas(art: Image.Image, size: int) -> Image.Image:
    """Mask artwork to the Big Sur rounded rect, add drop shadow, center on canvas."""
    art_px = max(1, round(size * ART_FRACTION))
    if art.width != art_px:
        art = art.resize((art_px, art_px), Image.LANCZOS)
    mask = rounded_mask(art_px, CORNER_FRACTION)
    art = art.copy()
    art.putalpha(mask)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    offset = (size - art_px) // 2
    if size >= 32:
        shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        silhouette = Image.new("RGBA", (art_px, art_px), (0, 0, 0, 110))
        silhouette.putalpha(mask.point(lambda v: v * 110 // 255))
        shadow.alpha_composite(silhouette, (offset, offset + max(1, round(size * 0.01))))
        canvas.alpha_composite(shadow.filter(
            ImageFilter.GaussianBlur(radius=max(0.5, size * 0.012))))
    canvas.alpha_composite(art, (offset, offset))
    return canvas


# --------------------------------------------------------------------------
# Asset writing
# --------------------------------------------------------------------------


class IconRenderer:
    """Renders any canvas size, caching the master artwork across sizes."""

    def __init__(self) -> None:
        self._master: Image.Image | None = None

    def master(self) -> Image.Image:
        if self._master is None:
            self._master = render_master_art()
        return self._master

    def render(self, size: int) -> Image.Image:
        if size <= 64:
            return render_small_icon(size)
        return compose_canvas(self.master(), size)


def write_appiconset(renderer: IconRenderer) -> None:
    APPICONSET.mkdir(parents=True, exist_ok=True)
    images = []
    for logical_size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = logical_size * scale
            scale_name = f"{scale}x"
            filename = f"AppIcon-{logical_size}x{logical_size}@{scale_name}.png"
            renderer.render(pixels).save(APPICONSET / filename)
            images.append(
                {
                    "filename": filename,
                    "idiom": "mac",
                    "scale": scale_name,
                    "size": f"{logical_size}x{logical_size}",
                }
            )
    (APPICONSET / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )


def write_asset_catalog_root() -> None:
    root = APPICONSET.parent
    root.mkdir(parents=True, exist_ok=True)
    (root / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )


def write_icns(renderer: IconRenderer) -> None:
    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True)
    for logical_size in (16, 32, 128, 256, 512):
        renderer.render(logical_size).save(ICONSET / f"icon_{logical_size}x{logical_size}.png")
        renderer.render(logical_size * 2).save(
            ICONSET / f"icon_{logical_size}x{logical_size}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS_PATH)], check=True)
    shutil.rmtree(ICONSET)


def write_preview(renderer: IconRenderer, directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        renderer.render(size).save(directory / f"icon_{size}.png")
    print(f"Preview PNGs written to {directory}")


def write_web_icons(renderer: IconRenderer) -> None:
    """Emit the web PWA icon set from the same seeded artwork as the macOS icons.

    Maskable + apple-touch icons are opaque full-bleed squares so iOS/Android
    apply their own corner mask cleanly; the ``any``-purpose icons use the Big
    Sur inset so they look polished (and match the macOS Dock icon) when shown
    un-masked.
    """
    WEB_ICONS.mkdir(parents=True, exist_ok=True)
    master = renderer.master()
    for size, name in ((180, "apple-touch-icon.png"),
                       (192, "icon-192-maskable.png"),
                       (512, "icon-512-maskable.png")):
        master.resize((size, size), Image.LANCZOS).convert("RGB").save(WEB_ICONS / name)
    for size, name in ((192, "icon-192.png"), (512, "icon-512.png")):
        compose_canvas(master, size).save(WEB_ICONS / name)
    print(f"Web icons written to {WEB_ICONS}")


def main() -> None:
    renderer = IconRenderer()
    if len(sys.argv) >= 3 and sys.argv[1] == "--preview":
        write_preview(renderer, Path(sys.argv[2]))
        return
    write_asset_catalog_root()
    write_appiconset(renderer)
    write_icns(renderer)
    write_web_icons(renderer)


if __name__ == "__main__":
    main()
