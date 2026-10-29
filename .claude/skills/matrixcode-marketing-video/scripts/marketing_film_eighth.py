"""Six ambient rain atmospheres with different scale, weight, and movement."""

from pathlib import Path

from marketing_model import Film, INVITATION, Scene


EIGHTH_FILM = Film("eighth", "Matrix Code — Atmospheres", (
    Scene("atmosphere-jade", "Jade hush", 5.5,
          {"preset": "custom", "color": "#77DDAA", "glyphs": "matrix", "font": "gothic",
           "density": 2.6, "size": 3.2, "speed": 0.65, "trail": 0.32,
           "trailvar": 0.2, "glyphrate": 0.3, "glow": 0.9, "lead": 1.45,
           "vignette": 0.28}, warmup=60),
    Scene("atmosphere-silk", "Silk curtains", 4.5,
          {"preset": "custom", "color": "#B8A5FF", "glyphs": "matrix", "font": "gothic",
           "density": 55, "size": 1.1, "speed": 0.7, "trail": 0.38,
           "trailvar": 0.15, "glyphrate": 0.75, "glow": 0.85, "lead": 0.6,
           "overlap": "true", "vignette": 0.25}, warmup=35),
    Scene("atmosphere-mist", "Silver mist", 4.5,
          {"preset": "custom", "color": "#F0F6FF", "glyphs": "symbols", "font": "mono",
           "density": 18.5, "size": 0.55, "speed": 2.1, "trail": 0.12,
           "glyphrate": 2.8, "glow": 0.9, "lead": 2.1, "vignette": 0.2}),
    Scene("atmosphere-liquid", "Liquid turquoise", 4.5,
          {"preset": "custom", "color": "#37C6D7", "glyphs": "katakana", "font": "rounded",
           "density": 4.5, "size": 2.2, "speed": 1.3, "trail": 0.5,
           "trailvar": 0, "glyphrate": 0.25, "glow": 1.55, "lead": 1.8,
           "vignette": 0.23}, warmup=30),
    Scene("atmosphere-storm", "Monsoon", 5.5,
          {"preset": "custom", "color": "#86A8CC", "glyphs": "matrix", "font": "matrix",
           "density": 18, "size": 0.95, "speed": 2.8, "trail": 0.13,
           "glyphrate": 3.5, "glow": 0.85, "lead": 2.1, "vignette": 0.3}),
    Scene("atmosphere-rose", "Rose dusk", 5.5,
          {"preset": "custom", "color": "#EFA7BB", "glyphs": "latin", "font": "mincho",
           "mirror": "false", "density": 5, "size": 2.6, "speed": 0.6,
           "trail": 0.45, "trailvar": 0.1, "glyphrate": 0.35,
           "glow": 2.3, "lead": 0.45, "vignette": 0.55}, warmup=45),
    INVITATION,
), Path("styles/atmospheres/matrixcode-atmospheres.mp4"))
