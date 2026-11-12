#!/usr/bin/env python3
"""Capture Matrix Code marketing showcases from the real WebGL app.

Requires a production build, Python Playwright/Pillow/NumPy, Chromium, and FFmpeg.
Run with --preview-only to review every style before rendering the MP4.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import fcntl
import io
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
import wave
from dataclasses import replace
from functools import lru_cache
from pathlib import Path
from urllib.parse import urlencode
from uuid import uuid4

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFont
import numpy as np
from playwright.sync_api import sync_playwright

from marketing_audio import write_soundtrack
from marketing_model import CAPTURE_EPOCH_MS, CTA, FPS, INVITATION, SIZE, TRANSITION, Film, Scene
from marketing_film_third import THIRD_FILM
from marketing_film_fourth import FOURTH_FILM
from marketing_film_fifth import FIFTH_FILM
from marketing_film_sixth import SIXTH_FILM
from marketing_film_seventh import SEVENTH_FILM
from marketing_film_eighth import EIGHTH_FILM
from marketing_shorts import SHORT_CLIPS, SHORT_FILMS
from marketing_film_showcase import SHOWCASE_CLIPS, SHOWCASE_FILMS
from marketing_film_quotes import QUOTES_FILM
from marketing_film_loop import CLASSIC_LOOP_FILM
from marketing_loop import loop_filter, verify_loop

def find_project_root() -> Path:
    for directory in Path(__file__).resolve().parents:
        if (directory / "package.json").is_file() and (directory / "src/main.ts").is_file():
            return directory
    raise RuntimeError("The video skill must live inside a MatrixCode checkout")


ROOT = find_project_root()
TEMP_ROOT = Path("/Volumes/DATA/Temp") if Path("/Volumes/DATA").is_dir() else Path(tempfile.gettempdir())
SITE = "julimbob.com/matrixcode"
TITLE_BOTTOM_MARGIN = 200
TITLE_LEFT = 78
BASE_SETTINGS = {
    "ramp": 0, "adaptive": 0, "quality": "high", "vignette": 0.15,
    "overlap": "false", "lead": 1.6,
}


def rabbit_mask() -> dict:
    """An original silhouette imported through the app's portable image format."""
    background = 60
    mask = Image.new("L", (384, 384), color=background)
    draw = ImageDraw.Draw(mask)
    draw.ellipse((63, 155, 277, 351), fill=255)  # body
    draw.ellipse((195, 103, 326, 231), fill=255)  # head
    draw.ellipse((218, 12, 249, 143), fill=255)  # upright ears
    draw.ellipse((269, 24, 301, 151), fill=255)
    draw.ellipse((32, 230, 104, 302), fill=255)  # tail
    draw.ellipse((148, 315, 319, 357), fill=255)  # foot
    draw.ellipse((287, 142, 301, 157), fill=background)  # eye
    mask = mask.resize((96, 96), Image.Resampling.LANCZOS)
    return {"name": "White rabbit", "width": mask.width, "height": mask.height,
            "data": base64.b64encode(mask.tobytes()).decode("ascii")}


FIRST_FILM = Film("first", "Matrix Code — Find your style", (
    Scene("classic", "Classic green", 5.5,
          {"preset": "classic", "density": 5, "size": 1.5, "glow": 1.2, "speed": 1, "trail": 0.25}),
    Scene("blue", "Electric blue binary", 4.5,
          {"preset": "blue", "glyphs": "binary", "density": 7, "size": 1.8, "glow": 1.35, "speed": 1.4, "trail": 0.16}),
    Scene("amber", "Amber terminal", 4.5,
          {"preset": "amber", "glyphs": "digits", "font": "terminal", "density": 6, "size": 2, "glow": 0.85, "speed": 0.75, "trail": 0.18, "scanlines": "true"}),
    Scene("purple", "Neon purple", 4.5,
          {"preset": "purple", "glyphs": "katakana", "density": 8, "size": 1.4, "glow": 1.9, "speed": 1.05, "trail": 0.32}),
    Scene("columns", "More columns", 4.5,
          {"preset": "classic", "density": 12, "size": 0.65, "glow": 0.9, "speed": 1.15, "trail": 0.18}),
    Scene("non-overlapping", "Non-overlapping rain columns", 6.5,
          {"preset": "classic", "density": 60, "size": 1.6, "glow": 0.65, "speed": 1.2, "trail": 0.12},
          overlap_comparison=True),
    INVITATION,
), Path("matrixcode-styles.mp4"))

SECOND_FILM = Film("second", "Matrix Code — Beyond the green", (
    Scene("red", "Red symbol storm", 5.5,
          {"preset": "red", "glyphs": "symbols", "density": 9, "size": 1.4,
           "glow": 1.1, "speed": 2.5, "trail": 0.1, "glyphrate": 4}),
    Scene("gold", "Golden slow motion", 4.5,
          {"preset": "gold", "font": "mincho", "density": 5, "size": 2.3,
           "glow": 0.65, "speed": 0.35, "trail": 0.42, "trailvar": 0.15,
           "glyphrate": 0.15}, warmup=40),
    Scene("white", "Monochrome lettering", 4.5,
          {"preset": "white", "glyphs": "latin", "font": "mono", "mirror": "false",
           "density": 7, "size": 1.8, "glow": 0.3, "speed": 0.9, "trail": 0.24}),
    Scene("teal", "Your own colour", 4.5,
          {"preset": "custom", "color": "#00FFD5", "font": "rounded", "density": 9,
           "size": 1.2, "glow": 2.2, "speed": 1.2, "trail": 0.36, "lead": 2}),
    Scene("images", "Images in the rain", 5.5,
          {"preset": "orange", "glyphs": "latin", "font": "mono", "mirror": "false",
           "density": 25, "size": 0.65, "glow": 0.3, "lead": 0,
           "speed": 1.3, "trail": 0.4},
          documents={"mx-images": {
              "images": [rabbit_mask()], "enabled": True, "frequencyMs": 500,
              "persistenceMs": 10000, "appearMs": 2200, "disappearMs": 0,
              "flickerOut": True, "brightnessFade": True,
              "imageScale": 0.72, "imagePlacementJitter": 0,
          }}, preview_seconds=4, start_images_after_warmup=True),
    Scene("countdown", "Count down to anything", 5.5,
          {"preset": "pink", "density": 6, "size": 3.3, "glow": 0.8,
           "speed": 1.5, "trail": 0.32, "glyphs": "digits", "lead": 0.7,
           "glyphrate": 5}, warmup=12,
          documents={
              "mx-countdown": {"targetMs": None, "moments": [
                  {"name": "Launch", "targetMs": CAPTURE_EPOCH_MS + 60_000},
              ]},
              "mx-messages": {
                  "messages": ["LAUNCH {countdown:Launch}"], "enabled": True,
                  "frequencyMs": 500, "persistenceMs": 60000, "appearMs": 800,
                  "disappearMs": 0, "flickerOut": False, "brightnessFade": False,
                  "messageLayout": "row", "verticalPosition": 0.5, "verticalJitter": 0,
                  "horizontalPosition": 0.5, "horizontalJitter": 0,
              },
          }, focus_text="LAUNCH 00:00"),
    INVITATION,
), Path("features/matrixcode-features.mp4"))

