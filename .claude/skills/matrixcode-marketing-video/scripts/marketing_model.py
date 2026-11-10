"""Shared recipe types, capture format, and closing invitation for every film."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

SIZE = (1920, 1080)
FPS = 30
TRANSITION = 0.5
CAPTURE_EPOCH_MS = 1_791_979_200_000  # 2026-10-14 12:00 UTC, an ordinary capture date
CTA = "Try it now!"


@dataclass(frozen=True)
class Scene:
    name: str
    title: str
    seconds: float
    settings: dict
    warmup: float = 18
    message: bool = False
    overlap_comparison: bool = False
    documents: dict | None = None
    preview_seconds: float = 1.5
    focus_text: str | None = None
    start_images_after_warmup: bool = False
    play_intro: bool = False
    actions: tuple[tuple[float, str], ...] = ()
    comparison_settings: dict | None = None
    comparison_title: str | None = None
    # Short social cuts burn the three platform names in from the first frame.
    platform_labels: bool = False
    # Feature showcases put one outcome caption at the top, already drawn on frame 0.
    caption_top: bool = False
    # Settled invitation chrome from frame 0, so a loop matches the closing frame.
    loop_open: bool = False
    # A second rain line centered under the focused message. Capture stamps it
    # with the message glyphs; the app itself still draws the line above.
    credit_line: str | None = None


@dataclass(frozen=True)
class Film:
    key: str
    title: str
    scenes: tuple[Scene, ...]
    relative_output: Path
    # "industrial" is the shared score. "matrix" is the darker looping promo score.
    score: str = "industrial"

    @property
    def duration(self) -> float:
        return sum(scene.seconds for scene in self.scenes) - TRANSITION * (len(self.scenes) - 1)

    @property
    def transitions(self) -> list[float]:
        return [sum(scene.seconds - TRANSITION for scene in self.scenes[:index])
                for index in range(1, len(self.scenes))]


INVITATION = Scene(
    "invitation", "Your Matrix Code. Your style.", 9,
    {"preset": "classic", "density": 12, "size": 4.4, "glow": 1.3, "speed": 1.5, "trail": 0.24},
    warmup=3, message=True,
)
