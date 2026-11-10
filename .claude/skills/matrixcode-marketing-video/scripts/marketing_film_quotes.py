"""A looping X promo: Try it now, five readable quotes, then Try it now again.

Each quote is a short extract from a recent optimistic AI post. The handle is a
second rain line, written with the message @ glyph. The opening line and the
quotes resolve out of the rain the way the closing invitation does. Style names
are not burned in. The score is original. It is not music from The Matrix.
"""

from __future__ import annotations

from pathlib import Path

from marketing_model import CTA, INVITATION, Film, Scene


# Same rain body as the invitation, so a quote sits in the code instead of on a dark field.
READABLE = {
    "density": 12, "speed": 1.5, "trail": 0.24, "glow": 1.3, "overlap": "false",
}
# Rain is full, and the flicker-in is still on screen when recording starts.
# A five-second shot then spends most of its time writing and the last second resolved.
QUOTE_WARMUP = 3
QUOTE_REVEAL_SECONDS = 3.5


def _messages(text: str, vertical: float = 0.44) -> dict:
    return {"mx-messages": {
        "messages": [text], "enabled": True,
        "frequencyMs": 500, "persistenceMs": 60000,
        "appearMs": round((QUOTE_WARMUP + QUOTE_REVEAL_SECONDS) * 1000),
        "disappearMs": 0,
        "flickerOut": True, "brightnessFade": False,
        "messageLayout": "row", "messageDirection": "topToBottom",
        "horizontalPosition": 0.5, "horizontalJitter": 0,
        "verticalPosition": vertical, "verticalJitter": 0,
    }}


def quote_scene(name: str, title: str, settings: dict, quote: str, handle: str) -> Scene:
    """One style, one large line, and the poster's handle on the next row."""
    return Scene(
        name, title, 5, {**READABLE, **settings}, warmup=QUOTE_WARMUP,
        documents=_messages(quote), focus_text=quote,
        credit_line=f"@{handle}", preview_seconds=4, show_title=False,
    )


# Same picture and reveal as the closing invitation. The centered headline stays
# from the first frame; the in-rain line writes itself during the shot.
OPENING = Scene(
    "try-it-now", INVITATION.title, 5, dict(INVITATION.settings),
    warmup=QUOTE_WARMUP, loop_open=True, documents=_messages(CTA, vertical=0.5),
    preview_seconds=4,
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
             "font": "rounded", "size": 4},
            "LITERALLY ANYTHING", "itsolelehmann",
        ),
        INVITATION,
    ),
    Path("quotes/matrixcode-quotes.mp4"),
    score="matrix",
)