FILMS = {film.key: film for film in (FIRST_FILM, SECOND_FILM, THIRD_FILM, FOURTH_FILM,
                                  FIFTH_FILM, SIXTH_FILM, SEVENTH_FILM, EIGHTH_FILM)}
# Shorts are a separate mode. `all` stays the eight long tours.
CATALOG = {**FILMS, **SHORT_FILMS, **SHOWCASE_FILMS, QUOTES_FILM.key: QUOTES_FILM,
           CLASSIC_LOOP_FILM.key: CLASSIC_LOOP_FILM}
FILM_GROUPS = {
    "both": ("first", "second"), "new": ("third", "fourth", "fifth"),
    "styles": ("sixth", "seventh", "eighth"), "all": tuple(FILMS),
    "shorts": tuple(film.key for film in SHORT_CLIPS),
    "showcase": tuple(film.key for film in SHOWCASE_CLIPS),
}
# One Chromium WebGL capture at a time per slot. Sixty shorts share three slots.
SHORT_RENDER_SLOTS = 3
PLATFORM_LABELS = ("browser", "screensaver", "both monitors")
TITLE_FILL = "#F5F7F6"
PLATFORM_LABEL_GAP = 10
# Preserve imports used by existing audio-preview commands for the first film.
SCENES = FIRST_FILM.scenes
DURATION = FIRST_FILM.duration
TRANSITIONS = FIRST_FILM.transitions


def scene_versions(scene: Scene) -> list[Scene]:
    """Run comparison views on the same clock with only declared controls changed."""
    settings = scene.comparison_settings
    title = scene.comparison_title or scene.title
    name = f"{scene.name}-comparison"
    if settings is None and scene.overlap_comparison:
        settings, title, name = {"overlap": "true"}, "Overlapping rain columns", "overlapping"
    if settings is None:
        return [scene]
    return [scene, replace(scene, name=name, title=title,
                           settings={**scene.settings, **settings}, overlap_comparison=False,
                           comparison_settings=None, comparison_title=None)]


def preview_path(directory: Path, index: int, scene: Scene) -> Path:
    return directory / f"{index:02d}-{scene.name}.jpg"

# Advance the normal app's RAF loop in exact frame increments; capture speed cannot
# change the motion. Fresh storage lives only in the throwaway browser context.
CLOCK_SCRIPT = r"""(() => {
  let now = 0, nextId = 0;
  const callbacks = new Map();
  Object.defineProperty(performance, 'now', {value: () => now});
  window.requestAnimationFrame = callback => {
    callbacks.set(++nextId, callback);
    return nextId;
  };
  window.cancelAnimationFrame = id => callbacks.delete(id);
  window.__videoAdvance = (frames = 1) => {
    for (let frame = 0; frame < frames; frame++) {
      now += FRAME_MILLISECONDS;
      const current = [...callbacks.values()];
      callbacks.clear();
      for (const callback of current) callback(now);
    }
  };
  const OriginalDate = Date;
  const epoch = CAPTURE_EPOCH;
  window.Date = class extends OriginalDate {
    constructor(...args) { super(...(args.length ? args : [epoch + now])); }
    static now() { return epoch + now; }
  };
  localStorage.clear();
  sessionStorage.clear();
  const documents = STORAGE_DOCUMENTS;
  for (const [key, value] of Object.entries(documents)) {
    localStorage.setItem(key, JSON.stringify(value));
  }
  if (CLOSING_INVITATION && typeof WebGL2RenderingContext !== 'undefined') {
    const {cols, rows, cells} = MESSAGE_LAYOUT;
    const invitationGaps = INVITATION_GAPS;
    const upload = WebGL2RenderingContext.prototype.texSubImage2D;
    WebGL2RenderingContext.prototype.texSubImage2D = function (...args) {
      if (window.__videoPlainMessage && args.length === 9 &&
          args[0] === this.TEXTURE_2D && args[1] === 0 && args[2] === 0 && args[3] === 0 &&
          args[4] === cols && args[5] === rows && args[6] === this.RGBA &&
          args[7] === this.UNSIGNED_BYTE && args[8] instanceof Uint8Array &&
          args[8].length === cols * rows * 4) {
        // Finish the invitation at its held brightness, without head highlights.
        // Grade a render copy so the app's simulation keeps advancing normally.
        const pixels = args[8].slice();
        const brightness = Math.min(...cells.map(cell => pixels[cell * 4 + 1]));
        for (const cell of cells) {
          pixels[cell * 4 + 1] = brightness;
          pixels[cell * 4 + 2] &= 0x3f; // retain the glyph crossfade phase
        }
        for (const cell of invitationGaps) {
          pixels[cell * 4 + 1] = 0;
          pixels[cell * 4 + 2] = 0;
        }
        args[8] = pixels;
      }
      return Reflect.apply(upload, this, args);
    };
  }
  const credit = CREDIT_STAMP;
  if (credit && typeof WebGL2RenderingContext !== 'undefined') {
    const uploadCredit = WebGL2RenderingContext.prototype.texSubImage2D;
    const claimed = {};
    WebGL2RenderingContext.prototype.texSubImage2D = function (...args) {
      if (args.length === 9 &&
          args[0] === this.TEXTURE_2D && args[1] === 0 && args[2] === 0 && args[3] === 0 &&
          args[4] === credit.cols && args[5] === credit.rows && args[6] === this.RGBA &&
          args[7] === this.UNSIGNED_BYTE && args[8] instanceof Uint8Array &&
          args[8].length === credit.cols * credit.rows * 4) {
        // The quote itself is the app's message, so streams claim it and the
        // flicker-in resolves it. The handle is a second row the scheduler
        // cannot draw. This copy follows the same claim, scramble, and head flash.
        const pixels = args[8].slice();
        const now = performance.now();
        const age = now - credit.fireMs;
        const appear = credit.appearMs;
        const scramble = age < 0 ? 1 : (appear > 0 && age < appear ? 1 - age / appear : 0);
        const tick = Math.floor(now / (1000 / 30));
        for (const pair of credit.cells) {
          const cell = pair[0];
          const glyph = pair[1];
          const offset = cell * 4;
          const flags = pixels[offset + 2];
          const isHead = (flags & 0x80) !== 0;
          if (!claimed[cell] && !isHead && pixels[offset + 1] > 12) {
            // About the sim's per-frame mutation chance at glyphRate 1.
            if (((cell * 13 + tick) % 1000) / 1000 < 0.052) claimed[cell] = 1;
          }
          if (!claimed[cell]) continue;
          if (!isHead && ((cell * 17 + tick) % 100) / 100 >= scramble) {
            pixels[offset] = glyph;
            pixels[offset + 3] = glyph;
          }
          pixels[offset + 1] = Math.max(pixels[offset + 1], 115); // messageBrightFloor 0.45
        }
        args[8] = pixels;
      }
      return Reflect.apply(uploadCredit, this, args);
    };
  }
})();"""


