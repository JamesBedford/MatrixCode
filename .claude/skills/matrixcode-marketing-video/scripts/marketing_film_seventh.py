"""Six phosphor and terminal rain styles for a retro showcase."""

from pathlib import Path

from marketing_model import Film, INVITATION, Scene


SEVENTH_FILM = Film("seventh", "Matrix Code — Phosphor memories", (
    Scene(
        "olive-phosphor", "Olive Phosphor", 5.5,
        {"preset": "custom", "color": "#B4D978", "glyphs": "latin", "font": "terminal",
         "mirror": "false", "density": 6, "size": 2.15, "speed": 0.8,
         "trail": 0.28, "trailvar": 0.2, "glyphrate": 0.2, "glow": 0.75,
         "lead": 0.9, "scanlines": "true", "vignette": 0.26},
        warmup=24,
    ),
    Scene(
        "paper-terminal", "Paper Terminal", 4.5,
        {"preset": "custom", "color": "#F0E8CB", "glyphs": "binary", "font": "mono",
         "mirror": "false", "density": 10, "size": 0.8, "speed": 1.45,
         "trail": 0.13, "glyphrate": 2.2, "glow": 0.35, "lead": 1.05,
         "scanlines": "false", "vignette": 0.1},
    ),
    Scene(
        "copper-circuit", "Copper Circuit", 4.5,
        {"preset": "custom", "color": "#E49B56", "glyphs": "symbols", "font": "gothic",
         "mirror": "false", "density": 9, "size": 1.7, "speed": 1.2,
         "trail": 0.27, "glyphrate": 3.1, "glow": 1.1, "lead": 1.5,
         "scanlines": "true", "vignette": 0.25},
    ),
    Scene(
        "green-glass", "Green Glass", 4.5,
        {"preset": "custom", "color": "#A9EFB4", "glyphs": "digits", "font": "mono",
         "mirror": "false", "density": 4.3, "size": 3, "speed": 1.35,
         "trail": 0.1, "glyphrate": 0.1, "glow": 0.25, "lead": 1.8,
         "scanlines": "true", "vignette": 0.3},
    ),
    Scene(
        "sepia-archive", "Sepia Archive", 5.5,
        {"preset": "custom", "color": "#D7BE89", "glyphs": "matrix", "font": "mincho",
         "density": 11, "size": 1.05, "speed": 0.65,
         "trail": 0.37, "trailvar": 0.1, "glyphrate": 0.35,
         "glow": 0.45, "lead": 1, "scanlines": "false", "vignette": 0.4},
        warmup=30,
    ),
    Scene(
        "silver-filament", "Silver Filament", 5.5,
        {"preset": "white", "glyphs": "katakana", "font": "rounded",
         "density": 16, "size": 0.8, "speed": 1.9,
         "trail": 0.2, "glyphrate": 3.5, "glow": 1.1, "lead": 1.6,
         "scanlines": "true", "vignette": 0.18},
    ),
    INVITATION,
), Path("styles/phosphor/matrixcode-phosphor.mp4"))
