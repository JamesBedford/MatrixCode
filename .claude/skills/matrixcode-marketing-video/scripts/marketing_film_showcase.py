"""Four short films that demonstrate Matrix Code, rather than another colour.

Each one is 8–12 seconds, already full of rain, with the outcome written at the
top from the first frame. They do not use the long closing invitation.
"""

from __future__ import annotations

import base64
from pathlib import Path

from PIL import Image, ImageDraw

from marketing_model import CAPTURE_EPOCH_MS, Film, Scene

READABLE_RAIN = {
    "preset": "classic", "glyphs": "latin", "font": "rounded", "mirror": "false",
    "density": 5, "size": 4.6, "glow": 0.7, "speed": 1.15, "trail": 0.34,
    "lead": 0.55, "glyphrate": 4, "overlap": "false",
}
COUNTDOWN_WARMUP = 12
COUNTDOWN_SECONDS = 10


def _message(template: str) -> dict:
    return {
        "mx-messages": {
            "messages": [template], "enabled": True,
            "frequencyMs": 500, "persistenceMs": 60000,
            "appearMs": 400, "disappearMs": 0,
            "flickerOut": False, "brightnessFade": False,
            "messageLayout": "row", "messageDirection": "topToBottom",
            "horizontalPosition": 0.5, "horizontalJitter": 0,
            "verticalPosition": 0.5, "verticalJitter": 0,
        },
    }


def named_scene(name: str, title: str, seconds: float) -> Scene:
    """A resolved phrase, held for the whole shot."""
    return Scene(
        name, title, seconds, READABLE_RAIN, warmup=14, caption_top=True,
        documents=_message("YOUR NAME"),
        focus_text="YOUR NAME", preview_seconds=0.2,
    )


def play_mask() -> dict:
    """A solid triangle. Large cells keep the silhouette obvious after compression."""
    artwork = Image.new("L", (384, 384), 32)
    ImageDraw.Draw(artwork).polygon([(64, 48), (64, 336), (332, 192)], fill=255)
    mask = artwork.resize((96, 96), Image.Resampling.LANCZOS)
    return {"name": "Play", "width": mask.width, "height": mask.height,
            "data": base64.b64encode(mask.tobytes()).decode("ascii")}


def picture_scene() -> Scene:
    return Scene(
        "picture", "A picture, made of code", 10,
        {"preset": "classic", "glyphs": "latin", "font": "mono", "mirror": "false",
         "density": 14, "size": 1.7, "glow": 0.45, "speed": 1.05, "trail": 0.3,
         "lead": 0.15, "overlap": "false"},
        warmup=18, caption_top=True, preview_seconds=0.4,
        documents={"mx-images": {
            "images": [play_mask()], "enabled": True, "frequencyMs": 500,
            "persistenceMs": 60000, "appearMs": 300, "disappearMs": 0,
            "flickerOut": False, "brightnessFade": False,
            "imageScale": 0.9, "imagePlacementJitter": 0,
        }},
    )


def countdown_scene() -> Scene:
    # Recording starts after the warmup, then runs COUNTDOWN_SECONDS.
    # The first frame reads 00:10 and the last frame reads 00:00.
    target = CAPTURE_EPOCH_MS + (COUNTDOWN_WARMUP + COUNTDOWN_SECONDS) * 1000
    return Scene(
        "countdown", "Count down to anything", COUNTDOWN_SECONDS,
        {"preset": "pink", "glyphs": "digits", "font": "mono", "mirror": "false",
         "density": 6, "size": 4.2, "glow": 0.55, "speed": 1.3, "trail": 0.36,
         "lead": 0.4, "glyphrate": 5, "overlap": "false"},
        warmup=COUNTDOWN_WARMUP, caption_top=True, preview_seconds=0.2,
        focus_text="LAUNCH 00:10",
        documents={
            "mx-countdown": {"targetMs": None, "moments": [
                {"name": "Launch", "targetMs": target},
            ]},
            **_message("LAUNCH {countdown:Launch}"),
        },
    )


def light_scene() -> Scene:
    return Scene(
        "light", "The letters stay. The light falls.", 8,
        {"preset": "classic", "glyphs": "matrix", "font": "matrix",
         "density": 4, "size": 2.5, "glow": 1.15, "speed": 1.35, "trail": 0.42,
         "overlap": "false"},
        warmup=22, caption_top=True, preview_seconds=0.2,
    )


def _film(key: str, title: str, scenes: tuple[Scene, ...]) -> Film:
    return Film(key, title, scenes, Path("showcase") / key / "matrixcode.mp4")


SHOWCASE_CLIPS = (
    _film("showcase-story", "Matrix Code — A screensaver you can write on", (
        Scene("screensaver", "A screensaver", 5,
              {"preset": "classic", "density": 5, "size": 1.8, "glow": 1.15,
               "speed": 1.1, "trail": 0.3, "overlap": "false"},
              warmup=22, caption_top=True, preview_seconds=0.2),
        named_scene("your-name", "Write your name", 7.5),
    )),
    _film("showcase-picture", "Matrix Code — A picture, made of code", (picture_scene(),)),
    _film("showcase-countdown", "Matrix Code — Count down to anything", (countdown_scene(),)),
    _film("showcase-light", "Matrix Code — The letters stay", (light_scene(),)),
)
SHOWCASE_FILMS = {film.key: film for film in SHOWCASE_CLIPS}
