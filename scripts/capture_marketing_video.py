#!/usr/bin/env python3
"""Capture a 30-second marketing film from the actual, unmodified WebGL app.

Requires a production build, Python Playwright/Pillow/NumPy, Chromium, and FFmpeg.
Run with --preview-only to review the six scenes before rendering the MP4.
"""

from __future__ import annotations

import argparse
import io
import json
import math
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlencode

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFont
from playwright.sync_api import sync_playwright

from marketing_audio import write_soundtrack

ROOT = Path(__file__).resolve().parent.parent
SIZE = (1920, 1080)
FPS = 30
TRANSITION = 0.5
CTA = "Try it now!"
SITE = "julimbob.com/matrixcode"
BASE_SETTINGS = {
    "ramp": 0, "adaptive": 0, "quality": "high", "vignette": 0.15,
    "overlap": "false", "lead": 1.6,
}


@dataclass(frozen=True)
class Scene:
    name: str
    title: str
    seconds: float
    settings: dict
    warmup: float = 18
    message: bool = False


SCENES = [
    Scene("classic", "Classic green", 5.5,
          {"preset": "classic", "density": 5, "size": 1.5, "glow": 1.2, "speed": 1, "trail": 0.25}),
    Scene("blue", "Electric blue", 4.5,
          {"preset": "blue", "glyphs": "binary", "density": 7, "size": 1.8, "glow": 1.35, "speed": 1.4, "trail": 0.16}),
    Scene("amber", "Amber terminal", 4.5,
          {"preset": "amber", "glyphs": "digits", "font": "terminal", "density": 6, "size": 2, "glow": 0.85, "speed": 0.75, "trail": 0.18, "scanlines": "true"}),
    Scene("purple", "Neon purple", 4.5,
          {"preset": "purple", "glyphs": "katakana", "density": 8, "size": 1.4, "glow": 1.9, "speed": 1.05, "trail": 0.32}),
    Scene("white", "Monochrome", 4.5,
          {"preset": "white", "glyphs": "symbols", "font": "mono", "density": 5, "size": 1.9, "glow": 0.65, "speed": 1.1, "trail": 0.14, "scanlines": "true"}),
    Scene("invitation", "Your Matrix Code. Your style.", 9,
          {"preset": "classic", "density": 12, "size": 4.4, "glow": 1.3, "speed": 1.5, "trail": 0.24},
          warmup=3, message=True),
]
DURATION = sum(scene.seconds for scene in SCENES) - TRANSITION * (len(SCENES) - 1)
TRANSITIONS = [sum(scene.seconds - TRANSITION for scene in SCENES[:index])
               for index in range(1, len(SCENES))]

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
  const epoch = OriginalDate.parse('2026-10-14T12:00:00Z');
  window.Date = class extends OriginalDate {
    constructor(...args) { super(...(args.length ? args : [epoch + now])); }
    static now() { return epoch + now; }
  };
  localStorage.clear();
  sessionStorage.clear();
  localStorage.setItem('mx-intro', JSON.stringify({enabled: false}));
  localStorage.setItem('mx-messages', JSON.stringify(MESSAGE_DOCUMENT));
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
SMALL_FONT = font(19, mono=True)


def message_mask() -> Image.Image:
    """Select existing message cells for a finishing grade, without drawing text."""
    glyph_scale = SCENES[-1].settings["size"]
    cols = max(8, math.floor(SIZE[0] / (18 * glyph_scale) + 0.5))
    rows = max(8, math.floor(SIZE[1] / (18 * glyph_scale) + 0.5))
    start_col = math.floor(cols * 0.5 - len(CTA) / 2 + 0.5)
    row = math.floor(rows * 0.5 - 0.5 + 0.5)
    cell_w, cell_h = SIZE[0] / cols, SIZE[1] / rows
    mask = Image.new("L", SIZE)
    draw = ImageDraw.Draw(mask)
    for offset, char in enumerate(CTA):
        if char != " ":
            draw.rectangle((round((start_col + offset) * cell_w), round(row * cell_h),
                            round((start_col + offset + 1) * cell_w) - 1,
                            round((row + 1) * cell_h) - 1), fill=255)
    return mask


MESSAGE_MASK = message_mask()


