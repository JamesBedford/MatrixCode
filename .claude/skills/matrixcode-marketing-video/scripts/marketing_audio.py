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
SCENE_ROOTS = (38, 38, 36, 38, 38, 36, 38)


def note_frequency(midi_note: int) -> float:
    return 440 * 2 ** ((midi_note - 69) / 12)


def write_soundtrack(
    output: Path, duration_seconds: float, transition_seconds: list[float],
    score: str = "industrial",
) -> None:
    """Write deterministic 48 kHz stereo PCM with a driving 120 BPM score."""
    if score == "matrix":
        write_matrix_soundtrack(output, duration_seconds, transition_seconds)
        return
    if score != "industrial":
        raise ValueError(f"Unknown soundtrack {score}")
    if not np.isfinite(duration_seconds) or duration_seconds <= 0:
        raise ValueError("The soundtrack duration must be a positive finite number")
    transitions = sorted({
        float(value) for value in transition_seconds
        if np.isfinite(value) and 0 < value < duration_seconds
    })
    samples = round(duration_seconds * SAMPLE_RATE)
    timeline = np.arange(samples) / SAMPLE_RATE
    mix = np.zeros((samples, 2), dtype=np.float64)
    percussion = np.zeros_like(mix)
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

    def place(
        voice: np.ndarray, start: float, gain: float, pan: float = 0,
        *, percussive: bool = False,
    ) -> None:
        offset = round(start * SAMPLE_RATE)
        first, last = max(0, offset), min(samples, offset + len(voice))
        if first >= last:
            return
        section = voice[first - offset:last - offset] * gain
        angle = (pan + 1) * np.pi / 4
        bus = percussion if percussive else mix
        bus[first:last, 0] += section * np.cos(angle)
        bus[first:last, 1] += section * np.sin(angle)

    def saw(time: np.ndarray, frequency: float, cutoff: float) -> np.ndarray:
        signal = np.zeros(len(time))
        for harmonic in range(1, min(64, int(cutoff / frequency)) + 1):
            # Additive synthesis bounds the spectrum before controlled saturation.
            weight = np.exp(-(harmonic * frequency / cutoff) ** 2) / harmonic
            signal += weight * np.sin(2 * np.pi * harmonic * frequency * time)
        return signal * 0.64

    def scene_at(seconds: float) -> int:
        return min(int(np.searchsorted(transitions, seconds, side="right")),
                   len(SCENE_ROOTS) - 1)

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
        scene = scene_at(start)
        note = BASS_RIFF[step % len(BASS_RIFF)]
        if note is None:
            continue
        accented = step % 4 == 0
        note += SCENE_ROOTS[scene] - SCENE_ROOTS[0]
        place(bass(note, accented, scene), start, 0.23 if accented else 0.18)

    for beat, start in enumerate(np.arange(0, final_hit, BEAT_SECONDS)):
        scene = scene_at(start)
        time = times(0.43)
        phase = 2 * np.pi * (47 * time + 112 * (1 - np.exp(-time * 45)) / 45)
        kick = np.sin(phase) * envelope(time, 0.0007, 0.105)
        click = noise(time, 1800, 6800) * np.exp(-time / 0.004)
        place(taper(np.tanh(kick * 1.45) * 0.85 + 0.08 * click), start, 0.40,
              percussive=True)
        if beat % 2 == 1:
            time = times(0.31)
            body = np.sin(2 * np.pi * 184 * time) + 0.25 * np.sin(2 * np.pi * 329 * time)
            snap = noise(time, 650, 7500) * envelope(time, 0.0006, 0.064)
            clap = noise(time, 1100, 5100)
            clap *= sum(np.exp(-np.maximum(0, time - tap) / 0.031) * (time >= tap) for tap in (0, 0.009, 0.019)) / 3
            snare = 0.54 * body * envelope(time, 0.001, 0.04) + 0.5 * snap + 0.19 * clap
            place(taper(snare), start, 0.38, percussive=True)
            place(taper(snap.copy()), start + 0.018, 0.035, 0.55, percussive=True)
            if scene >= 3 and beat % 4 == 3 and start + BEAT_SECONDS * 0.75 < final_hit:
                place(taper(snare.copy()), start + BEAT_SECONDS * 0.75,
                      0.045, -0.25, percussive=True)
        # Offbeat open hats and alternating sixteenths supply momentum.
        for fraction in (0.25, 0.5, 0.75):
            if fraction != 0.5 and scene in (0, 2):
                continue
            time = times(0.16 if fraction == 0.5 else 0.075)
            hat = noise(time, 4800, 10500) * envelope(time, 0.0005, 0.036 if fraction == 0.5 else 0.012)
            gain = 0.048 if fraction == 0.5 else 0.022 + 0.004 * (beat % 2)
            place(taper(hat), start + fraction * BEAT_SECONDS, gain,
                  (-1) ** beat * 0.4, percussive=True)

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
        scene = scene_at(start)
        if scene == 2 and index % 2:
            continue
        stab(start, SCENE_ROOTS[scene] + 12, 0.145 if start >= final_start else 0.115)
        if scene >= 3:
            stab(start + 0.75, SCENE_ROOTS[scene] + 12, 0.064, 0.36)

    def impact(start: float, gain: float) -> None:
        time = times(2.5)
        low = np.sin(2 * np.pi * (37 * time + 32 * (1 - np.exp(-time * 18)) / 18))
        metal = sum(np.sin(2 * np.pi * frequency * time) * weight for frequency, weight in ((311, 0.45), (487, 0.26), (733, 0.13)))
        strike = metal * envelope(time, 0.0007, 0.34)
        strike += noise(time, 300, 7200) * envelope(time, 0.001, 0.13) * 0.27
        place(taper(low * envelope(time, 0.002, 0.25) + strike), start, gain,
              percussive=True)
        place(taper(strike.copy()), start + 0.057, gain * 0.18, -0.7, percussive=True)
        place(taper(strike.copy()), start + 0.093, gain * 0.14, 0.7, percussive=True)

    def transition_fill(transition: float) -> None:
        """Lead into the scene's downbeat with three short, descending drum hits."""
        for index, frequency in enumerate((155, 110, 80)):
            time = times(0.20)
            phase = 2 * np.pi * frequency * (time + 0.006 * (1 - np.exp(-time * 75)))
            body = np.sin(phase) * envelope(time, 0.0008, 0.055 + index * 0.012)
            metal = (np.sin(2 * np.pi * frequency * 2.73 * time)
                     + 0.4 * np.sin(2 * np.pi * frequency * 4.17 * time))
            metal *= envelope(time, 0.0006, 0.027)
            attack = noise(time, 1600, 5200) * envelope(time, 0.0004, 0.006)
            drum = taper(np.tanh(body * 1.6) + metal * 0.12 + attack * 0.07)
            place(drum, transition - (3 - index) * BEAT_SECONDS / 4,
                  0.14 + index * 0.045, (index - 1) * 0.25, percussive=True)

    impact(0, 0.24)
    for transition in transitions:
        transition_fill(transition)
        impact(transition, 0.34)
        stab(transition, SCENE_ROOTS[scene_at(transition)] + 12, 0.13, 0.9)

    # The call to action lands on a weighty final chord with a short metallic tail.
    impact(final_hit, 0.48)
    stab(final_hit, 50, 0.20, 1.2)
    time = times(1.3)
    final_sub = np.sin(2 * np.pi * note_frequency(26) * time) * envelope(time, 0.004, 0.3)
    place(taper(final_sub), final_hit, 0.33)

    # Duck the music around the kick while preserving percussion transients.
    beat_phase = np.mod(timeline, BEAT_SECONDS)
    sidechain = 0.78 + 0.22 * (1 - np.exp(-beat_phase / 0.055))
    mix *= sidechain[:, None]
    mix += percussion
    for channel in range(2):
        mix[:, channel] = filtered(mix[:, channel], 22, 18000)
    mix = np.tanh(mix * 1.45)
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