def font(size: int, bold: bool = False, mono: bool = False):
    candidates = (
        ["/System/Library/Fonts/Menlo.ttc", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]
        if mono else
        [f"/System/Library/Fonts/Supplemental/Arial{' Bold' if bold else ''}.ttf",
         f"/usr/share/fonts/truetype/dejavu/DejaVuSans{'-Bold' if bold else ''}.ttf"]
    )
    for candidate in candidates:
        if Path(candidate).is_file():
            return ImageFont.truetype(candidate, size)
    return ImageFont.load_default(size=size)


def ease(value: float) -> float:
    value = min(1, max(0, value))
    return value * value * (3 - 2 * value)


def shade() -> Image.Image:
    layer = Image.new("RGBA", SIZE)
    draw = ImageDraw.Draw(layer)
    for y in range(SIZE[1]):
        top = 130 * max(0, 1 - y / 240) ** 2
        bottom = 205 * max(0, (y - 675) / (SIZE[1] - 675)) ** 1.2
        draw.line((0, y, SIZE[0], y), fill=(0, 0, 0, round(max(top, bottom))))
    return layer


SHADE = shade()
TITLE_FONT = font(72, bold=True)
SITE_FONT_SIZE = 56
ENDING_TITLE_FONT_SIZE = 50
ENDING_SITE_FONT_SIZE = 66
SITE_FONT = font(SITE_FONT_SIZE, mono=True)
ENDING_TITLE_FONT = font(ENDING_TITLE_FONT_SIZE, bold=True)
ENDING_SITE_FONT = font(ENDING_SITE_FONT_SIZE)
CORNER_SITE_POSITION = (SIZE[0] - 82, 63)
ENDING_TITLE_POSITION = (SIZE[0] / 2, 391)
ENDING_SITE_POSITION = (SIZE[0] / 2, 729)


def message_layout(glyph_scale: float = INVITATION.settings["size"], text: str = CTA,
                   config: dict | None = None) -> dict:
    """Match the app's row/drop placement for capture-only message grading."""
    config = config or {}
    cols = max(8, math.floor(SIZE[0] / (18 * glyph_scale) + 0.5))
    rows = max(8, math.floor(SIZE[1] / (18 * glyph_scale) + 0.5))
    drop = config.get("messageLayout", "row") == "drop"
    message_cols, message_rows = (1, len(text)) if drop else (len(text), 1)
    if message_cols > cols or message_rows > rows:
        raise ValueError(f"Message does not fit the capture grid: {text!r}")
    start_col = min(cols - message_cols, max(0, math.floor(
        cols * config.get("horizontalPosition", 0.5) - message_cols / 2 + 0.5)))
    start_row = min(rows - message_rows, max(0, math.floor(
        rows * config.get("verticalPosition", 0.5) - message_rows / 2 + 0.5)))
    reverse = drop and config.get("messageDirection") == "bottomToTop"
    return {"cols": cols, "rows": rows,
            "cells": [(start_row + (len(text) - 1 - offset if reverse else offset)) * cols + start_col
                      if drop else start_row * cols + start_col + offset
                      for offset, char in enumerate(text) if char != " "]}


MESSAGE_LAYOUT = message_layout()


def invitation_gap_cells(text: str = CTA, glyph_scale: float = INVITATION.settings["size"],
                         config: dict | None = None, pad_rows: int = 0) -> list[int]:
    """Space cells inside the invitation line, so rain does not sit inside the words.

    pad_rows also clears the rain directly above and below each space. A bright
    glyph in that cell reads as part of the phrase.
    """
    layout = message_layout(glyph_scale, text, config)
    cols, rows = layout["cols"], layout["rows"]
    first = next(index for index, character in enumerate(text) if character != " ")
    origin = min(layout["cells"]) - first
    gaps = []
    for offset, character in enumerate(text):
        if character != " ":
            continue
        cell = origin + offset
        row, col = divmod(cell, cols)
        for delta in range(-pad_rows, pad_rows + 1):
            padded = row + delta
            if 0 <= padded < rows:
                gaps.append(padded * cols + col)
    return gaps


def scene_invitation_gaps(scene: Scene) -> list[int]:
    """Space cells the shared invitation clears during its final plain second."""
    if not scene.message:
        return []
    return invitation_gap_cells()