def finish_frame(frame: Image.Image, scene: Scene, seconds: float) -> Image.Image:
    frame = frame.convert("RGB")
    if scene.message:
        # Bring forward only letters already revealed by the app. Ambient rain keeps
        # moving behind the invitation; no replacement or overlaid CTA text is used.
        focus = ease((seconds - 0.5) / 1.6)
        ambient = ImageEnhance.Brightness(frame).enhance(1 - 0.66 * focus)
        letters = ImageEnhance.Brightness(frame).enhance(1 + 1.65 * focus)
        ink = frame.getchannel("G").point(lambda value: min(255, max(0, (value - 12) * 9)))
        frame = Image.composite(letters, ambient, ImageChops.multiply(MESSAGE_MASK, ink))
    frame = Image.alpha_composite(frame.convert("RGBA"), SHADE)
    chrome = Image.new("RGBA", SIZE)
    draw = ImageDraw.Draw(chrome)
    if not scene.message:
        draw.text((SIZE[0] - 82, 63), SITE, font=SMALL_FONT, fill="#CED6D2", anchor="ra")
    reveal = ease(seconds / 0.65)
    if not scene.message:
        caption = Image.new("RGBA", SIZE)
        caption_draw = ImageDraw.Draw(caption)
        y = round(788 + 18 * (1 - reveal))
        caption_draw.text((78, y + 45), scene.title, font=TITLE_FONT, fill="#F5F7F6")
        caption.putalpha(caption.getchannel("A").point(lambda value: round(value * reveal)))
        chrome = Image.alpha_composite(chrome, caption)
    else:
        ending = Image.new("RGBA", SIZE)
        ending_draw = ImageDraw.Draw(ending)
        ending_draw.text((SIZE[0] / 2, 391), scene.title,
                         font=font(25, bold=True), fill="#EEF5EF", anchor="mm")
        ending_draw.text((SIZE[0] / 2, 729), SITE, font=font(33), fill="#F5FFF7", anchor="mm")
        ending.putalpha(ending.getchannel("A").point(lambda value: round(value * reveal)))
        chrome = Image.alpha_composite(chrome, ending)
    return Image.alpha_composite(frame, chrome).convert("RGB")


def open_scene(browser, dist: Path, scene: Scene):
    context = browser.new_context(viewport={"width": SIZE[0], "height": SIZE[1]},
                                  device_scale_factor=1, color_scheme="dark",
                                  reduced_motion="no-preference")
    doc = {
        "messages": [CTA] if scene.message else [], "enabled": scene.message,
        "frequencyMs": 500, "persistenceMs": 60000, "appearMs": 1800,
        "disappearMs": 0, "flickerOut": True, "brightnessFade": False,
        "messageLayout": "row", "verticalPosition": 0.5, "verticalJitter": 0,
        "horizontalPosition": 0.5, "horizontalJitter": 0,
    }
    context.add_init_script(CLOCK_SCRIPT.replace("MESSAGE_DOCUMENT", json.dumps(doc))
                           .replace("FRAME_MILLISECONDS", str(1000 / FPS)))
    page = context.new_page()
    problems = []
    page.on("pageerror", lambda error: problems.append(str(error)))
    page.on("console", lambda message: problems.append(message.text) if message.type == "error" else None)
    query = urlencode({**BASE_SETTINGS, **scene.settings})
    page.goto((dist / "matrixcode.html").resolve().as_uri() + "?" + query, wait_until="networkidle")
    page.wait_for_function("Boolean(document.querySelector('.mx-ui') && window.__videoAdvance)", polling=100)
    page.keyboard.press("Escape")
    page.evaluate("frames => window.__videoAdvance(frames)", round(scene.warmup * FPS))
    # Flush initial resize work before recording the stable full-resolution grid.
    page.screenshot()
    page.evaluate("window.__videoAdvance()")
    if page.locator(".mx-notice, .mx-ui.is-visible, .mx-modal.is-open").count():
        raise RuntimeError(f"{scene.name}: capture has fallback/settings UI")
    dimensions = page.locator("#app > canvas").evaluate("canvas => [canvas.width, canvas.height]")
    if tuple(dimensions) != SIZE:
        raise RuntimeError(f"{scene.name}: unexpected canvas dimensions {dimensions}")
    return context, page, problems


