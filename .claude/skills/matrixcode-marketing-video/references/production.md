# Production reference

## Setup from a fresh checkout

Run commands from the MatrixCode repository root. Use an isolated worktree before
editing. Requirements: Node/npm, Python 3.10 or newer, FFmpeg/FFprobe on `PATH`,
and Playwright Chromium with working WebGL2. The script uses ANGLE Metal on macOS;
other platforms need a functioning WebGL2 backend. Arial and Menlo are used on
macOS, with DejaVu fallbacks on Linux. Inspect type layout if fallback fonts differ.

```sh
npm ci
python3 -m venv /Volumes/DATA/Temp/matrixcode-video-venv
source /Volumes/DATA/Temp/matrixcode-video-venv/bin/activate
python3 -m pip install -r .claude/skills/matrixcode-marketing-video/scripts/requirements.txt
python3 -m playwright install chromium
npm run build
```

Install FFmpeg with the available platform package manager if it is missing.
Check imports and `ffmpeg -version` before rendering. Reuse an existing suitable
Python environment instead of reinstalling dependencies each time. A local dev
server is unnecessary: Chromium opens the self-contained `dist/matrixcode.html`.

## Render and preview

Use the prepared Python environment. The repository aliases and the bundled
scripts run the same code. Select an individual film or a group:

```sh
python3 scripts/capture_marketing_video.py --video first
python3 scripts/capture_marketing_video.py --video second
python3 scripts/capture_marketing_video.py --video third
python3 scripts/capture_marketing_video.py --video fourth
python3 scripts/capture_marketing_video.py --video fifth
python3 scripts/capture_marketing_video.py --video sixth
python3 scripts/capture_marketing_video.py --video seventh
python3 scripts/capture_marketing_video.py --video eighth
python3 scripts/capture_marketing_video.py --video both
python3 scripts/capture_marketing_video.py --video new
python3 scripts/capture_marketing_video.py --video styles
python3 scripts/capture_marketing_video.py --video all --preview-only
```

`--video first` is the default, preserving the original no-argument command. Each
recipe produces a 36-second, 1920 × 1080, 30 FPS H.264/AAC MP4 with fast-start
metadata. Every film shares the original nine-second in-rain `Try it now!` reveal.
`both` preserves the first/second selection, `new` selects third/fourth/fifth,
`styles` selects sixth/seventh/eighth, and `all` selects all eight. New captures use a 56-pixel corner URL, a 50-pixel
centered closing headline, and a 66-pixel centered closing URL. Their anchors keep
clear space around the original invitation; existing exports change when regenerated.

| Film | Scenes before the ending | Default MP4 under `output/marketing/` |
| --- | --- | --- |
| `first` | Classic green, blue binary, amber terminal, purple, fine columns, overlap comparison | `matrixcode-styles.mp4` |
| `second` | Red symbols, golden slow motion, monochrome Latin, custom teal, rabbit image reveal, live countdown | `features/matrixcode-features.mp4` |
| `third` | Personalised names, custom phrases, clock, count-up, vertical drop, positioned messages | `words/matrixcode-words.mp4` |
| `fourth` | Typed intros, rain during intro, load ramp, glyph mirroring, density shortcuts, intro skip | `choreography/matrixcode-choreography.mp4` |
| `fifth` | Graded moon, skyline panorama, image scale, placement, brightness fades, image playlist | `images/matrixcode-images.mp4` |
| `sixth` | Six saturated neon looks | `styles/neon/matrixcode-neon.mp4` |
| `seventh` | Six retro phosphor/terminal looks | `styles/phosphor/matrixcode-phosphor.mp4` |
| `eighth` | Six atmospheric/sculptural looks | `styles/atmospheres/matrixcode-atmospheres.mp4` |

The sixth through eighth films are style-only: normal query controls define each
look, body documents keep intros/messages/images disabled, and no timed actions
or comparison demonstrations run. Only the last `INVITATION` scene enables a message.

Each film's directory also contains:

- `matrixcode-poster.jpg`: the fully resolved closing invitation.
- `matrixcode-storyboard.jpg`: all scene previews; the first includes both overlap states.
- `matrixcode-final-frame.jpg`: extracted from the encoded film during verification.

`--preview-only` writes the poster and storyboard without replacing the MP4 or its
encoded final frame; previews may not match an older MP4 until a full render
completes. `--dist DIRECTORY` selects another production build.
`--output-dir DIRECTORY` changes the root while retaining each film's relative
path. `--out PATH.mp4` overrides one film's destination; it is rejected with
film groups (`both`, `new`, `styles`, or `all`). Keep custom destinations in separate directories because the
companion JPEG filenames are shared:

