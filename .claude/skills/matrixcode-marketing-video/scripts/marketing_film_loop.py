"""Silent matrix rain with the corner URL, prepared for seamless looping playback."""

from pathlib import Path

from marketing_model import Film, Scene


def silent_matrix_loop(key: str, title: str, scene_title: str, preset: str, output: str) -> Film:
    """One continuous matrix-glyph shot. A two-second overlap closes a 30-second loop."""
    return Film(
        key, title,
        (Scene(
            key, scene_title, 32,
            {"preset": preset, "glyphs": "matrix", "font": "matrix", "mirror": "true",
             "density": 3.5, "size": 1.2, "glow": 0.95, "speed": 1, "trail": 0.255,
             "trailvar": 1, "glyphrate": 1, "lead": 1.6, "vignette": 0.1,
             "scanlines": "false", "overlap": "false"},
            warmup=24, preview_seconds=8, overlays=False, corner_url=True,
        ),),
        Path(output),
        score=None, loop_overlap=2,
    )


CLASSIC_LOOP_FILM = silent_matrix_loop(
    "classic-loop", "Matrix Code — Classic green seamless loop", "Classic green",
    "classic", "loops/classic-green/matrixcode-classic-green-loop.mp4",
)
PURPLE_LOOP_FILM = silent_matrix_loop(
    "purple-loop", "Matrix Code — Purple seamless loop", "Purple matrix",
    "purple", "loops/purple-matrix/matrixcode-purple-matrix-loop.mp4",
)
