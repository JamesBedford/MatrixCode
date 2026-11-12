"""Classic green rain with the corner URL, prepared for silent looping playback."""

from pathlib import Path

from marketing_model import Film, Scene


CLASSIC_LOOP_FILM = Film(
    "classic-loop", "Matrix Code — Classic green seamless loop",
    (Scene(
        "classic-loop", "Classic green", 32,
        {"preset": "classic", "glyphs": "matrix", "font": "matrix", "mirror": "true",
         "density": 3.5, "size": 1.2, "glow": 0.95, "speed": 1, "trail": 0.255,
         "trailvar": 1, "glyphrate": 1, "lead": 1.6, "vignette": 0.1,
         "scanlines": "false", "overlap": "false"},
        warmup=24, preview_seconds=8, overlays=False, corner_url=True,
    ),),
    Path("loops/classic-green/matrixcode-classic-green-loop.mp4"),
    score=None, loop_overlap=2,
)
