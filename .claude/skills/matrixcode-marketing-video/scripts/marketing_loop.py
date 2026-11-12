"""Frame-exact circular finishing for a continuous real-app capture."""

import io
import json
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image

from marketing_model import FPS, Film


def loop_filter(film: Film) -> str:
    """Wrap via a smooth overlap; the file boundary remains an ordinary frame step.

    For a 30s film and 2s overlap, capture 32s. Keep source frames 60..899,
    then blend 900..959 into 0..59. The wrap is source59 -> source60.
    """
    overlap = round(film.loop_overlap * FPS)
    count = round(film.duration * FPS)
    # blend's N is one-based. Both endpoints are exact, with zero slope.
    phase = f"clip((N-1)/{overlap - 1},0,1)"
    weight = f"({phase}*{phase}*(3-2*{phase}))"
    return ";".join([
        "[0:v]split=3[body][tail][head]",
        f"[body]trim=start_frame={overlap}:end_frame={count},setpts=PTS-STARTPTS[main]",
        f"[tail]trim=start_frame={count}:end_frame={count + overlap},setpts=PTS-STARTPTS[end]",
        f"[head]trim=end_frame={overlap},setpts=PTS-STARTPTS[start]",
        f"[end][start]blend=all_expr='A*(1-{weight})+B*{weight}'[join]",
        "[main][join]concat=n=2:v=1:a=0[loop]",
    ])


def verify_loop(output: Path, film: Film, report: Path, storyboard: Path):
    """Check decoded motion through the wrap and retain representative encoded frames."""
    count = round(film.duration * FPS)
    sample_count = min(FPS, count // 2)
    decoded = subprocess.run([
        "ffmpeg", "-v", "error", "-i", str(output), "-vf",
        f"select='lt(n,{sample_count})+gte(n,{count - sample_count})',scale=480:270,format=gray",
        "-fps_mode", "passthrough", "-f", "rawvideo", "pipe:1",
    ], check=True, capture_output=True)
    frames = np.frombuffer(decoded.stdout, dtype=np.uint8)
    if frames.size != 2 * sample_count * 480 * 270:
        raise RuntimeError("Could not decode both sides of the loop boundary")
    frames = frames.reshape(-1, 270, 480).astype(np.float32)
    differences = np.abs(np.diff(frames, axis=0)).mean(axis=(1, 2))
    # The middle pair skips most of the film and is not a consecutive-frame sample.
    ordinary = np.delete(differences, sample_count - 1)
    seam = float(np.abs(frames[-1] - frames[0]).mean())
    typical = float(np.median(ordinary))
    upper = float(np.percentile(ordinary, 95))
    if typical < 0.05 or seam < 0.05:
        raise RuntimeError("Loop boundary or neighboring rain frames are static")
    if seam > upper * 1.5 + 0.25:
        raise RuntimeError(f"Loop boundary jumps: {seam:.3f}, ordinary 95th percentile {upper:.3f}")
    report.write_text(json.dumps({
        "duration_seconds": film.duration, "frames": count, "fps": FPS,
        "audio_streams": int(film.score is not None),
        "overlays": any(scene.overlays for scene in film.scenes),
        "overlap_seconds": film.loop_overlap,
        "boundary_mean_absolute_difference": seam,
        "ordinary_median_difference": typical, "ordinary_95th_percentile_difference": upper,
        "comparison_size": [480, 270],
    }, indent=2) + "\n")
    times = (0, film.duration / 4, film.duration / 2, film.duration * 3 / 4,
             film.duration - film.loop_overlap / 2, (count - 1) / FPS)
    sheet = Image.new("RGB", (1440, 540))
    for index, seconds in enumerate(times):
        still = subprocess.run([
            "ffmpeg", "-v", "error", "-ss", str(seconds), "-i", str(output),
            "-frames:v", "1", "-vf", "scale=480:270", "-f", "image2pipe", "-vcodec", "png", "pipe:1",
        ], check=True, capture_output=True)
        with Image.open(io.BytesIO(still.stdout)) as image:
            sheet.paste(image, ((index % 3) * 480, (index // 3) * 270))
    sheet.save(storyboard, quality=93, subsampling=0)
    print(f"Loop verified: boundary motion {seam:.3f}, ordinary median {typical:.3f}, p95 {upper:.3f}")
