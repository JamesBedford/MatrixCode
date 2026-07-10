#!/usr/bin/env python3
"""Generate macOS app/screen-saver icons from the web favicon SVG."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
SVG_PATH = ROOT / "public" / "favicon.svg"
RESOURCES = ROOT / "macos" / "MatrixCodeScreenSaver" / "Resources"
APPICONSET = RESOURCES / "Assets.xcassets" / "AppIcon.appiconset"
ICONSET = RESOURCES / "MatrixCode.iconset"
ICNS_PATH = RESOURCES / "MatrixCode.icns"
FONT_CANDIDATES = [
    Path("/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"),
    Path("/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"),
    Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
]


@dataclass(frozen=True)
class Glyph:
    x: float
    y: float
    fill: tuple[int, int, int]
    text: str
    glow: bool


def parse_hex(color: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"#([0-9a-fA-F]{6})", color)
    if not match:
        raise ValueError(f"Unsupported SVG color: {color}")
    raw = match.group(1)
    return (int(raw[0:2], 16), int(raw[2:4], 16), int(raw[4:6], 16))


def load_icon_model() -> tuple[tuple[int, int, int], list[Glyph]]:
    root = ET.parse(SVG_PATH).getroot()
    namespace = {"svg": "http://www.w3.org/2000/svg"}
    rect = root.find("svg:rect", namespace)
    if rect is None:
        raise ValueError(f"{SVG_PATH} does not contain a background rect")
    background = parse_hex(rect.attrib["fill"])
    glyphs: list[Glyph] = []
    for node in root.findall(".//svg:text", namespace):
        glyphs.append(
            Glyph(
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


def font_path() -> Path:
    for path in FONT_CANDIDATES:
        if path.exists():
            return path
    raise FileNotFoundError("No suitable Japanese-capable macOS font found")


def render_icon(size: int, background: tuple[int, int, int], glyphs: list[Glyph]) -> Image.Image:
    scale = size / 64
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((0, 0, size, size), radius=13 * scale, fill=background + (255,))

    font = ImageFont.truetype(str(font_path()), max(1, round(13 * scale)))
    for glyph in glyphs:
        xy = (glyph.x * scale, glyph.y * scale)
        fill = glyph.fill + (255,)
        if glyph.glow:
            glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            ImageDraw.Draw(glow).text(xy, glyph.text, font=font, fill=fill, anchor="mm")
            canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(radius=0.9 * scale)))
        draw.text(xy, glyph.text, font=font, fill=fill, anchor="mm")
    return canvas


def write_png(path: Path, size: int, background: tuple[int, int, int], glyphs: list[Glyph]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    render_icon(size, background, glyphs).save(path)


def write_appiconset(background: tuple[int, int, int], glyphs: list[Glyph]) -> None:
    APPICONSET.mkdir(parents=True, exist_ok=True)
    images = []
    for logical_size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = logical_size * scale
            scale_name = f"{scale}x"
            filename = f"AppIcon-{logical_size}x{logical_size}@{scale_name}.png"
            write_png(APPICONSET / filename, pixels, background, glyphs)
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


def write_icns(background: tuple[int, int, int], glyphs: list[Glyph]) -> None:
    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True)
    for logical_size in (16, 32, 128, 256, 512):
        write_png(ICONSET / f"icon_{logical_size}x{logical_size}.png", logical_size, background, glyphs)
        write_png(ICONSET / f"icon_{logical_size}x{logical_size}@2x.png", logical_size * 2, background, glyphs)
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS_PATH)], check=True)
    shutil.rmtree(ICONSET)


def main() -> None:
    background, glyphs = load_icon_model()
    write_asset_catalog_root()
    write_appiconset(background, glyphs)
    write_icns(background, glyphs)


if __name__ == "__main__":
    main()
