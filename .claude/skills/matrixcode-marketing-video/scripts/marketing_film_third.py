"""Words, personalisation, and live information rendered by the rain itself."""

from __future__ import annotations

from pathlib import Path

from marketing_model import CAPTURE_EPOCH_MS, INVITATION, Film, Scene


MESSAGE_RAIN = {
    "density": 6, "speed": 1.5, "trail": 0.32, "glyphrate": 5,
    "glow": 0.8, "lead": 0.7, "overlap": "false",
}


def message_scene(
    name: str, title: str, seconds: float, settings: dict,
    template: str, resolved_example: str, *, layout: str = "row",
    horizontal: float = 0.5, vertical: float = 0.5, documents: dict | None = None,
) -> Scene:
    """Give each real message enough rain and hold time to remain readable."""
    message = {
        "messages": [template], "enabled": True,
        "frequencyMs": 500, "persistenceMs": 60000,
        "appearMs": 800, "disappearMs": 0,
        "flickerOut": False, "brightnessFade": False,
        "messageLayout": layout, "messageDirection": "topToBottom",
        "horizontalPosition": horizontal, "horizontalJitter": 0,
        "verticalPosition": vertical, "verticalJitter": 0,
    }
    return Scene(
        name, title, seconds, {**MESSAGE_RAIN, **settings}, warmup=12,
        documents={"mx-messages": message, **(documents or {})},
        focus_text=resolved_example,
    )


THIRD_FILM = Film("third", "Matrix Code — Code with a message", (
    message_scene(
        "your-name", "Your name in the rain", 5.5,
        {"preset": "custom", "color": "#69F7A8", "glyphs": "katakana",
         "font": "rounded", "size": 3.6, "name": "ALEX"},
        "HELLO {name}", "HELLO ALEX",
    ),
    message_scene(
        "your-words", "Say it in code", 4.5,
        {"preset": "gold", "glyphs": "latin", "font": "mincho", "size": 3.3,
         "density": 8, "lead": 0.35, "glow": 0.65},
        "STAY CURIOUS", "STAY CURIOUS",
    ),
    message_scene(
        "live-clock", "A clock made of code", 4.5,
        {"preset": "blue", "glyphs": "digits", "font": "mono", "size": 4.2,
         "density": 12, "trail": 0.42, "lead": 0.25, "glow": 0.55},
        "{time:%H:%M:%S}", "00:00:00",
    ),
    message_scene(
        "count-up", "Count every moment", 4.5,
        {"preset": "white", "glyphs": "digits", "font": "mono", "size": 3.8,
         "lead": 0.4, "glow": 0.45},
        "UP {countup:Session}", "UP 02:00",
        documents={"mx-countdown": {
            "targetMs": None,
            "moments": [{"name": "Session", "targetMs": CAPTURE_EPOCH_MS - 120000}],
        }},
    ),
    message_scene(
        "vertical-words", "Messages can fall vertically", 5.5,
        {"preset": "pink", "glyphs": "symbols", "font": "gothic", "size": 4,
         "density": 8, "glow": 0.65},
        "DREAM", "DREAM", layout="drop",
    ),
    message_scene(
        "word-placement", "Put words where you want", 5.5,
        {"preset": "custom", "color": "#BF9FFF", "glyphs": "matrix", "font": "terminal", "size": 3.4,
         "vignette": 0.35, "scanlines": "true"},
        "YOUR SPACE", "YOUR SPACE", horizontal=0.27, vertical=0.3,
    ),
    INVITATION,
), Path("words/matrixcode-words.mp4"))
