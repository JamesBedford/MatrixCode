#!/usr/bin/env python3
"""Synthesize an original industrial electronic action score for the video."""

from __future__ import annotations

import argparse
from pathlib import Path
import wave

import numpy as np


SAMPLE_RATE = 48_000
BEAT_SECONDS = 0.5
BASS_RIFF = (38, 38, 50, 38, None, 38, 41, 39, 38, None, 50, 38, 45, 41, 39, 38)
SCENE_ROOTS = (38, 38, 36, 38, 41, 38)


def note_frequency(midi_note: int) -> float:
    return 440 * 2 ** ((midi_note - 69) / 12)


def write_soundtrack(
    output: Path, duration_seconds: float, transition_seconds: list[float],
) -> None:
    """Write deterministic 48 kHz stereo PCM with a driving 120 BPM score."""
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
    final_start = transitions[-1] if transitions else max(0, duration_seconds - 9)
    final_hit = max(final_start, duration_seconds - 1)

    def times(seconds: float) -> np.ndarray:
        return np.arange(round(seconds * SAMPLE_RATE)) / SAMPLE_RATE

    def envelope(time: np.ndarray, attack: float, decay: float) -> np.ndarray:
        return (1 - np.exp(-time / attack)) * np.exp(-time / decay)

    def taper(voice: np.ndarray, seconds: float = 0.015) -> np.ndarray:
        length = min(len(voice), round(seconds * SAMPLE_RATE))
        voice[-length:] *= np.linspace(1, 0, length)
        return voice

    def filtered(signal: np.ndarray, low: float, high: float) -> np.ndarray:
        spectrum = np.fft.rfft(signal)
        frequency = np.fft.rfftfreq(len(signal), 1 / SAMPLE_RATE)
        response = 1 / np.sqrt(1 + (frequency / high) ** 8)
        if low:
            response *= 1 - np.exp(-(frequency / low) ** 4)
        return np.fft.irfft(spectrum * response, n=len(signal))

    def noise(time: np.ndarray, low: float, high: float) -> np.ndarray:
        signal = filtered(random.standard_normal(len(time)), low, high)
        return signal / max(float(np.std(signal)), 1e-9)

    def place(voice: np.ndarray, start: float, gain: float, pan: float = 0) -> None:
        offset = round(start * SAMPLE_RATE)
        first, last = max(0, offset), min(samples, offset + len(voice))
        if first >= last:
            return
        section = voice[first - offset:last - offset] * gain
        angle = (pan + 1) * np.pi / 4
        mix[first:last, 0] += section * np.cos(angle)
        mix[first:last, 1] += section * np.sin(angle)

    def saw(time: np.ndarray, frequency: float, cutoff: float) -> np.ndarray:
        signal = np.zeros(len(time))
        for harmonic in range(1, min(64, int(cutoff / frequency)) + 1):
            # Additive synthesis bounds the spectrum before controlled saturation.
            weight = np.exp(-(harmonic * frequency / cutoff) ** 2) / harmonic
            signal += weight * np.sin(2 * np.pi * harmonic * frequency * time)
        return signal * 0.64

    def bass(note: int, accented: bool, scene: int) -> np.ndarray:
        time = times(0.27 if accented else 0.23)
        frequency = note_frequency(note)
        tone = saw(time, frequency, 2600 + scene * 170)
        fm = np.sin(2 * np.pi * frequency * time + 1.1 * np.sin(2 * np.pi * frequency * 2 * time))
        tone = filtered(np.tanh((tone + 0.26 * fm) * 2.7), 105, 4200)
        body = envelope(time, 0.002, 0.15 if accented else 0.095)
        sub = np.sin(2 * np.pi * frequency / 2 * time) * envelope(time, 0.004, 0.17)
        return taper(tone * body + 0.43 * sub)

    # Keep the low end centered and give each scene its own rhythmic density.
    for step, start in enumerate(np.arange(0, final_hit, BEAT_SECONDS / 2)):
        scene = min(np.searchsorted(transitions, start, side="right"), len(SCENE_ROOTS) - 1)
        note = BASS_RIFF[step % len(BASS_RIFF)]
        if note is None:
            continue
        accented = step % 4 == 0
        note += SCENE_ROOTS[scene] - SCENE_ROOTS[0]
        place(bass(note, accented, scene), start, 0.23 if accented else 0.18)

    for beat, start in enumerate(np.arange(0, final_hit, BEAT_SECONDS)):
        time = times(0.43)
        phase = 2 * np.pi * (47 * time + 112 * (1 - np.exp(-time * 45)) / 45)
        kick = np.sin(phase) * envelope(time, 0.0007, 0.105)
        click = noise(time, 1800, 6800) * np.exp(-time / 0.004)
        place(taper(np.tanh(kick * 1.45) * 0.85 + 0.08 * click), start, 0.40)
        if beat % 2 == 1:
            time = times(0.31)
            body = np.sin(2 * np.pi * 184 * time) + 0.25 * np.sin(2 * np.pi * 329 * time)
            snap = noise(time, 650, 7500) * envelope(time, 0.0006, 0.064)
            clap = noise(time, 1100, 5100)
            clap *= sum(np.exp(-np.maximum(0, time - tap) / 0.031) * (time >= tap) for tap in (0, 0.009, 0.019)) / 3
            snare = 0.54 * body * envelope(time, 0.001, 0.04) + 0.5 * snap + 0.19 * clap
            place(taper(snare), start, 0.38)
            place(taper(snap.copy()), start + 0.018, 0.035, 0.55)
        # Offbeat open hats and alternating sixteenths supply momentum.
        for fraction in (0.25, 0.5, 0.75):
            scene = np.searchsorted(transitions, start, side="right")
            if fraction != 0.5 and scene in (0, 2):
                continue
            time = times(0.16 if fraction == 0.5 else 0.075)
            hat = noise(time, 5200, 12500) * envelope(time, 0.0005, 0.036 if fraction == 0.5 else 0.012)
            place(taper(hat), start + fraction * BEAT_SECONDS, 0.052 if fraction == 0.5 else 0.028, (-1) ** beat * 0.4)

    def stab(start: float, root: int, gain: float, duration: float = 0.65) -> None:
        time = times(duration)
        shape = envelope(time, 0.006, min(0.22, duration / 3))
        for side, detune in ((-0.65, 0.996), (0.65, 1.004)):
            chord = np.zeros(len(time))
            for interval, weight in ((0, 1), (7, 0.67), (12, 0.5), (15, 0.24)):
                chord += saw(time, note_frequency(root + interval) * detune, 3600) * weight
            chord = taper(filtered(np.tanh(chord * 1.4), 190, 4900) * shape)
            place(chord, start, gain, side)
            place(chord, start + 0.1875, gain * 0.18, -side)
            place(chord, start + 0.375, gain * 0.07, side)

    for index, start in enumerate(np.arange(0, final_hit, BEAT_SECONDS * 2)):
        scene = min(np.searchsorted(transitions, start, side="right"), len(SCENE_ROOTS) - 1)
        if scene == 2 and index % 2:
            continue
        stab(start, SCENE_ROOTS[scene] + 12, 0.145 if start >= final_start else 0.115)
        if scene in (3, 4, 5):
            stab(start + 0.75, SCENE_ROOTS[scene] + 12, 0.064, 0.36)

    def impact(start: float, gain: float) -> None:
        time = times(2.5)
        low = np.sin(2 * np.pi * (37 * time + 32 * (1 - np.exp(-time * 18)) / 18))
        metal = sum(np.sin(2 * np.pi * frequency * time) * weight for frequency, weight in ((311, 0.45), (487, 0.26), (733, 0.13)))
        strike = metal * envelope(time, 0.0007, 0.34)
        strike += noise(time, 300, 7200) * envelope(time, 0.001, 0.13) * 0.27
        place(taper(low * envelope(time, 0.002, 0.25) + strike), start, gain)
        place(taper(strike.copy()), start + 0.057, gain * 0.18, -0.7)
        place(taper(strike.copy()), start + 0.093, gain * 0.14, 0.7)

    impact(0, 0.24)
    for transition in transitions:
        time = times(1)
        rise = noise(time, 900, 6500)
        chirp = np.sin(2 * np.pi * (140 * time + 620 * time ** 3))
        sweep = taper((rise * 0.37 + chirp * 0.17) * time ** 2, 0.007)
        place(sweep, transition - 1, 0.13, -0.35)
        place(sweep, transition - 0.984, 0.10, 0.35)
        impact(transition, 0.34)
        stab(transition, 50, 0.13, 0.9)

    # The call to action lands on a weighty final chord with a short metallic tail.
    impact(final_hit, 0.48)
    stab(final_hit, 50, 0.20, 1.2)
    time = times(1.3)
    final_sub = np.sin(2 * np.pi * note_frequency(26) * time) * envelope(time, 0.004, 0.3)
    place(taper(final_sub), final_hit, 0.33)

    # A gentle beat-synchronous pump leaves room between the dense accents.
    beat_phase = np.mod(timeline, BEAT_SECONDS)
    sidechain = 0.78 + 0.22 * (1 - np.exp(-beat_phase / 0.055))
    mix *= sidechain[:, None]
    for channel in range(2):
        mix[:, channel] = filtered(mix[:, channel], 22, 18000)
    mix = np.tanh(mix * 1.75)
    fade = np.minimum(1, timeline / 0.003) * np.minimum(1, (duration_seconds - timeline) / 0.35)
    mix *= np.clip(fade[:, None], 0, 1)
    peak = float(np.max(np.abs(mix)))
    if peak > 0:
        mix *= 0.87 / peak
    pcm = np.rint(mix * 32767).astype("<i2")
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
