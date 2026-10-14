#!/usr/bin/env python3
"""Synthesize an original, restrained electronic score for the marketing video."""

from __future__ import annotations

import argparse
from pathlib import Path
import wave

import numpy as np


SAMPLE_RATE = 48_000
BEAT_SECONDS = 60 / 96
SCENE_ARPEGGIOS = (
    (50, 57, 62, 65), (53, 60, 65, 69), (48, 55, 60, 64),
    (55, 62, 67, 70), (52, 59, 64, 67), (50, 57, 62, 69),
)


def note_frequency(midi_note: int) -> float:
    return 440 * 2 ** ((midi_note - 69) / 12)


def write_soundtrack(
    output: Path, duration_seconds: float, transition_seconds: list[float],
) -> None:
    """Write deterministic stereo PCM: drone, pulse, arpeggios, swells, and chime.

    Scene changes shift the harmony; the final scene resolves to an open D chord.
    Every voice has a smooth envelope and the master peaks below full scale.
    """
    if not np.isfinite(duration_seconds) or duration_seconds <= 0:
        raise ValueError("The soundtrack duration must be a positive finite number")
    transitions = sorted({
        float(value) for value in transition_seconds
        if np.isfinite(value) and 0 < value < duration_seconds
    })
    samples = round(duration_seconds * SAMPLE_RATE)
    timeline = np.arange(samples) / SAMPLE_RATE
    mix = np.zeros((samples, 2), dtype=np.float64)
    random = np.random.default_rng(0x4D415452)

    def place(voice: np.ndarray, start: float, gain: float, pan: float = 0) -> None:
        offset = round(start * SAMPLE_RATE)
        first = max(0, offset)
        last = min(samples, offset + len(voice))
        if first >= last:
            return
        section = voice[first - offset:last - offset] * gain
        angle = (pan + 1) * np.pi / 4
        mix[first:last, 0] += section * np.cos(angle)
        mix[first:last, 1] += section * np.sin(angle)

    def voice_times(seconds: float) -> np.ndarray:
        return np.arange(round(seconds * SAMPLE_RATE)) / SAMPLE_RATE

    def envelope(time: np.ndarray, attack: float, decay: float) -> np.ndarray:
        return (1 - np.exp(-time / attack)) * np.exp(-time / decay)

    # A quiet, beating fifth anchors the track without a prominent bass melody.
    base_frequency = note_frequency(38)
    drift = 0.035 * np.sin(2 * np.pi * 0.09 * timeline)
    for channel, detune in enumerate((-0.12, 0.12)):
        fundamental = np.sin(2 * np.pi * (base_frequency + detune) * timeline + drift)
        fifth = np.sin(2 * np.pi * (base_frequency * 1.5 + detune) * timeline)
        octave = np.sin(2 * np.pi * base_frequency * 2 * timeline)
        breath = 0.85 + 0.15 * np.sin(2 * np.pi * 0.13 * timeline)
        mix[:, channel] += (fundamental + 0.24 * fifth + 0.08 * octave) * breath * 0.055

    pattern = (0, 2, 1, 3, 2, 1, 0, 1)
    for index, start in enumerate(np.arange(0.1, duration_seconds, BEAT_SECONDS / 2)):
        scene = min(np.searchsorted(transitions, start, side="right"), len(SCENE_ARPEGGIOS) - 1)
        frequency = note_frequency(SCENE_ARPEGGIOS[scene][pattern[index % len(pattern)]])
        time = voice_times(1.8)
        tone = np.sin(2 * np.pi * frequency * time)
        tone += 0.18 * np.sin(2 * np.pi * frequency * 2 * time)
        tone += 0.035 * np.sin(2 * np.pi * frequency * 3 * time)
        tone *= envelope(time, 0.014, 0.36)
        # Sparse accents and two quiet echoes keep the pattern fluid and spacious.
        gain = 0.048 if index % 4 == 0 else 0.031
        pan = (-0.32, 0.22, -0.08, 0.35)[index % 4]
        place(tone, start, gain, pan)
        place(tone, start + BEAT_SECONDS / 2, gain * 0.20, -pan)
        place(tone, start + BEAT_SECONDS, gain * 0.09, pan)

    for index, start in enumerate(np.arange(0, duration_seconds, BEAT_SECONDS)):
        if index % 2 == 0:
            time = voice_times(0.32)
            phase = 2 * np.pi * (44 * time + 42 * (1 - np.exp(-time * 30)) / 30)
            kick = np.sin(phase) * envelope(time, 0.002, 0.065)
            place(kick, start, 0.11)
        time = voice_times(0.075)
        noise = random.standard_normal(len(time))
        noise -= np.convolve(noise, np.ones(19) / 19, mode="same")
        shaker = noise * envelope(time, 0.003, 0.013)
        place(shaker, start + BEAT_SECONDS / 2, 0.010, (-1) ** index * 0.35)

    for transition in transitions:
        time = voice_times(1.7)
        noise = random.standard_normal(len(time))
        air = np.convolve(noise, np.ones(11) / 11, mode="same")
        swell = np.where(time < 1.25, (time / 1.25) ** 2, np.exp(-(time - 1.25) * 12))
        chirp = np.sin(2 * np.pi * (420 * time + 180 * time ** 2))
        place((air + 0.08 * chirp) * swell, transition - 1.25, 0.042, -0.25)
        place(air * swell, transition - 1.23, 0.025, 0.4)

    final_start = transitions[-1] if transitions else max(0, duration_seconds - 8)
    for index, midi_note in enumerate((62, 69, 74)):
        time = voice_times(5)
        frequency = note_frequency(midi_note)
        chime = np.sin(2 * np.pi * frequency * time)
        chime += 0.22 * np.sin(2 * np.pi * frequency * 2.003 * time)
        chime += 0.08 * np.sin(2 * np.pi * frequency * 3.997 * time)
        chime *= envelope(time, 0.008, 1.35)
        place(chime, final_start + 0.35 + index * 0.55, 0.070 - index * 0.01, (index - 1) * 0.3)

    fade = np.minimum(1, timeline / 0.5) * np.minimum(1, (duration_seconds - timeline) / 1)
    mix = np.tanh(mix * 1.2) * np.clip(fade[:, None], 0, 1)
    peak = np.max(np.abs(mix))
    if peak > 0:
        mix *= 0.68 / peak
    pcm = np.rint(np.clip(mix, -1, 1) * 32767).astype("<i2")
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output), "wb") as soundtrack:
        soundtrack.setparams((2, 2, SAMPLE_RATE, samples, "NONE", "not compressed"))
        soundtrack.writeframes(pcm.tobytes())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--duration", type=float, default=30)
    parser.add_argument("--transitions", type=float, nargs="*", default=[5, 9, 13, 17, 21])
    arguments = parser.parse_args()
    write_soundtrack(arguments.output, arguments.duration, arguments.transitions)