INVITATION_GAPS = invitation_gap_cells()

# Mirrors src/sim/glyphSet.ts. Message glyphs start after katakana, digits, Latin, and symbols.
_MESSAGE_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=+-*<>:.,!?'@"
_MESSAGE_START = 56 + 10 + 26 + 7


def message_glyph(character: str) -> int | None:
    """Glyph index for one message character, or None for a space or unsupported mark."""
    if character == " ":
        return None
    index = _MESSAGE_CHARS.find(character)
    if index < 0:
        return None
    return _MESSAGE_START + index


def _mulberry32(seed: int):
    """One mulberry32 sample stream, matching src/util/rng.ts."""
    a = seed & 0xFFFFFFFF

    def to_i32(value: int) -> int:
        value &= 0xFFFFFFFF
        return value - 0x100000000 if value >= 0x80000000 else value

    def imul(left: int, right: int) -> int:
        return to_i32(to_i32(left) * to_i32(right))

    def rng() -> float:
        nonlocal a
        a = to_i32(a + 0x6D2B79F5)
        mixed = imul(to_i32(a ^ ((a & 0xFFFFFFFF) >> 15)), to_i32(1 | a))
        updated = to_i32(mixed + imul(to_i32(mixed ^ ((mixed & 0xFFFFFFFF) >> 7)), to_i32(61 | mixed)))
        mixed = to_i32(updated ^ mixed)
        return ((mixed & 0xFFFFFFFF) ^ ((mixed & 0xFFFFFFFF) >> 14)) / 4294967296

    return rng


def first_message_fire_ms(frequency_ms: float = 500) -> float:
    """Clock time when the first saved message fires.

    MessageScheduler waits one jittered gap after its first frame. That gap is
    the first sample of MSG_SEED (0x5eed1e). Capture steps the clock by 1000/FPS.
    """
    gap = frequency_ms * (0.75 + 0.5 * _mulberry32(0x5EED1E)())
    frame = 1000 / FPS
    fire = frame
    while fire + 1e-9 < frame + gap:
        fire += frame
    return fire


def plain_message(scene: Scene, frame_number: int, frame_count: int) -> bool:
    """Settle only the shared invitation, and only during its final second."""
    return bool(scene.message and frame_number >= frame_count - FPS)


def _held_cells(text: str, cols: int, row: int, start_col: int, scene_name: str) -> list[list[int]]:
    cells = []
    for offset, character in enumerate(text):
        glyph = message_glyph(character)
        if glyph is None:
            if character != " ":
                raise ValueError(f"{scene_name}: unsupported message character {character!r}")
            continue
        cells.append([row * cols + start_col + offset, glyph])
    return cells


def credit_stamp(scene: Scene) -> dict | None:
    """Handle cells one blank row under the quote. The quote itself stays in the scheduler."""
    line = scene.credit_line
    if not line:
        return None
    quote = scene.focus_text
    if not quote or quote[:1] == " ":
        raise ValueError(f"{scene.name}: a credit line needs a focused message")
    config = (scene.documents or {}).get("mx-messages", {})
    quote_layout = message_layout(scene.settings["size"], quote, config)
    cols, rows = quote_layout["cols"], quote_layout["rows"]
    quote_cell = min(quote_layout["cells"])
    quote_row, _quote_col = divmod(quote_cell, cols)
    # One blank row keeps the handle from blooming into the quote.
    handle_row = quote_row + 2
    if handle_row >= rows or len(line) > cols:
        raise ValueError(f"{scene.name}: credit line does not fit under {quote!r}")
    start_col = min(cols - len(line), max(0, math.floor(
        cols * config.get("horizontalPosition", 0.5) - len(line) / 2 + 0.5)))
    return {
        "cols": cols, "rows": rows,
        "cells": _held_cells(line, cols, handle_row, start_col, scene.name),
        "appearMs": int(config.get("appearMs", 0)),
        "fireMs": first_message_fire_ms(float(config.get("frequencyMs", 500))),
    }


def message_mask(layout: dict = MESSAGE_LAYOUT) -> Image.Image:
    """Select existing message cells for a finishing grade, without drawing text."""
    cols, rows = layout["cols"], layout["rows"]
    cell_w, cell_h = SIZE[0] / cols, SIZE[1] / rows
    mask = Image.new("L", SIZE)
    draw = ImageDraw.Draw(mask)
    for cell in layout["cells"]:
        col, row = cell % cols, cell // cols
        draw.rectangle((round(col * cell_w), round(row * cell_h),
                        round((col + 1) * cell_w) - 1,
                        round((row + 1) * cell_h) - 1), fill=255)
    return mask


MESSAGE_MASK = message_mask()


@lru_cache(maxsize=32)
def focus_mask(glyph_scale: float, text: str, layout: str = "row",
               direction: str = "topToBottom", vertical_position: float = 0.5,
               horizontal_position: float = 0.5) -> Image.Image:
    return message_mask(message_layout(glyph_scale, text, {
        "messageLayout": layout, "messageDirection": direction,
        "verticalPosition": vertical_position, "horizontalPosition": horizontal_position,
    }))


def scene_focus_mask(scene: Scene) -> Image.Image:
    document = (scene.documents or {}).get("mx-messages", {})
    if document.get("verticalJitter", 0) or document.get("horizontalJitter", 0):
        raise ValueError("Focused marketing messages require fixed placement")
    mask = focus_mask(scene.settings["size"], scene.focus_text,
                      document.get("messageLayout", "row"),
                      document.get("messageDirection", "topToBottom"),
                      document.get("verticalPosition", 0.5), document.get("horizontalPosition", 0.5))
    stamp = credit_stamp(scene)
    if not stamp:
        return mask
    credit = message_mask({"cols": stamp["cols"], "rows": stamp["rows"],
                           "cells": [cell for cell, _glyph in stamp["cells"]]})
    return ImageChops.lighter(mask, credit)


def grade_message(frame: Image.Image, mask: Image.Image, ink: Image.Image, focus: float,
                  dim: float = 0.66, boost: float = 1.65) -> Image.Image:
    ambient = ImageEnhance.Brightness(frame).enhance(1 - dim * focus)
    letters = ImageEnhance.Brightness(frame).enhance(1 + boost * focus)
    ink = ink.point(lambda value: min(255, max(0, (value - 12) * 9)))
    return Image.composite(letters, ambient, ImageChops.multiply(mask, ink))


