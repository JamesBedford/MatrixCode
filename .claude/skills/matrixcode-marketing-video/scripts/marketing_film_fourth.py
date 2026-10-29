"""A film about the rain's opening choreography and live keyboard controls."""

from pathlib import Path

from marketing_model import Film, INVITATION, Scene


def opening(lines: tuple[str, ...], *, during: bool, char_ms: int = 65,
            hold_ms: int = 550, fade_ms: int = 350) -> dict:
    """Supply a real editable intro document with a readable, bounded timeline."""
    return {"mx-intro": {
        "enabled": True,
        "lines": [{"text": text, "holdMs": hold_ms, "pauseMs": 0} for text in lines],
        "charMs": char_ms,
        "startDelayMs": 150,
        "fadeOutMs": fade_ms,
        "rainDuringIntro": during,
        "postIntroDelayMs": 0,
    }}


FOURTH_FILM = Film("fourth", "Matrix Code — Set the scene", (
    Scene(
        "opening-before-rain", "Your opening. Then the rain.", 5.5,
        {"preset": "classic", "glyphs": "matrix", "font": "matrix",
         "density": 9, "size": 1.8, "speed": 2.3, "trail": 0.28,
         "glow": 1.15, "ramp": 800},
        warmup=0, play_intro=True, preview_seconds=2.7,
        documents=opening(("Wake up, dreamer.", "Make it your Matrix."), during=False),
    ),
    Scene(
        "opening-over-rain", "Words over falling code", 4.5,
        {"preset": "custom", "color": "#7DD3FC", "glyphs": "matrix", "font": "gothic",
         "density": 8, "size": 1.6, "speed": 1.4, "trail": 0.27,
         "glow": 1.15, "lead": 1.2},
        warmup=0, play_intro=True, preview_seconds=2.6,
        documents=opening(("Your words.", "Your atmosphere."), during=True),
    ),
    Scene(
        "rain-ramp", "Build the atmosphere", 4.5,
        {"preset": "purple", "glyphs": "symbols", "font": "gothic",
         "density": 18, "size": 1.05, "speed": 2, "trail": 0.25,
         "glow": 1.1, "ramp": 3000},
        warmup=0, preview_seconds=3.8,
    ),
    Scene(
        "pause-and-resume", "Pause and resume", 4.5,
        {"preset": "custom", "color": "#FF875F", "glyphs": "katakana", "font": "rounded",
         "density": 6, "size": 1.8, "speed": 2.1, "trail": 0.2,
         "glow": 1.1},
        actions=((1.0, "P"), (2.4, "P")), preview_seconds=1.8,
    ),
    Scene(
        "density-keys", "Turn up the rain", 5.5,
        {"preset": "blue", "glyphs": "latin", "font": "gothic", "mirror": "false",
         "density": 2.5, "size": 0.9, "speed": 1.8, "trail": 0.17,
         "glow": 0.9, "overlap": "true"},
        actions=tuple((round(0.8 + index * 0.1, 2), "=") for index in range(18)),
        preview_seconds=4.2,
    ),
    Scene(
        "skip-opening", "Skip straight to the rain", 5.5,
        {"preset": "white", "glyphs": "symbols", "font": "rounded",
         "density": 8, "size": 2.4, "speed": 2.5, "trail": 0.23,
         "glow": 0.65, "lead": 1},
        warmup=0, play_intro=True, preview_seconds=4,
        documents=opening(("Your opening scene.",), during=False, char_ms=140,
                          hold_ms=5000, fade_ms=500),
        actions=((1.2, "Escape"),),
    ),
    INVITATION,
), Path("choreography/matrixcode-choreography.mp4"))
