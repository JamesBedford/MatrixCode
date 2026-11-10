"""A looping X promo: Try it now, five readable quotes, then Try it now again.

Each quote is a short extract from a recent optimistic AI post. The handle is a
second rain line. The rain alphabet has no @ sign, so the credit reads "X: handle".
The score is original. It is not music from The Matrix.
"""

from __future__ import annotations

from pathlib import Path

from marketing_model import CTA, INVITATION, Film, Scene


READABLE = {
    "density": 5, "speed": 1.2, "trail": 0.28, "trailvar": 0.2, "glyphrate": 3,
    "glow": 0.65, "lead": 0.35, "overlap": "false", "vignette": 0.18,
}


def _messages(text: str, vertical: float = 0.44) -> dict:
    return {"mx-messages": {
        "messages": [text], "enabled": True,
        "frequencyMs": 500, "persistenceMs": 60000,
        "appearMs": 400, "disappearMs": 0,
        "flickerOut": False, "brightnessFade": False,
        "messageLayout": "row", "messageDirection": "topToBottom",
        "horizontalPosition": 0.5, "horizontalJitter": 0,
        "verticalPosition": vertical, "verticalJitter": 0,
    }}


def quote_scene(name: str, title: str, settings: dict, quote: str, handle: str) -> Scene:
    """One style, one large line, and the poster's X handle on the next row."""
    return Scene(
        name, title, 5, {**READABLE, **settings}, warmup=14,
        documents=_messages(quote), focus_text=quote,
        credit_line=f"X: {handle}", preview_seconds=2,
    )


# Bookend uses the shared invitation picture so the first and last frames agree.
OPENING = Scene(
    "try-it-now", INVITATION.title, 5, dict(INVITATION.settings),
    warmup=12, loop_open=True, documents=_messages(CTA, vertical=0.5),
    preview_seconds=1,
)


# Lines are short extracts, not the whole post. Handles are the X accounts.
# @gdb, 8 Nov 2026: "the engine of scientific discovery"
# @davidvgilmore, 9 Nov 2026: "a better future for AI"
# @dhh, 9 Nov 2026: "the machines amazing"
# @brivael, 8 Nov 2026: "never been more optimistic"
# @itsolelehmann, 6 Nov 2026: "applied to literally anything"
QUOTES_FILM = Film(
    "quotes", "Matrix Code — Try it now", (
        OPENING,
        quote_scene(
            "blue-binary", "Blue binary",
            {"preset": "blue", "glyphs": "binary", "font": "mono", "size": 4},
            "ENGINE OF DISCOVERY", "gdb",
        ),
        quote_scene(
            "amber-terminal", "Amber terminal",
            {"preset": "amber", "glyphs": "digits", "font": "terminal",
             "size": 4.2, "scanlines": "true", "mirror": "false"},
            "A BETTER FUTURE", "davidvgilmore",
        ),
        quote_scene(
            "neon-purple", "Neon purple",
            {"preset": "purple", "glyphs": "katakana", "font": "gothic", "size": 3.8},
            "MACHINES ARE AMAZING", "dhh",
        ),
        quote_scene(
            "golden-code", "Golden code",
            {"preset": "gold", "glyphs": "katakana", "font": "mincho", "size": 3.4},
            "NEVER MORE OPTIMISTIC", "brivael",
        ),
        quote_scene(
            "crimson-rain", "Crimson rain",
            {"preset": "custom", "color": "#FF2A4A", "glyphs": "matrix",
             "font": "rounded", "size": 4, "glow": 0.95},
            "LITERALLY ANYTHING", "itsolelehmann",
        ),
        INVITATION,
    ),
    Path("quotes/matrixcode-quotes.mp4"),
    score="matrix",
)