def iter_platform_labels():
    """Yield each platform label, its top-left origin, and its text bounds.

    The scene name keeps the long-film title slot. These three names sit at the
    top left, in the same face, with no plate.
    """
    probe = ImageDraw.Draw(Image.new("RGB", SIZE))
    sample = probe.textbbox((0, 0), "Hg", font=TITLE_FONT, anchor="lt")
    step = (sample[3] - sample[1]) + PLATFORM_LABEL_GAP
    y = 56
    for label in PLATFORM_LABELS:
        origin = (TITLE_LEFT, y)
        yield label, origin, probe.textbbox(origin, label, font=TITLE_FONT, anchor="lt")
        y += step


def burn_platform_labels(draw: ImageDraw.ImageDraw) -> None:
    """Draw the three platform names at full strength. They do not fade in."""
    for label, origin, _bounds in iter_platform_labels():
        draw.text(origin, label, font=TITLE_FONT, fill=TITLE_FILL, anchor="lt")


def scene_title_layer(title: str, seconds: float) -> Image.Image:
    """The lower-left scene name, with the same face, place, and entrance as the long films."""
    reveal = ease(seconds / 0.65)
    caption = Image.new("RGBA", SIZE)
    caption_draw = ImageDraw.Draw(caption)
    y = round(SIZE[1] - TITLE_BOTTOM_MARGIN + 18 * (1 - reveal))
    caption_draw.text((TITLE_LEFT, y), title, font=TITLE_FONT, fill=TITLE_FILL, anchor="lb")
    caption.putalpha(caption.getchannel("A").point(lambda value: round(value * reveal)))
    return caption


def text_plate(draw: ImageDraw.ImageDraw, text: str, origin: tuple[int, int],
               anchor: str, face: ImageFont.ImageFont) -> tuple[int, int, int, int]:
    """Draw one line on a dark plate and return the plate box."""
    box = draw.textbbox(origin, text, font=face, anchor=anchor)
    plate = (box[0] - 18, box[1] - 10, box[2] + 18, box[3] + 10)
    draw.rounded_rectangle(plate, radius=12, fill=(6, 12, 8, 230))
    draw.text(origin, text, font=face, fill="#F4FFF6", anchor=anchor)
    return plate


def burn_top_caption(draw: ImageDraw.ImageDraw, title: str) -> tuple[int, int, int, int]:
    """Outcome caption at the top, present on the first frame."""
    return text_plate(draw, title, (TITLE_LEFT, 78), "lt", TITLE_FONT)


def burn_lower_url(draw: ImageDraw.ImageDraw) -> tuple[int, int, int, int]:
    """URL plate sitting fully above the player-control margin."""
    origin = (SIZE[0] - 82, SIZE[1] - TITLE_BOTTOM_MARGIN - 10)
    return text_plate(draw, SITE, origin, "rb", SITE_FONT)


def finish_frame(frame: Image.Image, scene: Scene, seconds: float) -> Image.Image:
    frame = frame.convert("RGB")
    if not scene.overlays:
        return frame
    if scene.message or scene.loop_open:
        # Bring forward only letters already revealed by the app. Ambient rain keeps
        # moving behind the invitation; no replacement or overlaid CTA text is used.
        # The opening writes itself on the same curve as the closing reveal.
        focus = ease((seconds - 0.5) / 1.6)
        frame = grade_message(frame, MESSAGE_MASK, frame.getchannel("G"), focus)
    elif scene.focus_text:
        # Grade only the app's existing message cells; tokens keep ticking underneath.
        # Showcase captions are already the point of frame 0, so their letters are too.
        red, green, blue = frame.split()
        ink = ImageChops.lighter(ImageChops.lighter(red, green), blue)
        mask = scene_focus_mask(scene)
        if scene.caption_top:
            amount = 1
        elif scene.credit_line:
            amount = ease((seconds - 0.5) / 1.6)
        else:
            amount = ease(seconds / 0.65)
        # Quote lines use the invitation's lift. A harder grade pulls them out of the rain.
        if scene.credit_line:
            frame = grade_message(frame, mask, ink, amount)
        else:
            frame = grade_message(frame, mask, ink, amount, dim=0.6, boost=2)
    frame = Image.alpha_composite(frame.convert("RGBA"), SHADE)
    chrome = Image.new("RGBA", SIZE)
    draw = ImageDraw.Draw(chrome)
    reveal = ease(seconds / 0.65)
    if scene.caption_top:
        burn_top_caption(draw, scene.title)
        burn_lower_url(draw)
    elif scene.message or scene.loop_open:
        ending = Image.new("RGBA", SIZE)
        ending_draw = ImageDraw.Draw(ending)
        ending_draw.text(ENDING_TITLE_POSITION, scene.title,
                         font=ENDING_TITLE_FONT, fill="#EEF5EF", anchor="mm")
        ending_draw.text(ENDING_SITE_POSITION, SITE, font=ENDING_SITE_FONT, fill="#F5FFF7", anchor="mm")
        strength = 1 if scene.loop_open else reveal
        ending.putalpha(ending.getchannel("A").point(lambda value: round(value * strength)))
        chrome = Image.alpha_composite(chrome, ending)
    else:
        draw.text(CORNER_SITE_POSITION, SITE, font=SITE_FONT, fill="#CED6D2", anchor="ra")
        if scene.platform_labels:
            burn_platform_labels(draw)
        if scene.show_title:
            chrome = Image.alpha_composite(chrome, scene_title_layer(scene.title, seconds))
    return Image.alpha_composite(frame, chrome).convert("RGB")


