"""Sixty short social cuts. The 36-second films stay the long tour.

Each cut opens on a long-film picture: the same density, size, speed, trail, and
glow as one of those scenes. Words and images use that scene's placement and are
already resolved. The scene name sits in the long-film lower-left title slot.
"""

from __future__ import annotations

import copy
import math
from pathlib import Path

from marketing_film_eighth import EIGHTH_FILM
from marketing_film_fifth import FIFTH_FILM
from marketing_film_fourth import FOURTH_FILM
from marketing_film_seventh import SEVENTH_FILM
from marketing_film_sixth import SIXTH_FILM
from marketing_film_third import THIRD_FILM
from marketing_model import CAPTURE_EPOCH_MS, Film, Scene

# Bodies copied from the first and second films. Those films live in the capture
# script, which imports this module, so the numbers are checked against them in tests.
CLASSIC = {"preset": "classic", "density": 5, "size": 1.5, "glow": 1.2, "speed": 1, "trail": 0.25}
BLUE = {"preset": "blue", "glyphs": "binary", "density": 7, "size": 1.8, "glow": 1.35, "speed": 1.4, "trail": 0.16}
AMBER = {"preset": "amber", "glyphs": "digits", "font": "terminal", "density": 6, "size": 2,
         "glow": 0.85, "speed": 0.75, "trail": 0.18, "scanlines": "true"}
PURPLE = {"preset": "purple", "glyphs": "katakana", "density": 8, "size": 1.4, "glow": 1.9, "speed": 1.05, "trail": 0.32}
FINE = {"preset": "classic", "density": 12, "size": 0.65, "glow": 0.9, "speed": 1.15, "trail": 0.18}
PACKED = {"preset": "classic", "density": 60, "size": 1.6, "glow": 0.65, "speed": 1.2, "trail": 0.12}
RED = {"preset": "red", "glyphs": "symbols", "density": 9, "size": 1.4, "glow": 1.1, "speed": 2.5, "trail": 0.1, "glyphrate": 4}
GOLD = {"preset": "gold", "font": "mincho", "density": 5, "size": 2.3, "glow": 0.65, "speed": 0.35,
        "trail": 0.42, "trailvar": 0.15, "glyphrate": 0.15}
WHITE = {"preset": "white", "glyphs": "latin", "font": "mono", "mirror": "false", "density": 7, "size": 1.8,
         "glow": 0.3, "speed": 0.9, "trail": 0.24}
TEAL = {"preset": "custom", "color": "#00FFD5", "font": "rounded", "density": 9, "size": 1.2,
        "glow": 2.2, "speed": 1.2, "trail": 0.36, "lead": 2}
LAUNCH = {"preset": "pink", "density": 6, "size": 3.3, "glow": 0.8, "speed": 1.5, "trail": 0.32,
          "glyphs": "digits", "lead": 0.7, "glyphrate": 5}


def _scene(film: Film, name: str) -> Scene:
    return next(scene for scene in film.scenes if scene.name == name)


def _seconds(speed: float) -> int:
    if speed >= 2.4:
        return 6
    if speed <= 0.6:
        return 10
    if speed <= 0.85:
        return 9
    return 8


def _hold(documents: dict | None) -> dict | None:
    """Keep a long-film word or image fully resolved through the short."""
    if not documents:
        return None
    held = copy.deepcopy(documents)
    held.pop("mx-intro", None)
    images = held.get("mx-images")
    if isinstance(images, dict) and images.get("enabled"):
        images.update(frequencyMs=400, persistenceMs=180000, appearMs=0, disappearMs=0,
                      flickerOut=False, brightnessFade=False)
    messages = held.get("mx-messages")
    if isinstance(messages, dict) and messages.get("enabled"):
        messages.update(frequencyMs=400, persistenceMs=180000, appearMs=500, disappearMs=0,
                        flickerOut=False, brightnessFade=False)
    return held or None


def _clip(number: int, slug: str, settings: dict, title: str, *, documents: dict | None = None,
          focus_text: str | None = None) -> Film:
    speed = float(settings.get("speed", 1))
    # Slow rain is warmed until the trails already fill the frame.
    warmup = max(22.0, math.ceil((22.0 / speed) * 10) / 10)
    key = f"{number:02d}-{slug}"
    shot = Scene(key, title, _seconds(speed), settings, warmup=warmup, platform_labels=True,
                 documents=documents, focus_text=focus_text)
    return Film(key, f"Matrix Code — {title}", (shot,),
                Path("shorts") / key / "matrixcode.mp4")


def _from_scene(number: int, slug: str, source: Scene, title: str | None = None, **changes) -> Film:
    settings = {key: value for key, value in source.settings.items() if key != "ramp"}
    settings.update(changes)
    return _clip(number, slug, settings, title or source.title,
                 documents=_hold(source.documents), focus_text=source.focus_text)


def _launch_documents() -> dict:
    return _hold({
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
    })


