"""Six saturated neon looks captured with the ordinary rain controls."""

from pathlib import Path

from marketing_model import INVITATION, Film, Scene


def neon_scene(name: str, title: str, seconds: float, color: str, **settings) -> Scene:
    return Scene(name, title, seconds, {
        "preset": "custom", "color": color, "scanlines": "false",
        "vignette": 0.18, "mirror": "true", "overlap": "false", **settings,
    })


SIXTH_FILM = Film("sixth", "Matrix Code — Neon nights", (
    neon_scene(
        "fuchsia-circuit", "Fuchsia Circuit", 5.5, "#FF1493",
        glyphs="katakana", font="gothic", density=10, size=1.25,
        speed=1.65, trail=0.26, trailvar=0.75, glyphrate=2.5, glow=1.6, lead=1.2,
    ),
    neon_scene(
        "azure-voltage", "Azure Voltage", 4.5, "#438DFF",
        glyphs="latin", font="mono", density=13, size=0.9,
        speed=2.15, trail=0.18, glyphrate=3.5, glow=1.25, lead=1.8, mirror="false",
    ),
    neon_scene(
        "acid-bloom", "Acid Bloom", 4.5, "#B8FF00",
        glyphs="matrix", font="rounded", density=9, size=1.8,
        speed=1.2, trail=0.35, glyphrate=1.5, glow=1.9, lead=0.85,
    ),
    neon_scene(
        "violet-flux", "Violet Flux", 4.5, "#BC61FF",
        glyphs="symbols", font="terminal", density=10, size=1.65,
        speed=0.95, trail=0.3, glyphrate=3.5, glow=1.95, lead=1.1,
    ),
    neon_scene(
        "laser-teal", "Laser Teal", 5.5, "#00FFC2",
        glyphs="binary", font="mono", density=24, size=0.7,
        speed=1.8, trail=0.23, glyphrate=2, glow=0.9, lead=1.35, overlap="true",
    ),
    neon_scene(
        "crimson-horizon", "Crimson Horizon", 5.5, "#FF3B57",
        glyphs="digits", font="mono", density=8, size=2.6,
        speed=0.6, trail=0.42, glyphrate=0.6, glow=1.2, lead=0.65, mirror="false",
    ),
    INVITATION,
), Path("styles/neon/matrixcode-neon.mp4"))