```sh
python3 scripts/capture_marketing_video.py --video both --output-dir output/marketing/review
python3 scripts/capture_marketing_video.py --video new --output-dir output/marketing/review
python3 scripts/capture_marketing_video.py --video styles --output-dir output/marketing/review
python3 scripts/capture_marketing_video.py --video second --out output/marketing/feature-cut/matrixcode-features.mp4
```

`--temp-dir DIRECTORY` chooses scratch storage for lossless clips, audio, and
previews. Its default is `/Volumes/DATA/Temp` when `/Volumes/DATA` exists,
otherwise the platform temporary directory. Scratch files clean up automatically.
Each run prints its unique log path under the output root's `logs/` directory
(beside `--out` when supplied). Noninteractive runs print a concise result and
output paths; failures include an ID and a command to show the relevant log tail.
Interactive runs also announce each film as it starts.

Render to the worktree output, inspect and verify, then copy the finished artifacts
to the user's intended project location. Avoid overwriting a good MP4 with a failed
render. A full render publishes artifacts only after audio/video verification
succeeds. The default output tree, including logs, is ignored by Git; commit the
reusable recipes instead.

If Chromium fails on macOS with `MachPortRendezvousServer ... Permission denied`,
the sandbox blocked its process launch. Use the available tool approval mechanism
to run this local capture outside the sandbox; do not keep retrying identical
blocked launches or claim the video was generated. GPU failures, fallback notices,
unexpected canvas dimensions, console errors, and FFmpeg failures are fatal.

## Change the recipe

Edit the Python sources under this skill's `scripts/` directory:

| Setting/function | Purpose |
| --- | --- |
| `marketing_model.py` | Shared `Film`, `Scene`, capture format, fixed calendar, and original `INVITATION`. |
| `FIRST_FILM`, `SECOND_FILM` in `capture_marketing_video.py` | Original styles and alternate-feature recipes. |
| `marketing_film_third.py`, `marketing_film_fourth.py`, `marketing_film_fifth.py` | Words/tokens, choreography/controls, and image-focused recipes. |
| `marketing_film_sixth.py`, `marketing_film_seventh.py`, `marketing_film_eighth.py` | Pure neon, retro phosphor, and atmospheric style reels. |
| `FILMS`, `FILM_GROUPS` | CLI catalog, output paths, and group selections. |
| `Scene.documents`, `scene_documents` | Isolated app storage for image reveals and countdown/message features. |
| `Scene.preview_seconds` | Representative storyboard time within a scene; the image scene uses four seconds. |
| `Scene.start_images_after_warmup` | Prewarm rain with reveals off, then use the normal Shift+X shortcut to start the image schedule; omit its transient toast from the capture. |
| `Scene.play_intro` | Preserve the real typed intro during recording; use zero preroll to show its entrance. Settings chrome is dismissed with H and its fade is suppressed for clean cold-start frames. |
| `Scene.actions` | Normal keyboard shortcuts at clip-relative times, such as = density or Escape intro skip. Actions run in preview and full capture. |
| `Scene.comparison_settings`, `Scene.comparison_title` | A same-clock second view that changes declared query controls; the fourth film compares readable and mirrored Latin glyphs while rain keeps moving. |
| `Scene.focus_text`, `grade_message` | Improve contrast around existing countdown glyphs using a fixed-width resolved example; the token itself still comes from the app. |
| `BASE_SETTINGS` | Shared capture controls, including disabled adaptive resolution/load ramp. |
| `SIZE`, `FPS`, `TRANSITION` | Frame size, frame rate, and dissolve length. |
| `Film.duration`, `Film.transitions` | Derived from each recipe's scenes and dissolves; keep them derived. |
| `SITE`, `SITE_FONT_SIZE`, `ENDING_TITLE_FONT_SIZE`, `ENDING_SITE_FONT_SIZE`, caption positions | Public URL, typography, centered ending layout, and frame insets. |
| `TITLE_FONT`, `TITLE_BOTTOM_MARGIN` | Scene titles and player clearance. |
| `INVITATION`, `CTA`, `open_scene`, `finish_frame` | Shared in-rain invitation, entrance timing, held brightness, and finishing. |
| `rabbit_mask` | Original silhouette supplied to the real image scheduler as a portable mask. |
| `scene_versions` | A same-settings comparison that changes only overlap. |
| `assemble`, `verify_soundtrack`, `verify_video` | Encoding, dissolves, normalized audio, metadata, duration, stream checks, full decode, and final-frame extraction. |

Choose valid query controls from `src/config/controls.ts`. Useful existing scene
keys are `preset`, `color`, `glyphs`, `font`, `density`, `size`, `glow`, `speed`,
`trail`, `trailvar`, `glyphrate`, `mirror`, `scanlines`, and `overlap`.
Keep enough preroll to fill the rain; the second film's slow-motion scene uses
40 seconds of warmup. The overlap comparison runs both views on the same clock and switches halfway through; its
internal switch is independent of the between-scene dissolves.