def _build() -> tuple[Film, ...]:
    clips: list[Film] = []

    def add(slug: str, settings: dict, title: str, documents: dict | None = None,
            focus_text: str | None = None) -> None:
        clips.append(_clip(len(clips) + 1, slug, settings, title, documents=documents, focus_text=focus_text))

    def add_scene(slug: str, source: Scene, **changes) -> None:
        clips.append(_from_scene(len(clips) + 1, slug, source, **changes))

    add("classic-green", CLASSIC, "Classic green")
    add("blue-binary", BLUE, "Electric blue binary")
    add("amber-terminal", AMBER, "Amber terminal")
    add("neon-purple", PURPLE, "Neon purple")
    add("fine-columns", FINE, "More columns")
    add("packed-columns", PACKED, "Non-overlapping rain columns")
    add("overlap-columns", {**PACKED, "overlap": "true"}, "Overlapping rain columns")
    add("red-storm", RED, "Red symbol storm")
    add("golden-slow", GOLD, "Golden slow motion")
    add("monochrome", WHITE, "Monochrome lettering")
    add("custom-teal", TEAL, "Your own colour")
    add("launch", LAUNCH, "Count down to anything", _launch_documents(), "LAUNCH 00:00")
    for slug, name in (
        ("hello-alex", "your-name"),
        ("stay-curious", "your-words"),
        ("live-clock", "live-clock"),
        ("count-up", "count-up"),
        ("dream", "vertical-words"),
        ("your-space", "word-placement"),
    ):
        add_scene(slug, _scene(THIRD_FILM, name))
    add_scene("purple-build", _scene(FOURTH_FILM, "rain-ramp"))
    add_scene("readable", _scene(FOURTH_FILM, "glyph-mirroring"))
    for slug, name in (
        ("moon", "moon"),
        ("skyline", "panorama"),
        ("planet", "image-scale"),
        ("violet-moon", "image-fade"),
    ):
        add_scene(slug, _scene(FIFTH_FILM, name))
    for slug, name in (
        ("fuchsia", "fuchsia-circuit"),
        ("azure", "azure-voltage"),
        ("acid", "acid-bloom"),
        ("violet-flux", "violet-flux"),
        ("laser-teal", "laser-teal"),
        ("crimson", "crimson-horizon"),
    ):
        add_scene(slug, _scene(SIXTH_FILM, name))
    for slug, name in (
        ("olive", "olive-phosphor"),
        ("paper", "paper-terminal"),
        ("copper", "copper-circuit"),
        ("green-glass", "green-glass"),
        ("sepia", "sepia-archive"),
        ("silver", "silver-filament"),
    ):
        add_scene(slug, _scene(SEVENTH_FILM, name))
    for slug, name in (
        ("jade", "atmosphere-jade"),
        ("silk", "atmosphere-silk"),
        ("mist", "atmosphere-mist"),
        ("liquid", "atmosphere-liquid"),
        ("monsoon", "atmosphere-storm"),
        ("rose-dusk", "atmosphere-rose"),
    ):
        add_scene(slug, _scene(EIGHTH_FILM, name))
    for slug, settings, title in (
        ("orange-columns", {**CLASSIC, "preset": "orange"}, "Orange columns"),
        ("pink-columns", {**CLASSIC, "preset": "pink"}, "Pink columns"),
        ("red-columns", {**CLASSIC, "preset": "red"}, "Red columns"),
        ("gold-katakana", {**CLASSIC, "preset": "gold", "glyphs": "katakana", "font": "mincho"}, "Gold katakana"),
        ("white-digits", {**CLASSIC, "preset": "white", "glyphs": "digits", "font": "mono", "mirror": "false"}, "White digits"),
        ("blue-latin", {**BLUE, "glyphs": "latin", "font": "gothic", "mirror": "false"}, "Blue lettering"),
        ("teal-binary", {**BLUE, "preset": "custom", "color": "#00FFD5"}, "Teal binary"),
        ("purple-binary", {**BLUE, "preset": "purple"}, "Purple binary"),
        ("purple-latin", {**PURPLE, "glyphs": "latin", "font": "mincho", "mirror": "false"}, "Purple lettering"),
        ("pink-katakana", {**PURPLE, "preset": "pink"}, "Pink katakana"),
        ("amber-katakana", {**PURPLE, "preset": "amber"}, "Amber katakana"),
        ("orange-storm", {**RED, "preset": "orange"}, "Orange storm"),
        ("classic-storm", {**RED, "preset": "classic"}, "Green symbol storm"),
        ("blue-storm", {**RED, "preset": "blue"}, "Blue symbol storm"),
        ("green-terminal", {**AMBER, "preset": "classic"}, "Green terminal"),
        ("white-terminal", {**AMBER, "preset": "white", "mirror": "false"}, "White terminal"),
        ("blue-fine", {**FINE, "preset": "blue", "glyphs": "binary", "font": "mono", "mirror": "false"}, "Fine blue columns"),
        ("gold-fine", {**FINE, "preset": "gold", "font": "mincho"}, "Fine gold columns"),
    ):
        add(slug, settings, title)
    return tuple(clips)


SHORT_CLIPS = _build()
SHORT_FILMS = {film.key: film for film in SHORT_CLIPS}
