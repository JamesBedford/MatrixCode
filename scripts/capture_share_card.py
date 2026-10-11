#!/usr/bin/env python3
"""Capture the running web build as the link-preview card, public/share-card.jpg.

Serves dist/ on a throwaway loopback port and opens matrixcode.html in
headless Chromium at a 1200x630 CSS viewport and 2x device pixels, with fresh
storage so every setting is at its default. It skips the typed intro with
Escape, waits for the settings panel to auto-hide and the rain to fill the
screen, then samples a run of frames. The frame
whose lit glyphs cover the most of the screen is Lanczos-downscaled 2:1 and
saved as a progressive JPEG. Nothing is drawn, composited, or retouched.
See docs/share-card.md.

Requires `npm run build` first, plus Playwright for Python and Pillow:
    pip install playwright pillow && python3 -m playwright install chromium

Usage:
    python3 scripts/capture_share_card.py                     # write public/share-card.jpg
    python3 scripts/capture_share_card.py --candidates DIR    # also keep every sampled frame
"""

from __future__ import annotations

import argparse
import functools
import http.server
import io
import sys
import threading
from pathlib import Path

from PIL import Image, ImageStat
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
CARD_SIZE = (1200, 630)
# The app caps devicePixelRatio at 2, so 2x is the sharpest real render.
DEVICE_SCALE = 2
# The intro is skipped; this covers the 8 s density ramp and lets every column start falling.
SETTLE_MS = 25_000
FRAME_COUNT = 30
FRAME_INTERVAL_MS = 1_200
# Frames are scored by the share of grid blocks holding at least one lit glyph pixel.
COVERAGE_GRID = (12, 7)
LIT_LUMA = 120
JPEG_OPTIONS = {"quality": 90, "progressive": True, "optimize": True, "subsampling": 0}
# Metal-backed ANGLE keeps WebGL2 on the GPU in headless Chromium on macOS.
CHROMIUM_ARGS = ["--use-angle=metal", "--enable-gpu", "--ignore-gpu-blocklist"] if sys.platform == "darwin" else []


def coverage(frame: Image.Image) -> float:
    luma = frame.convert("L")
    columns, rows = COVERAGE_GRID
    width, height = luma.size
    lit = 0
    for row in range(rows):
        for column in range(columns):
            box = (column * width // columns, row * height // rows, (column + 1) * width // columns, (row + 1) * height // rows)
            if luma.crop(box).getextrema()[1] > LIT_LUMA:
                lit += 1
    return lit / (columns * rows)


def score(frame: Image.Image) -> tuple[float, float]:
    """Coverage first, then mean brightness to break ties."""
    return coverage(frame), ImageStat.Stat(frame.convert("L")).mean[0]


def serve(directory: Path) -> http.server.ThreadingHTTPServer:
    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_args: object) -> None:
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(directory)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def capture_frames(url: str) -> list[Image.Image]:
    problems: list[str] = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(args=CHROMIUM_ARGS)
        page = browser.new_page(
            viewport={"width": CARD_SIZE[0], "height": CARD_SIZE[1]},
            device_scale_factor=DEVICE_SCALE,
            color_scheme="dark",
            reduced_motion="no-preference",
        )
        page.on("console", lambda message: problems.append(f"console.{message.type}: {message.text}") if message.type in ("error", "warning") else None)
        page.on("pageerror", lambda error: problems.append(f"pageerror: {error}"))
        page.goto(url, wait_until="load")
        page.wait_for_timeout(1_500)
        intro = page.locator(".mx-message")
        # Escape first dismisses the settings panel shown on load, then skips the intro.
        for _ in range(3):
            if not intro.is_visible():
                break
            page.keyboard.press("Escape")
            page.wait_for_timeout(300)
        if intro.is_visible():
            problems.append("Escape did not skip the intro")
        page.wait_for_timeout(SETTLE_MS)
        if page.locator(".mx-ui.is-visible").count():
            problems.append("the settings panel is showing")
        if page.locator(".mx-notice").count():
            problems.append("the Canvas2D compatibility fallback is showing instead of WebGL2")
        frames = []
        for _ in range(FRAME_COUNT):
            frames.append(Image.open(io.BytesIO(page.screenshot())).convert("RGB"))
            page.wait_for_timeout(FRAME_INTERVAL_MS)
        browser.close()
    if problems:
        raise SystemExit("Capture aborted:\n" + "\n".join(problems))
    return frames


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dist", type=Path, default=ROOT / "dist", help="built web app directory (default: dist)")
    parser.add_argument("--out", type=Path, default=ROOT / "public" / "share-card.jpg")
    parser.add_argument("--candidates", type=Path, help="also save every sampled frame here for manual review")
    args = parser.parse_args()
    if not (args.dist / "matrixcode.html").is_file():
        raise SystemExit(f"{args.dist / 'matrixcode.html'} is missing; run `npm run build` first.")

    server = serve(args.dist)
    try:
        # Adaptive resolution only scales the render target; turning it off keeps every frame at full 2x.
        frames = capture_frames(f"http://127.0.0.1:{server.server_address[1]}/matrixcode.html?adaptive=0")
    finally:
        server.shutdown()

    expected = (CARD_SIZE[0] * DEVICE_SCALE, CARD_SIZE[1] * DEVICE_SCALE)
    cards = []
    for index, frame in enumerate(frames):
        if frame.size != expected:
            raise SystemExit(f"frame {index} is {frame.size}, expected {expected}")
        cards.append(frame.resize(CARD_SIZE, Image.Resampling.LANCZOS))
    scores = [score(card) for card in cards]
    best = max(range(len(cards)), key=scores.__getitem__)

    if args.candidates:
        args.candidates.mkdir(parents=True, exist_ok=True)
        for index, card in enumerate(cards):
            card.save(args.candidates / f"frame-{index:02d}.jpg", **JPEG_OPTIONS)
            print(f"frame-{index:02d}.jpg  coverage {scores[index][0]:.2f}  mean {scores[index][1]:.2f}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    cards[best].save(args.out, **JPEG_OPTIONS)
    print(f"Wrote {args.out} from frame {best:02d} (coverage {scores[best][0]:.2f}, {args.out.stat().st_size // 1024} KB).")


if __name__ == "__main__":
    main()