def scene_documents(scene: Scene) -> dict:
    doc = {
        "messages": [CTA] if scene.message else [], "enabled": scene.message,
        # Include preroll in the entrance, then hold the resolved invitation through the clip.
        "frequencyMs": 500, "persistenceMs": round(scene.seconds * 1000),
        "appearMs": round((scene.warmup + 5) * 1000),
        "disappearMs": 0, "flickerOut": True, "brightnessFade": False,
        "messageLayout": "row", "verticalPosition": 0.5, "verticalJitter": 0,
        "horizontalPosition": 0.5, "horizontalJitter": 0,
    }
    return {"mx-intro": {"enabled": False}, "mx-messages": doc,
            "mx-images": {"enabled": False, "images": []},
            "mx-countdown": {"targetMs": None, "moments": []},
            **(scene.documents or {})}


def open_scene(browser, dist: Path, scene: Scene):
    context = browser.new_context(viewport={"width": SIZE[0], "height": SIZE[1]},
                                  device_scale_factor=1, color_scheme="dark",
                                  reduced_motion="no-preference")
    documents = scene_documents(scene)
    if scene.start_images_after_warmup:
        documents["mx-images"] = {**documents["mx-images"], "enabled": False}
    context.add_init_script(CLOCK_SCRIPT.replace("STORAGE_DOCUMENTS", json.dumps(documents))
                           .replace("CLOSING_INVITATION", json.dumps(bool(scene.message or scene.loop_open)))
                           .replace("CAPTURE_EPOCH", str(CAPTURE_EPOCH_MS))
                           .replace("MESSAGE_LAYOUT", json.dumps(MESSAGE_LAYOUT))
                           .replace("INVITATION_GAPS", json.dumps(scene_invitation_gaps(scene)))
                           .replace("CREDIT_STAMP", json.dumps(credit_stamp(scene)))
                           .replace("FRAME_MILLISECONDS", str(1000 / FPS)))
    page = context.new_page()
    problems = []
    page.on("pageerror", lambda error: problems.append(str(error)))
    page.on("console", lambda message: problems.append(message.text) if message.type == "error" else None)
    query = urlencode({**BASE_SETTINGS, **scene.settings})
    page.goto((dist / "matrixcode.html").resolve().as_uri() + "?" + query, wait_until="networkidle")
    page.wait_for_function("Boolean(document.querySelector('.mx-ui') && window.__videoAdvance)", polling=100)
    if not scene.play_intro:
        page.keyboard.press("Escape")
    elif page.locator(".mx-ui.is-visible").count():
        page.keyboard.press("H")
    # Keep the normal settings dismissal from leaving a fading panel in cold-start shots.
    page.locator(".mx-ui").evaluate("element => { element.style.transition = 'none'; element.style.opacity = '0'; }")
    page.evaluate("frames => window.__videoAdvance(frames)", round(scene.warmup * FPS))
    # Flush initial resize work before recording the stable full-resolution grid.
    page.screenshot()
    page.evaluate("window.__videoAdvance()")
    if page.locator(".mx-notice, .mx-ui.is-visible, .mx-modal.is-open").count():
        raise RuntimeError(f"{scene.name}: capture has fallback/settings UI")
    dimensions = page.locator("#app > canvas").evaluate("canvas => [canvas.width, canvas.height]")
    if tuple(dimensions) != SIZE:
        raise RuntimeError(f"{scene.name}: unexpected canvas dimensions {dimensions}")
    overlap = page.get_by_role("button", name="Allow overlap", include_hidden=True).get_attribute("aria-pressed")
    if overlap != {**BASE_SETTINGS, **scene.settings}["overlap"]:
        raise RuntimeError(f"{scene.name}: incorrect overlap setting {overlap}")
    if scene.start_images_after_warmup:
        # Start the real image schedule over fully populated rain using its normal shortcut.
        page.keyboard.press("Shift+X")
        page.locator(".mx-toast").evaluate_all("toasts => toasts.forEach(toast => toast.remove())")
        if not page.evaluate("""() => {
            const doc = JSON.parse(localStorage.getItem('mx-images') || '{}');
            return doc.enabled && doc.images?.length > 0;
        }"""):
            raise RuntimeError(f"{scene.name}: image schedule did not start")
    return context, page, problems


def apply_scene_actions(page, scene: Scene, frame_number: int):
    for seconds, key in scene.actions:
        if frame_number == round(seconds * FPS):
            page.keyboard.press(key)
            page.locator(".mx-toast").evaluate_all("toasts => toasts.forEach(toast => toast.remove())")