All recipes end with the same `INVITATION` scene. Its message geometry comes from
that scene's glyph scale and `CTA`. Reserve `message=True` for this closing scene:
it enables the invitation's upload hook and finishing mask. Other in-rain messages
belong in `Scene.documents["mx-messages"]`, as the countdown scene demonstrates.
Focused row/drop messages follow the document's direction and placement and must
use zero jitter. Their `focus_text` is a resolved fixed-width geometry example;
the app supplies and updates the actual letters. Check every changing token in
early and late encoded samples, since changing glyphs must be claimed by rain.
Image and countdown documents use `mx-images` and `mx-countdown`, with the same
schemas as the ordinary app. The feature scenes are actual scheduled reveals and
tokens, rather than text or images drawn over a capture. `SIZE`, message geometry,
mask, and canvas validation must agree. The default five-second entrance includes
scene warmup, then holds the message through the closing scene. `CLOCK_SCRIPT` advances the normal
app RAF in exact `1000 / FPS` steps and fixes the calendar to an ordinary date so
holiday themes cannot change the intended look. Capture uses isolated storage;
never edit the user's actual browser settings for a film. Controlled timing does
not guarantee identical rain pixels or encoded bytes across machines.

The rabbit uses a grey background and white silhouette, with dense unmirrored
Latin glyphs and restrained bloom so the app's image-dependent letter shapes stay
readable. Its ordinary rain warms up before the image schedule starts, keeping
the reveal entrance visible without cold rows at the bottom of the frame.
The countdown uses twelve seconds of preroll, enough stream coverage and glyph
mutation to resolve its letters, and a message hold that covers preroll plus the
entire shot. Check both an early and a late encoded frame for missing characters.

When changing scene count, order, or duration, verify dissolves do not exceed the
adjacent scenes, and align the music's section roots with the new transitions.
Warmup is not part of the exported duration. Message hold, final plain-green
second, finishing shade, and caption safe areas need review after format changes.

## Change the original score

Edit this skill's `scripts/marketing_audio.py`. NumPy synthesizes all voices; it
does not download music or use external samples. `write_soundtrack` writes seeded,
deterministic, 48 kHz stereo 16-bit PCM for the requested duration and transitions.
Each selected film passes its own derived timings to the same score generator.

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
from capture_marketing_video import SECOND_FILM
from marketing_audio import write_soundtrack
write_soundtrack(Path('/Volumes/DATA/Temp/matrixcode-score-preview.wav'),
                 SECOND_FILM.duration, SECOND_FILM.transitions)
PY
```

Use the same Python environment as the render. The standalone audio CLI also
accepts `OUTPUT.wav --duration SECONDS --transitions ...`; its defaults are for the
first recipe, so pass the selected film's timings. Legacy imports `SCENES`,
`DURATION`, and `TRANSITIONS` still refer to `FIRST_FILM`. Check stereo,
sample rate, duration, clipped PCM samples, attack/tail discontinuities, and fades.
Repeated generation with the same settings should be byte-identical. Compare
perceived loudness when listening to revisions. The WAV peak ceiling is 0.87;
`assemble` targets −14 LUFS, −1.5 dBTP, and LRA 7 before AAC encoding. These are
encoding targets, not guarantees about the decoded AAC's exact measurements.

## Verify the deliverable

Full renders automatically verify the WAV's format, duration, and peak ceiling,
then check the encoded video/audio streams, duration, frame count, and complete
decode. They also extract `matrixcode-final-frame.jpg` before publishing.
Run the recipe and CLI regression checks with the prepared Python environment:

```sh
python3 -m unittest discover -s .claude/skills/matrixcode-marketing-video/scripts -p 'test_*.py'
```

Use each recipe's derived size, duration, and FPS when changing the format.
Inspect the storyboard and encoded final frame rather than trusting the
pre-encoding poster. Confirm the CTA is fully resolved, plain green, and stays
visible through the last frame. The new feature scenes also need visual review:
check that the rabbit resolves clearly and the countdown visibly ticks.
For the third film check names, clock/count-up updates, vertical words, and message
placement. For the fourth check actual typed text, continuous motion across
readable/mirrored glyph views, density changes, and intro skip. For the fifth check image
contrast, scale/placement, fade phases, and distinct masks appearing in the playlist.
For the style-only films inspect every look at small-player width, confirm ongoing
rain motion, and check that no intro/message/image overlays appear before the shared ending.

Check scene frames at the intended smallest player width. A 600-pixel preview of
the title around 1.5 seconds can be extracted with:

```sh
ffmpeg -v error -y -ss 1.5 -i output/marketing/features/matrixcode-features.mp4 -vf scale=600:-2 -frames:v 1 /Volumes/DATA/Temp/matrixcode-player-preview.jpg
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
