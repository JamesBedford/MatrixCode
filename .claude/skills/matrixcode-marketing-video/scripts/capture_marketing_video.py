#!/usr/bin/env python3
"""Capture Matrix Code marketing showcases from the real WebGL app.

Requires a production build, Python Playwright/Pillow/NumPy, Chromium, and FFmpeg.
Run with --preview-only to review every style before rendering the MP4.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import io
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
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

def find_project_root() -> Path:
    for directory in Path(__file__).resolve().parents:
        if (directory / "package.json").is_file() and (directory / "src/main.ts").is_file():
            return directory
    raise RuntimeError("The video skill must live inside a MatrixCode checkout")


ROOT = find_project_root()
TEMP_ROOT = Path("/Volumes/DATA/Temp") if Path("/Volumes/DATA").is_dir() else Path(tempfile.gettempdir())
SITE = "julimbob.com/matrixcode"
TITLE_BOTTOM_MARGIN = 200
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
FILM_GROUPS = {
    "both": ("first", "second"), "new": ("third", "fourth", "fifth"),
    "styles": ("sixth", "seventh", "eighth"), "all": tuple(FILMS),
}
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
        args[8] = pixels;
      }
      return Reflect.apply(upload, this, args);
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
    return focus_mask(scene.settings["size"], scene.focus_text,
                      document.get("messageLayout", "row"),
                      document.get("messageDirection", "topToBottom"),
                      document.get("verticalPosition", 0.5), document.get("horizontalPosition", 0.5))


def grade_message(frame: Image.Image, mask: Image.Image, ink: Image.Image, focus: float,
                  dim: float = 0.66, boost: float = 1.65) -> Image.Image:
    ambient = ImageEnhance.Brightness(frame).enhance(1 - dim * focus)
    letters = ImageEnhance.Brightness(frame).enhance(1 + boost * focus)
    ink = ink.point(lambda value: min(255, max(0, (value - 12) * 9)))
    return Image.composite(letters, ambient, ImageChops.multiply(mask, ink))


def finish_frame(frame: Image.Image, scene: Scene, seconds: float) -> Image.Image:
    frame = frame.convert("RGB")
    if scene.message:
        # Bring forward only letters already revealed by the app. Ambient rain keeps
        # moving behind the invitation; no replacement or overlaid CTA text is used.
        focus = ease((seconds - 0.5) / 1.6)
        frame = grade_message(frame, MESSAGE_MASK, frame.getchannel("G"), focus)
    elif scene.focus_text:
        # Grade only the app's existing message cells; tokens keep ticking underneath.
        red, green, blue = frame.split()
        ink = ImageChops.lighter(ImageChops.lighter(red, green), blue)
        mask = scene_focus_mask(scene)
        frame = grade_message(frame, mask, ink, ease(seconds / 0.65), dim=0.6, boost=2)
    frame = Image.alpha_composite(frame.convert("RGBA"), SHADE)
    chrome = Image.new("RGBA", SIZE)
    draw = ImageDraw.Draw(chrome)
    if not scene.message:
        draw.text(CORNER_SITE_POSITION, SITE, font=SITE_FONT, fill="#CED6D2", anchor="ra")
    reveal = ease(seconds / 0.65)
    if not scene.message:
        caption = Image.new("RGBA", SIZE)
        caption_draw = ImageDraw.Draw(caption)
        y = round(SIZE[1] - TITLE_BOTTOM_MARGIN + 18 * (1 - reveal))
        caption_draw.text((78, y), scene.title, font=TITLE_FONT, fill="#F5F7F6", anchor="lb")
        caption.putalpha(caption.getchannel("A").point(lambda value: round(value * reveal)))
        chrome = Image.alpha_composite(chrome, caption)
    else:
        ending = Image.new("RGBA", SIZE)
        ending_draw = ImageDraw.Draw(ending)
        ending_draw.text(ENDING_TITLE_POSITION, scene.title,
                         font=ENDING_TITLE_FONT, fill="#EEF5EF", anchor="mm")
        ending_draw.text(ENDING_SITE_POSITION, SITE, font=ENDING_SITE_FONT, fill="#F5FFF7", anchor="mm")
        ending.putalpha(ending.getchannel("A").point(lambda value: round(value * reveal)))
        chrome = Image.alpha_composite(chrome, ending)
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
                           .replace("CLOSING_INVITATION", json.dumps(scene.message))
                           .replace("CAPTURE_EPOCH", str(CAPTURE_EPOCH_MS))
                           .replace("MESSAGE_LAYOUT", json.dumps(MESSAGE_LAYOUT))
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
                page.evaluate("""plainMessage => {
                    window.__videoPlainMessage = plainMessage;
                    window.__videoAdvance();
                }""", scene.message and frame_number >= count - FPS)
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
    columns = 3
    sheet = Image.new("RGB", (columns * 480, math.ceil(len(previews) / columns) * 270), "black")
    for index, preview in enumerate(previews):
        still = Image.open(preview)
        sheet.paste(still.resize((480, 270), Image.Resampling.LANCZOS),
                    ((index % columns) * 480, (index // columns) * 270))
    sheet.save(output, quality=93, subsampling=0)


def assemble(clips: list[Path], audio: Path, output: Path, film: Film):
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
    subprocess.run([
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-filter_complex_threads", "1",
        *inputs, "-i", str(audio), "-filter_complex", ";".join(filters),
        "-map", f"[{last}]", "-map", f"{len(clips)}:a", "-c:v", "libx264",
        "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-r", str(FPS),
        "-af", "loudnorm=I=-14:TP=-1.5:LRA=7", "-ar", "48000",
        "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-t", str(film.duration),
        "-metadata", f"title={film.title}",
        "-metadata", "comment=Actual Matrix Code WebGL capture; original generated soundtrack",
        str(output),
    ], check=True, stdout=sys.stdout, stderr=sys.stderr)


def resolve_outputs(video: str, output_directory: Path, output: Path | None) -> list[tuple[Film, Path]]:
    keys = FILM_GROUPS.get(video, (video,))
    if len(keys) > 1 and output is not None:
        raise ValueError("--out selects one MP4; use --output-dir with a film group")
    films = tuple(FILMS[key] for key in keys)
    return [(film, output if output is not None else output_directory / film.relative_output)
            for film in films]


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dist", type=Path, default=ROOT / "dist")
    parser.add_argument("--video", choices=[*FILMS, *FILM_GROUPS], default="first",
                        help="select a film; both: first two; new: third–fifth; styles: sixth–eighth; all: every film")
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
    audio = next(stream for stream in streams if stream["codec_type"] == "audio")
    if (video["codec_name"], video["width"], video["height"], video["r_frame_rate"], video["pix_fmt"]) != (
            "h264", *SIZE, f"{FPS}/1", "yuv420p"):
        raise RuntimeError(f"Unexpected video stream: {video}")
    if (audio["codec_name"], int(audio["sample_rate"]), audio["channels"]) != ("aac", 48000, 2):
        raise RuntimeError(f"Unexpected audio stream: {audio}")
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
            audio = directory / "soundtrack.wav"
            video = directory / output.name
            final_frame = directory / "matrixcode-final-frame.jpg"
            write_soundtrack(audio, film.duration, film.transitions)
            verify_soundtrack(audio, film)
            assemble(clips, audio, video, film)
            verify_video(video, film, final_frame)
            artifacts += [video, final_frame]
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