def capture(browser, dist: Path, scene: Scene, index: int, directory: Path, preview_only: bool):
    versions = scene_versions(scene)
    sessions = [open_scene(browser, dist, version) for version in versions]
    clip = directory / f"{index:02d}-{scene.name}.mp4"
    encoder = None
    try:
        if not preview_only:
            encoder = subprocess.Popen([
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "rawvideo",
                "-pixel_format", "rgb24", "-video_size", f"{SIZE[0]}x{SIZE[1]}",
                "-framerate", str(FPS), "-i", "pipe:0", "-an", "-c:v", "libx264",
                "-preset", "ultrafast", "-crf", "0", "-pix_fmt", "yuv420p", str(clip),
            ], stdin=subprocess.PIPE, stdout=sys.stdout, stderr=sys.stderr)
        count = round(scene.seconds * FPS)
        switch_frame = math.ceil(count / len(versions))
        preview_frames = (
            {count - 1} if scene.message else
            {min(count - 1, index * switch_frame + round(scene.preview_seconds * FPS))
             for index in range(len(versions))}
        )
        for frame_number in range(count):
            # Both comparison views share the same clock and are already full of rain
            # when the full-screen switch happens; the extra lanes never start empty.
            for version, (_, page, _) in zip(versions, sessions):
                apply_scene_actions(page, version, frame_number)
                # The opening writes itself for the whole shot. Only the shared
                # invitation settles to plain letters, and only in its last second.
                plain = plain_message(version, frame_number, count)
                page.evaluate("""plainMessage => {
                    window.__videoPlainMessage = plainMessage;
                    window.__videoAdvance();
                }""", plain)
            if preview_only and frame_number not in preview_frames:
                continue
            version_index = min(frame_number // switch_frame, len(versions) - 1)
            version = versions[version_index]
            page = sessions[version_index][1]
            image = Image.open(io.BytesIO(page.screenshot(type="png")))
            output = finish_frame(image, version, (frame_number - version_index * switch_frame) / FPS)
            if encoder:
                encoder.stdin.write(output.tobytes())
            if frame_number in preview_frames:
                output.save(preview_path(directory, index, version), quality=95, subsampling=0)
            if preview_only and frame_number == max(preview_frames):
                break
        for version, (_, _, problems) in zip(versions, sessions):
            if problems:
                raise RuntimeError(f"{version.name}: browser errors: {problems}")
    finally:
        for context, _, _ in sessions:
            context.close()
        if encoder:
            encoder.stdin.close()
            if encoder.wait() != 0:
                raise RuntimeError(f"{scene.name}: FFmpeg capture failed")
    print(f"Captured {scene.title}", flush=True)
    return clip


def contact_sheet(directory: Path, output: Path, film: Film):
    previews = [preview_path(directory, index, version)
                for index, scene in enumerate(film.scenes) for version in scene_versions(scene)]
    columns = min(3, len(previews))
    sheet = Image.new("RGB", (columns * 480, math.ceil(len(previews) / columns) * 270), "black")
    for index, preview in enumerate(previews):
        still = Image.open(preview)
        sheet.paste(still.resize((480, 270), Image.Resampling.LANCZOS),
                    ((index % columns) * 480, (index // columns) * 270))
    sheet.save(output, quality=93, subsampling=0)


def assemble(clips: list[Path], audio: Path | None, output: Path, film: Film):
    inputs = [argument for clip in clips for argument in ["-i", str(clip)]]
    filters = [f"[{index}:v]settb=AVTB,setpts=PTS-STARTPTS,format=yuv420p[v{index}]"
               for index in range(len(clips))]
    last = "v0"
    offset = film.scenes[0].seconds - TRANSITION
    for index in range(1, len(clips)):
        merged = f"blend{index}"
        filters.append(f"[{last}][v{index}]xfade=transition=fade:duration={TRANSITION}:offset={offset}[{merged}]")
        last = merged
        offset += film.scenes[index].seconds - TRANSITION
    if film.loop_overlap:
        filters, last = [loop_filter(film)], "loop"
    audio_inputs = ["-i", str(audio)] if audio is not None else []
    audio_options = (["-map", f"{len(clips)}:a", "-af", "loudnorm=I=-14:TP=-1.5:LRA=7",
                      "-ar", "48000", "-c:a", "aac", "-b:a", "192k"]
                     if audio is not None else ["-an"])
    comment = "Actual Matrix Code WebGL capture"
    if audio is not None:
        comment += "; original generated soundtrack"
    subprocess.run([
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-filter_complex_threads", "1",
        *inputs, *audio_inputs, "-filter_complex", ";".join(filters),
        "-map", f"[{last}]", *audio_options, "-c:v", "libx264",
        "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-r", str(FPS),
        "-movflags", "+faststart", "-t", str(film.duration),
        "-metadata", f"title={film.title}",
        "-metadata", f"comment={comment}",
        str(output),
    ], check=True, stdout=sys.stdout, stderr=sys.stderr)


def short_render(outputs: list[tuple[Film, Path]]) -> bool:
    return bool(outputs) and all(scene.platform_labels for film, _ in outputs for scene in film.scenes)


@contextlib.contextmanager
def render_slot(enabled: bool):
    """Limit concurrent short captures so sixty Chromium launches do not stack up."""
    if not enabled:
        yield
        return
    slot_dir = TEMP_ROOT / "matrixcode-short-slots"
    slot_dir.mkdir(parents=True, exist_ok=True)
    handles = [os.open(slot_dir / f"slot-{index}.lock", os.O_CREAT | os.O_RDWR)
               for index in range(SHORT_RENDER_SLOTS)]
    chosen = None
    try:
        while chosen is None:
            for handle in handles:
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                chosen = handle
                break
            if chosen is None:
                time.sleep(0.4)
        yield
    finally:
        if chosen is not None:
            fcntl.flock(chosen, fcntl.LOCK_UN)
        for handle in handles:
            os.close(handle)


def resolve_outputs(video: str, output_directory: Path, output: Path | None) -> list[tuple[Film, Path]]:
    keys = FILM_GROUPS.get(video, (video,))
    if len(keys) > 1 and output is not None:
        raise ValueError("--out selects one MP4; use --output-dir with a film group")
    try:
        films = tuple(CATALOG[key] for key in keys)
    except KeyError:
        raise ValueError(f"unknown film {video}") from None
    return [(film, output if output is not None else output_directory / film.relative_output)
            for film in films]


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dist", type=Path, default=ROOT / "dist")
    parser.add_argument("--video", choices=[*CATALOG, *FILM_GROUPS], default="first",
                        help="a film, short slug, shorts, showcase, quotes, classic-loop, or all eight long tours")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "output/marketing",
                        help="output root; each additional film keeps its previews in its own subfolder")
    parser.add_argument("--out", type=Path, help="override the MP4 path for a single film")
    parser.add_argument("--temp-dir", type=Path, default=TEMP_ROOT,
                        help="scratch directory for lossless clips and audio")
    parser.add_argument("--preview-only", action="store_true", help="render scene contact sheet only")
    args = parser.parse_args(argv)
    try:
        resolve_outputs(args.video, args.output_dir, args.out)
    except ValueError as error:
        parser.error(str(error))
    if args.out is not None and args.out.suffix.lower() != ".mp4":
        parser.error("--out must end in .mp4")
    return args


def verify_soundtrack(audio: Path, film: Film):
    with wave.open(str(audio), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getnframes()) != (
                2, 2, 48000, round(film.duration * 48000)):
            raise RuntimeError("Soundtrack format or duration does not match the film")
        pcm = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2")
    peak = int(np.max(np.abs(pcm.astype(np.int32))))
    if not 0 < peak <= round(0.87 * 32767):
        raise RuntimeError(f"Soundtrack exceeds the PCM peak ceiling: {peak}")
    print(f"Soundtrack verified: stereo 48 kHz, {film.duration:g}s, peak {peak / 32767:.4f}")


def verify_video(output: Path, film: Film, final_frame: Path):
    probe = subprocess.run([
        "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(output),
    ], capture_output=True, text=True)
    if probe.returncode:
        print(probe.stderr, file=sys.stderr)
        probe.check_returncode()
    streams = json.loads(probe.stdout)["streams"]
    video = next(stream for stream in streams if stream["codec_type"] == "video")
    audio_streams = [stream for stream in streams if stream["codec_type"] == "audio"]
    if (video["codec_name"], video["width"], video["height"], video["r_frame_rate"], video["pix_fmt"]) != (
            "h264", *SIZE, f"{FPS}/1", "yuv420p"):
        raise RuntimeError(f"Unexpected video stream: {video}")
    if film.score is None:
        if audio_streams:
            raise RuntimeError("Silent film contains an audio stream")
    elif len(audio_streams) != 1 or (
            audio_streams[0]["codec_name"], int(audio_streams[0]["sample_rate"]),
            audio_streams[0]["channels"]) != ("aac", 48000, 2):
        raise RuntimeError(f"Unexpected audio streams: {audio_streams}")
    if abs(float(video["duration"]) - film.duration) > 1 / FPS:
        raise RuntimeError(f"Unexpected video duration: {video['duration']}")
    if int(video["nb_frames"]) != round(film.duration * FPS):
        raise RuntimeError(f"Unexpected frame count: {video['nb_frames']}")
    subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-i", str(output), "-f", "null", "-"],
                   check=True, stdout=sys.stdout, stderr=sys.stderr)
    subprocess.run([
        "ffmpeg", "-v", "error", "-y", "-sseof", str(-1.01 / FPS), "-i", str(output),
        "-frames:v", "1", "-q:v", "2", str(final_frame),
    ], check=True, stdout=sys.stdout, stderr=sys.stderr)
    if not final_frame.is_file():
        raise RuntimeError("Encoded final frame was not extracted")
    print(f"Video verified: {SIZE[0]}x{SIZE[1]}, {FPS} FPS, {film.duration:g}s, full decode")


def render_film(browser, args, film: Film, output: Path):
    with tempfile.TemporaryDirectory(prefix=f"matrixcode-{film.key}-", dir=args.temp_dir) as temporary:
        directory = Path(temporary)
        clips = [capture(browser, args.dist, scene, index, directory, args.preview_only)
                 for index, scene in enumerate(film.scenes)]
        storyboard = directory / "matrixcode-storyboard.jpg"
        poster = directory / "matrixcode-poster.jpg"
        contact_sheet(directory, storyboard, film)
        shutil.copyfile(preview_path(directory, len(film.scenes) - 1, film.scenes[-1]), poster)
        artifacts = [storyboard, poster]
        if not args.preview_only:
            audio = directory / "soundtrack.wav" if film.score is not None else None
            video = directory / output.name
            final_frame = directory / "matrixcode-final-frame.jpg"
            if audio is not None:
                if film.score == "industrial":
                    write_soundtrack(audio, film.duration, film.transitions)
                else:
                    write_soundtrack(audio, film.duration, film.transitions, score=film.score)
                verify_soundtrack(audio, film)
            assemble(clips, audio, video, film)
            verify_video(video, film, final_frame)
            artifacts += [video, final_frame]
            if film.loop_overlap:
                report = directory / "matrixcode-loop-check.json"
                verify_loop(video, film, report, storyboard)
                artifacts.append(report)
        output.parent.mkdir(parents=True, exist_ok=True)
        # Publish only after the complete film has encoded and decoded successfully.
        staged_artifacts = []
        try:
            for artifact in artifacts:
                destination = output.parent / artifact.name
                staged = destination.with_name(f".{destination.name}.{uuid4().hex}.tmp")
                staged_artifacts.append((staged, destination))
                shutil.copyfile(artifact, staged)
            for staged, destination in staged_artifacts:
                staged.replace(destination)
        finally:
            for staged, _ in staged_artifacts:
                staged.unlink(missing_ok=True)
        print(f"Wrote {'previews for' if args.preview_only else 'film'} {output}", flush=True)


def main():
    args = parse_args()
    outputs = resolve_outputs(args.video, args.output_dir, args.out)
    log_directory = (args.out.parent if args.out else args.output_dir) / "logs"
    log = log_directory / f"capture-{args.video}-{uuid4().hex[:12]}.log"
    terminal = sys.stdout
    try:
        log_directory.mkdir(parents=True, exist_ok=True)
        details = log.open("w")
    except OSError as error:
        print(f"fail [capture-log]: {error}", file=sys.stderr)
        return 1
    print(f"Log: {log}", flush=True)
    try:
        with details, contextlib.redirect_stdout(details), contextlib.redirect_stderr(details):
            try:
                args.temp_dir.mkdir(parents=True, exist_ok=True)
                # Playwright and Chromium inherit the same scratch location as the clips.
                for variable in ("TMPDIR", "TMP", "TEMP"):
                    os.environ[variable] = str(args.temp_dir.resolve())
                if not (args.dist / "matrixcode.html").is_file():
                    raise RuntimeError("production build missing; run npm run build first")
                for command in ("ffmpeg", "ffprobe"):
                    if not shutil.which(command):
                        raise RuntimeError(f"{command} is required")
                with render_slot(short_render(outputs)):
                    with sync_playwright() as playwright:
                        browser_args = (["--use-angle=metal", "--enable-gpu", "--ignore-gpu-blocklist"]
                                        if sys.platform == "darwin" else [])
                        browser = playwright.chromium.launch(args=browser_args)
                        try:
                            for film, output in outputs:
                                if terminal.isatty():
                                    print(f"Rendering {film.key}: {film.title}", file=terminal, flush=True)
                                render_film(browser, args, film, output)
                        finally:
                            browser.close()
            except Exception:
                traceback.print_exc()
                raise
    except Exception as error:
        message = str(error).splitlines()[0] if str(error) else repr(error)
        print(f"fail [capture]: {type(error).__name__}: {message}", file=sys.stderr)
        print(f"Detail: tail -n 20 '{log}'", file=sys.stderr)
        return 1
    print(f"pass: {len(outputs)} {'preview sets' if args.preview_only else 'films'}, skipped=0, warnings=0")
    for film, output in outputs:
        print(f"{film.key}: {output.parent if args.preview_only else output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