def write_matrix_soundtrack(
    output: Path, duration_seconds: float, transition_seconds: list[float],
) -> None:
    """Dark, driving original score for the looping promo.

    120 BPM puts a kick on every beat. A film whose length is a whole number of
    beats joins the loop on a kick. Drums run through the last beat. A short
    fade only removes the click at the join.
    """
    if not np.isfinite(duration_seconds) or duration_seconds <= 0:
        raise ValueError("The soundtrack duration must be a positive finite number")
    transitions = sorted({
        float(value) for value in transition_seconds
        if np.isfinite(value) and 0 < value < duration_seconds
    })
    roots = (38, 36, 34, 38, 41, 36, 38)  # D minor family, opening and close on D
    samples = round(duration_seconds * SAMPLE_RATE)
    timeline = np.arange(samples) / SAMPLE_RATE
    mix = np.zeros((samples, 2), dtype=np.float64)
    percussion = np.zeros_like(mix)
    random = np.random.default_rng(0x4D415458)

    def times(seconds: float) -> np.ndarray:
        return np.arange(max(1, round(seconds * SAMPLE_RATE))) / SAMPLE_RATE

    def envelope(time: np.ndarray, attack: float, decay: float) -> np.ndarray:
        return (1 - np.exp(-time / attack)) * np.exp(-time / decay)

    def taper(voice: np.ndarray, seconds: float = 0.012) -> np.ndarray:
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

    def place(
        voice: np.ndarray, start: float, gain: float, pan: float = 0,
        *, percussive: bool = False,
    ) -> None:
        offset = round(start * SAMPLE_RATE)
        first, last = max(0, offset), min(samples, offset + len(voice))
        if first >= last:
            return
        section = voice[first - offset:last - offset] * gain
        angle = (pan + 1) * np.pi / 4
        bus = percussion if percussive else mix
        bus[first:last, 0] += section * np.cos(angle)
        bus[first:last, 1] += section * np.sin(angle)

    def saw(time: np.ndarray, frequency: float, cutoff: float) -> np.ndarray:
        signal = np.zeros(len(time))
        limit = min(48, int(cutoff / max(frequency, 1)))
        for harmonic in range(1, limit + 1):
            weight = np.exp(-(harmonic * frequency / cutoff) ** 2) / harmonic
            signal += weight * np.sin(2 * np.pi * harmonic * frequency * time)
        return signal * 0.7

    def scene_at(seconds: float) -> int:
        return min(int(np.searchsorted(transitions, seconds, side="right")), len(roots) - 1)

    def kick() -> np.ndarray:
        time = times(0.42)
        frequency = 46 + 170 * np.exp(-time * 32)
        phase = 2 * np.pi * np.cumsum(frequency) / SAMPLE_RATE
        body = np.sin(phase) * envelope(time, 0.0006, 0.13)
        click = noise(time, 1400, 7000) * np.exp(-time / 0.0035)
        return taper(np.tanh(body * 2.4) + 0.16 * click)

    def snare() -> np.ndarray:
        time = times(0.28)
        body = np.sin(2 * np.pi * 188 * time) * envelope(time, 0.001, 0.045)
        snap = noise(time, 700, 8000) * envelope(time, 0.0005, 0.05)
        clap = noise(time, 1200, 5000)
        clap *= sum(np.exp(-np.maximum(0, time - tap) / 0.028) * (time >= tap)
                    for tap in (0, 0.008, 0.017)) / 3
        return taper(np.tanh(body * 1.8) * 0.55 + snap * 0.62 + clap * 0.22)

    def hat(opened: bool) -> np.ndarray:
        time = times(0.14 if opened else 0.045)
        burst = noise(time, 5500, 14000) * envelope(time, 0.0004, 0.03 if opened else 0.01)
        return taper(burst)

    def bass(note: int, accented: bool) -> np.ndarray:
        time = times(0.2 if accented else 0.16)
        frequency = note_frequency(note)
        tone = saw(time, frequency, 1600)
        grit = np.tanh(tone * 5.2)
        sub = np.sin(2 * np.pi * frequency / 2 * time)
        body = envelope(time, 0.002, 0.1 if accented else 0.065)
        return taper(filtered(grit, 55, 2200) * body + sub * body * 0.85)

    def stab(start: float, root: int, gain: float) -> None:
        time = times(0.28)
        shape = envelope(time, 0.004, 0.07)
        for side, detune in ((-0.72, 0.994), (0.72, 1.006)):
            chord = np.zeros(len(time))
            for interval, weight in ((0, 1), (3, 0.85), (7, 0.62), (10, 0.38), (13, 0.16)):
                chord += saw(time, note_frequency(root + interval) * detune, 3200) * weight
            # A close second voice thickens the stab without becoming a second chord.
            chord += saw(time, note_frequency(root + 1) * detune, 2400) * 0.12
            voice = taper(filtered(np.tanh(chord * 1.7), 180, 5200) * shape)
            place(voice, start, gain, side)

    # Eighth-note minor riff. It restarts on D at the loop point.
    riff = (0, 0, -2, 0, 3, -2, 0, -5)
    eighth = BEAT_SECONDS / 2
    for step, start in enumerate(np.arange(0, duration_seconds, eighth)):
        note = riff[step % len(riff)]
        root = roots[scene_at(float(start))]
        accented = step % 4 == 0
        place(bass(root + note, accented), float(start), 0.26 if accented else 0.18)

    kick_voice = kick()
    snare_voice = snare()
    closed_hat = hat(False)
    open_hat = hat(True)
    for beat, start in enumerate(np.arange(0, duration_seconds, BEAT_SECONDS)):
        place(kick_voice, float(start), 0.5, percussive=True)
        if beat % 2 == 1:
            place(snare_voice, float(start), 0.42, percussive=True)
            place(snare_voice, float(start) + 0.016, 0.05, 0.45, percussive=True)
        for fraction, opened, gain, pan in (
            (0.25, False, 0.028, -0.35),
            (0.5, True, 0.055, 0.15),
            (0.75, False, 0.024, 0.4),
        ):
            place(open_hat if opened else closed_hat, float(start) + fraction * BEAT_SECONDS,
                  gain, pan * ((-1) ** beat), percussive=True)

    for index, start in enumerate(np.arange(0, duration_seconds, BEAT_SECONDS * 2)):
        root = roots[scene_at(float(start))]
        stab(float(start), root + 12, 0.15)
        if index % 2 == 1:
            stab(float(start) + BEAT_SECONDS, root + 12, 0.06)

    def impact(start: float, gain: float) -> None:
        time = times(1.6)
        low = np.sin(2 * np.pi * (34 * time + 28 * (1 - np.exp(-time * 16)) / 16))
        metal = sum(np.sin(2 * np.pi * frequency * time) * weight
                    for frequency, weight in ((294, 0.4), (440, 0.22), (698, 0.1)))
        strike = metal * envelope(time, 0.0006, 0.22)
        strike += noise(time, 250, 6400) * envelope(time, 0.0008, 0.08) * 0.3
        place(taper(low * envelope(time, 0.002, 0.22) + strike), start, gain, percussive=True)

    def transition_fill(transition: float) -> None:
        for index, frequency in enumerate((148, 104, 74)):
            time = times(0.16)
            phase = 2 * np.pi * frequency * (time + 0.005 * (1 - np.exp(-time * 70)))
            body = np.sin(phase) * envelope(time, 0.0007, 0.05 + index * 0.01)
            attack = noise(time, 1500, 4800) * envelope(time, 0.0004, 0.005)
            drum = taper(np.tanh(body * 1.8) + attack * 0.08)
            place(drum, transition - (3 - index) * BEAT_SECONDS / 4,
                  0.16 + index * 0.04, (index - 1) * 0.3, percussive=True)

    impact(0, 0.34)
    for transition in transitions:
        transition_fill(transition)
        impact(transition, 0.3)
        stab(transition, roots[scene_at(transition)] + 12, 0.12)

    beat_phase = np.mod(timeline, BEAT_SECONDS)
    sidechain = 0.7 + 0.3 * (1 - np.exp(-beat_phase / 0.045))
    mix *= sidechain[:, None]
    mix += percussion
    for channel in range(2):
        mix[:, channel] = filtered(mix[:, channel], 28, 16000)
    mix = np.tanh(mix * 1.25)
    fade = 0.012
    edges = np.minimum(1, timeline / fade) * np.minimum(1, (duration_seconds - timeline) / fade)
    mix *= np.clip(edges[:, None], 0, 1)
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
    parser.add_argument("--duration", type=float, default=36)
    parser.add_argument("--transitions", type=float, nargs="*", default=[5, 9, 13, 17, 21, 27])
    parser.add_argument("--score", choices=("industrial", "matrix"), default="industrial")
    arguments = parser.parse_args()
    write_soundtrack(arguments.output, arguments.duration, arguments.transitions,
                     score=arguments.score)