def capture(browser, dist: Path, scene: Scene, index: int, directory: Path, preview_only: bool):
    context, page, problems = open_scene(browser, dist, scene)
    clip = directory / f"{index:02d}-{scene.name}.mp4"
    encoder = None
    try:
        if not preview_only:
            encoder = subprocess.Popen([
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "rawvideo",
                "-pixel_format", "rgb24", "-video_size", f"{SIZE[0]}x{SIZE[1]}",
                "-framerate", str(FPS), "-i", "pipe:0", "-an", "-c:v", "libx264",
                "-preset", "ultrafast", "-crf", "0", "-pix_fmt", "yuv420p", str(clip),
            ], stdin=subprocess.PIPE)
        count = round(scene.seconds * FPS)
        preview_frame = round((5 if scene.message else 1.5) * FPS)
        for frame_number in range(count):
            page.evaluate("window.__videoAdvance()")
            if preview_only and frame_number != preview_frame:
                continue
            image = Image.open(io.BytesIO(page.screenshot(type="png")))
            output = finish_frame(image, scene, frame_number / FPS)
            if encoder:
                encoder.stdin.write(output.tobytes())
            if frame_number == preview_frame:
                output.save(directory / f"{index:02d}-{scene.name}.jpg", quality=95, subsampling=0)
            if preview_only:
                break
        if problems:
            raise RuntimeError(f"{scene.name}: browser errors: {problems}")
    finally:
        context.close()
        if encoder:
            encoder.stdin.close()
            if encoder.wait() != 0:
                raise RuntimeError(f"{scene.name}: FFmpeg capture failed")
    print(f"Captured {scene.title}", flush=True)
    return clip


def contact_sheet(directory: Path, output: Path):
    sheet = Image.new("RGB", (1440, 810), "black")
    for index, scene in enumerate(SCENES):
        still = Image.open(directory / f"{index:02d}-{scene.name}.jpg")
        sheet.paste(still.resize((480, 270), Image.Resampling.LANCZOS),
                    ((index % 3) * 480, (index // 3) * 270))
    sheet.crop((0, 0, 1440, 540)).save(output, quality=93, subsampling=0)


def assemble(clips: list[Path], audio: Path, output: Path):
    inputs = [argument for clip in clips for argument in ["-i", str(clip)]]
    filters = [f"[{index}:v]settb=AVTB,setpts=PTS-STARTPTS,format=yuv420p[v{index}]"
               for index in range(len(clips))]
    last = "v0"
    offset = SCENES[0].seconds - TRANSITION
    for index in range(1, len(clips)):
        merged = f"blend{index}"
        filters.append(f"[{last}][v{index}]xfade=transition=fade:duration={TRANSITION}:offset={offset}[{merged}]")
        last = merged
        offset += SCENES[index].seconds - TRANSITION
    subprocess.run([
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-filter_complex_threads", "1",
        *inputs, "-i", str(audio), "-filter_complex", ";".join(filters),
        "-map", f"[{last}]", "-map", f"{len(clips)}:a", "-c:v", "libx264",
        "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-r", str(FPS),
        "-af", "loudnorm=I=-14:TP=-1.5:LRA=7", "-ar", "48000",
        "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-t", str(DURATION),
        "-metadata", "title=Matrix Code — Find your style",
        "-metadata", "comment=Actual Matrix Code WebGL capture; original generated soundtrack",
        str(output),
    ], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dist", type=Path, default=ROOT / "dist")
    parser.add_argument("--out", type=Path, default=ROOT / "output/marketing/matrixcode-styles.mp4")
    parser.add_argument("--preview-only", action="store_true", help="render scene contact sheet only")
    args = parser.parse_args()
    if not (args.dist / "matrixcode.html").is_file():
        parser.error("production build missing; run npm run build first")
    if not shutil.which("ffmpeg"):
        parser.error("ffmpeg is required")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="matrixcode-film-") as temporary:
        directory = Path(temporary)
        with sync_playwright() as playwright:
            browser_args = ["--use-angle=metal", "--enable-gpu", "--ignore-gpu-blocklist"] if sys.platform == "darwin" else []
            browser = playwright.chromium.launch(args=browser_args)
            try:
                clips = [capture(browser, args.dist, scene, index, directory, args.preview_only)
                         for index, scene in enumerate(SCENES)]
            finally:
                browser.close()
        contact_sheet(directory, args.out.with_name("matrixcode-storyboard.jpg"))
        shutil.copyfile(directory / "05-invitation.jpg", args.out.with_name("matrixcode-poster.jpg"))
        if not args.preview_only:
            audio = directory / "soundtrack.wav"
            write_soundtrack(audio, DURATION, TRANSITIONS)
            assemble(clips, audio, args.out)
            print(f"Wrote {args.out}", flush=True)
        print(f"Scene previews: {args.out.parent}", flush=True)


if __name__ == "__main__":
    main()
