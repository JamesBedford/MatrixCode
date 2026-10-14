# Matrix Code marketing video

`scripts/capture_marketing_video.py` creates a 40-second, 1920 × 1080,
30 fps landscape video from the actual production WebGL app. It starts with
classic green, shows blue binary, amber terminal digits, purple katakana, and
monochrome symbols, then adds a green style with many more columns and a full-screen
comparison of non-overlapping and overlapping rain. It returns to green with
**Try it now!** revealed by the app's own in-rain message scheduler. The invitation
starts dissolving into flickering glyphs in roughly the final two seconds. The
final scene includes the public app URL.

The video includes style names, half-second dissolves, and an original
industrial electronic soundtrack synthesized by `scripts/marketing_audio.py`,
with distorted bass, punchy drums, tense synths, and transition impacts. No external
music, footage, or generated rain visuals are used. The ending applies a finishing
brightness grade to the app's existing message glyphs while dimming the surrounding
rain; the invitation is not drawn as a separate text overlay. Scene settings use
ordinary app controls and live in the capture script.

The extra-column style uses smaller glyphs and higher density. The overlap
comparison keeps its settings identical and switches from overlap off to on
halfway through, using two warmed views running on the same capture clock.

The style scenes use only their main titles, with no supporting subtitles,
numbered chapter labels, navigation dots, or a top-left logo. The closing line reads
**Your Matrix Code. Your style.** above the invitation.

## Render

Install FFmpeg, Python Playwright, Pillow, and NumPy, plus Playwright Chromium:

```sh
python3 -m pip install playwright pillow numpy
python3 -m playwright install chromium
npm run build
python3 scripts/capture_marketing_video.py --preview-only
python3 scripts/capture_marketing_video.py
```

The default output directory is `output/marketing/`, ignored by Git:

- `matrixcode-styles.mp4`: H.264/AAC video with web-streaming fast start.
- `matrixcode-poster.jpg`: a frame of the final invitation.
- `matrixcode-storyboard.jpg`: nine previews, including both overlap states.

Use `--dist DIRECTORY` for another production build and `--out PATH.mp4` to choose
the video destination. Capture clips and the WAV score are temporary and removed
after encoding. The script opens the self-contained build directly; no dev server
or network connection is needed.

## Capture and verification

Each scene gets a fresh, isolated Chromium context. Capture advances the app's
normal animation loop in exact 1/30-second increments, disables adaptive resolution,
and fixes the calendar to an ordinary date so holiday overrides cannot change the
selected styles. Intro, message, and UI state affect only these throwaway contexts.
The script fails on page errors, a compatibility fallback, visible settings, an
incorrect canvas size, or failed encoding. macOS uses GPU-backed ANGLE Metal;
other systems need a working WebGL2 implementation.

Review the storyboard, decoded transition frames, and final frame after rendering.
FFprobe should report 1920 × 1080, 30 fps, 1200 video frames, a 40-second duration,
and a stereo 48 kHz audio stream. Decode the complete MP4 to check for stream errors:

```sh
ffprobe -v error -show_streams -show_format output/marketing/matrixcode-styles.mp4
ffmpeg -v error -i output/marketing/matrixcode-styles.mp4 -f null -
```

This workflow adds marketing assets only and does not change rendering or behavior
in the web or native applications.
