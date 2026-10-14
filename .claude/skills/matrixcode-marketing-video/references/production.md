# Production reference

## Setup from a fresh checkout

Run commands from the MatrixCode repository root. Use an isolated worktree before
editing. Requirements: Node/npm, Python 3.10 or newer, FFmpeg/FFprobe on `PATH`,
and Playwright Chromium with working WebGL2. The script uses ANGLE Metal on macOS;
other platforms need a functioning WebGL2 backend. Arial and Menlo are used on
macOS, with DejaVu fallbacks on Linux. Inspect type layout if fallback fonts differ.

```sh
npm ci
python3 -m venv /tmp/matrixcode-video-venv
/tmp/matrixcode-video-venv/bin/python -m pip install -r .claude/skills/matrixcode-marketing-video/scripts/requirements.txt
/tmp/matrixcode-video-venv/bin/python -m playwright install chromium
npm run build
```

Install FFmpeg with the available platform package manager if it is missing.
Check imports and `ffmpeg -version` before rendering. Reuse an existing suitable
Python environment instead of reinstalling dependencies each time. A local dev
server is unnecessary: Chromium opens the self-contained `dist/matrixcode.html`.

## Render and preview

The repository aliases and the bundled scripts run the same code:

```sh
/tmp/matrixcode-video-venv/bin/python .claude/skills/matrixcode-marketing-video/scripts/capture_marketing_video.py --preview-only
/tmp/matrixcode-video-venv/bin/python .claude/skills/matrixcode-marketing-video/scripts/capture_marketing_video.py
```

The current recipe produces a 36-second, 1920 × 1080, 30 FPS H.264/AAC MP4.
Defaults under `output/marketing/`:

- `matrixcode-styles.mp4`: the finished film, with fast-start metadata.
- `matrixcode-poster.jpg`: the fully resolved closing invitation.
- `matrixcode-storyboard.jpg`: all scene previews, including both overlap states.
- `matrixcode-final-frame.jpg`: extract from the encoded film during verification.

`--preview-only` writes JPEG previews without replacing the MP4; these may not
correspond to the current MP4 until a full render completes. Use `--dist DIRECTORY`
for another production build, and `--out PATH.mp4` to choose a destination. For a
distinct film, use its own output directory so its poster and storyboard do not
overwrite those of another film, for example:

```sh
/tmp/matrixcode-video-venv/bin/python scripts/capture_marketing_video.py --out output/marketing/short/matrixcode-short.mp4
```

Render to the worktree output, inspect and verify, then copy the finished artifacts
to the user's intended project location. Avoid overwriting a good MP4 with a failed
render. The MP4 and previews are ignored by Git; commit the reusable recipe instead.

If Chromium fails on macOS with `MachPortRendezvousServer ... Permission denied`,
the sandbox blocked its process launch. Use the available tool approval mechanism
to run this local capture outside the sandbox; do not keep retrying identical
blocked launches or claim the video was generated. GPU failures, fallback notices,
unexpected canvas dimensions, console errors, and FFmpeg failures are fatal.

## Change the recipe

Edit `scripts/capture_marketing_video.py` **inside this skill**:

| Setting/function | Purpose |
| --- | --- |
| `SCENES`, `Scene` | Scene order, titles, durations, warmup, controls, and special behaviors. |
| `BASE_SETTINGS` | Shared capture controls, including disabled adaptive resolution/load ramp. |
| `SIZE`, `FPS`, `TRANSITION` | Frame size, frame rate, and dissolve length. |
| `DURATION`, `TRANSITIONS` | Derived from scenes and dissolves; keep them derived. |
| `SITE`, `SITE_FONT`, `TITLE_FONT`, `TITLE_BOTTOM_MARGIN` | Public URL, corner type, scene type, and player clearance. |
| `CTA`, `open_scene`, `finish_frame` | In-rain invitation, entrance timing, held brightness, and finishing. |
| `scene_versions` | A same-settings comparison that changes only overlap. |
| `assemble` | Encoding, dissolves, normalized audio, metadata, and final duration. |

Choose valid query controls from `src/config/controls.ts`. Useful existing scene
keys are `preset`, `glyphs`, `font`, `density`, `size`, `glow`, `speed`, `trail`,
`scanlines`, and `overlap`. Keep enough preroll to fill the rain. The overlap
comparison runs both views on the same clock and switches halfway through; its
internal switch is independent of the between-scene dissolves.

