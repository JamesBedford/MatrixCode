"""Sixty short social cuts. The 36-second films stay the long tour for your own post.

Each cut is one finished look, 6–10 seconds, already full of rain at frame zero,
with the browser, screensaver, and both-monitors labels burned in.
"""

from __future__ import annotations

from pathlib import Path

from marketing_model import Film, Scene

# Ten palettes by six glyph treatments. Order is the on-disk folder order.
PRESETS = (
    ("classic", "Classic green", {}),
    ("amber", "Amber", {}),
    ("orange", "Orange", {}),
    ("blue", "Blue", {}),
    ("gold", "Gold", {}),
    ("red", "Red", {}),
    ("pink", "Pink", {}),
    ("purple", "Purple", {}),
    ("white", "White", {}),
    ("teal", "Teal", {"preset": "custom", "color": "#00FFD5"}),
)

GLYPH_LOOKS = (
    ("matrix", {
        "glyphs": "matrix", "font": "matrix", "density": 6, "size": 1.45,
        "glow": 1.15, "speed": 1.05, "trail": 0.26,
    }),
    ("katakana", {
        "glyphs": "katakana", "font": "mincho", "density": 8, "size": 1.35,
        "glow": 1.7, "speed": 1.15, "trail": 0.3,
    }),
    ("binary", {
        "glyphs": "binary", "font": "mono", "mirror": "false", "density": 7, "size": 1.7,
        "glow": 1.25, "speed": 1.45, "trail": 0.16,
    }),
    ("digits", {
        "glyphs": "digits", "font": "terminal", "mirror": "false", "scanlines": "true",
        "density": 6, "size": 1.9, "glow": 0.8, "speed": 0.85, "trail": 0.2,
    }),
    ("latin", {
        "glyphs": "latin", "font": "rounded", "mirror": "false", "density": 5, "size": 2.05,
        "glow": 1.05, "speed": 0.95, "trail": 0.28,
    }),
    ("symbols", {
        "glyphs": "symbols", "font": "gothic", "density": 9, "size": 1.25,
        "glow": 1.4, "speed": 1.8, "trail": 0.12, "glyphrate": 3,
    }),
)

SHORT_SECONDS = (6, 7, 8, 9, 10)


def _shorts() -> tuple[Film, ...]:
    films = []
    number = 0
    for preset_slug, preset_title, preset_settings in PRESETS:
        for glyph_slug, glyph_settings in GLYPH_LOOKS:
            number += 1
            settings = {"preset": preset_slug, **glyph_settings, **preset_settings}
            speed = float(settings["speed"])
            # Slow rain needs a longer hidden warmup so the exported frame is already full.
            warmup = max(22.0, round(22 / speed, 1))
            slug = f"{number:02d}-{preset_slug}-{glyph_slug}"
            scene = Scene(
                slug, preset_title, SHORT_SECONDS[(number - 1) % len(SHORT_SECONDS)], settings,
                warmup=warmup, platform_labels=True,
            )
            films.append(Film(
                slug, f"Matrix Code — {preset_title} {glyph_slug}", (scene,),
                # One folder per cut. Companion stills share this directory.
                Path("shorts") / slug / "matrixcode.mp4",
            ))
    return tuple(films)


SHORT_CLIPS = _shorts()
SHORT_FILMS = {film.key: film for film in SHORT_CLIPS}