The current message geometry comes from `SCENES[-1]`, `CTA`, and its glyph scale.
Keep the invitation as the last scene with `message=True`; if adding multiple
message scenes or changing that relationship, update `message_layout`, the upload
hook, and the finishing mask together. `SIZE`, message geometry, mask, and canvas
validation must agree. The default five-second entrance includes scene warmup, then
holds the message through the closing scene. `CLOCK_SCRIPT` advances the normal
app RAF in exact `1000 / FPS` steps and fixes the calendar to an ordinary date so
holiday themes cannot change the intended look. Capture uses isolated storage;
never edit the user's actual browser settings for a film. Controlled timing does
not guarantee identical rain pixels or encoded bytes across machines.

When changing scene count, order, or duration, verify dissolves do not exceed the
adjacent scenes, and align the music's section roots with the new transitions.
Warmup is not part of the exported duration. Message hold, final plain-green
second, finishing shade, and caption safe areas need review after format changes.

## Change the original score

Edit this skill's `scripts/marketing_audio.py`. NumPy synthesizes all voices; it
does not download music or use external samples. `write_soundtrack` writes seeded,
deterministic, 48 kHz stereo 16-bit PCM for the requested duration and transitions.

`BASS_RIFF`, `SCENE_ROOTS`, and `BEAT_SECONDS` control musical identity. Current
tempo is 120 BPM. Bass/synths route through `mix`; drum hits and impacts route
through `percussion` so the kick-synchronous music ducking does not dull their
attacks. `transition_fill` supplies three short descending tom/metal hits before
each scene; `impact` accents its downbeat. Transition stabs follow the section root.
The closing hit lands one second before the end, followed by a short tail and fade.

Generate an audio-only preview before spending time on a new full film:

```sh
python3 - <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, '.claude/skills/matrixcode-marketing-video/scripts')
from capture_marketing_video import DURATION, TRANSITIONS
from marketing_audio import write_soundtrack
write_soundtrack(Path('/tmp/matrixcode-score-preview.wav'), DURATION, TRANSITIONS)
PY
```

Use the same Python environment as the render. The standalone audio CLI also
accepts `OUTPUT.wav --duration SECONDS --transitions ...`; its defaults are for the
current recipe, so pass updated timings when making a different film. Check stereo,
sample rate, duration, clipped PCM samples, attack/tail discontinuities, and fades.
Repeated generation with the same settings should be byte-identical. Compare
perceived loudness when listening to revisions. The WAV peak ceiling is 0.87;
`assemble` targets −14 LUFS, −1.5 dBTP, and LRA 7 before AAC encoding. These are
encoding targets, not guarantees about the decoded AAC's exact measurements.

## Verify the deliverable

Use the recipe's current derived size, duration, and FPS rather than assuming the
original values for a new film:

```sh
ffprobe -v error -show_streams -show_format output/marketing/matrixcode-styles.mp4
ffmpeg -v error -i output/marketing/matrixcode-styles.mp4 -f null -
ffmpeg -v error -y -sseof -0.034 -i output/marketing/matrixcode-styles.mp4 -frames:v 1 -q:v 2 output/marketing/matrixcode-final-frame.jpg
```

For the current 30 FPS film, `-sseof -0.034` selects a frame near the end. For a
different FPS, use a seek offset slightly longer than one frame. Inspect the
encoded final frame rather than trusting a pre-encoding poster. Confirm the CTA
is fully resolved, plain green, and stays visible through the last frame.

Check scene frames at the intended smallest player width. A 600-pixel preview of
the title around 1.5 seconds can be extracted with:

```sh
ffmpeg -v error -y -ss 1.5 -i output/marketing/matrixcode-styles.mp4 -vf scale=600:-2 -frames:v 1 /tmp/matrixcode-player-preview.jpg
```

Inspect readability and the area where X's timer and playback controls sit. In
the current recipe, even the title's entrance retains a 182-pixel native bottom
margin (about 57 pixels at a 600-pixel player width). This is a tested layout
allowance, not a claim that every host uses identical controls. The final centered
scene has separate positioning. Ensure each scene fits without clipping, the
overlap comparison has no cold-start gap, and there are no fallback/settings UI.
Watch/listen to the finished film where available; a successful decode alone does
not verify aesthetics. If only numerical audio checks are available, say so.

## Cleanup and handoff

Keep the latest finished MP4 and its poster, storyboard, and encoded final frame.
Remove superseded numbered versions of the same film after validating replacement;
preserve distinct films and archives the user still wants. Remove temporary
audio/player-preview files created by this task. `TemporaryDirectory` already
removes intermediate raw clips, scene JPEGs, and WAV score even on exceptions.
Do not sweep unrelated worktrees, dependencies, release artifacts, or personal
files into cleanup. Merge verified source changes using the project instructions,
remove the completed worktree/branch, and return the video link.
