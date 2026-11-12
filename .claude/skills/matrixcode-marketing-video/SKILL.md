---
name: matrixcode-marketing-video
description: Create, regenerate, or revise MatrixCode marketing videos from the real WebGL app, including scene styling, captions, an original synthesized soundtrack, and exports for social posting.
---

# MatrixCode marketing video

Produce a finished MP4 from this project's production app. Keep the capture,
soundtrack, and dependencies in this skill's `scripts/` directory; the repository's
`scripts/capture_marketing_video.py` and `scripts/marketing_audio.py` are compatibility
symlinks to these same sources. Claude discovers this folder directly, and Codex
discovers it through the project's `.agents/skills` symlink.

## Choose the work

- **Classic silent loop:** `--video classic-loop` renders 30 seconds of the real
  app's classic green rain at 1920 × 1080, 30 FPS, with the usual top-right URL.
  No audio stream, scene titles, intros, messages, or image reveals. Output is
  `output/marketing/loops/classic-green/matrixcode-classic-green-loop.mp4`.
  A smooth two-second tail/opening overlap closes the loop while the file boundary
  retains consecutive source frames. This recipe has no closing invitation.
- **Purple silent loop:** `--video purple-loop` is the same 30-second seamless
  capture with the purple preset and matrix glyphs. Output is
  `output/marketing/loops/purple-matrix/matrixcode-purple-matrix-loop.mp4`.
  It keeps the corner URL and omits audio, titles, intros, messages, and image reveals.
- **Recreate a film:** build the app and select `--video first` (the default),
  `second`, `third`, `fourth`, `fifth`, `sixth`, `seventh`, or `eighth`. Groups:
  `both` selects the first two, `new` selects the third through fifth, `styles`
  selects the sixth through eighth, and `all` selects every long film. The additional
  style reels cover neon, retro phosphor, and atmospheric rain looks.
- **Short social cuts:** `--video shorts` renders sixty 6–10 second clips, and
  `--video 01-classic-green` (any short slug) renders one. Each opens on a
  long-film picture, with that scene's density, size, speed, trail, and glow.
  Each short's name uses the long-film lower-left title. `browser`,
  `screensaver`, and `both monitors` stay at the top left. Output goes to
  `output/marketing/shorts/<slug>/`.
  The eight 36-second films stay the long tour for your own post and are not
  shortened or replaced by this mode.
- **Feature showcases:** `--video showcase` renders four 8–12 second films, and
  `--video showcase-story` (or `showcase-picture`, `showcase-countdown`,
  `showcase-light`) renders one. Each opens on rain that is already full, puts one
  outcome caption at the top, and writes `output/marketing/showcase/<key>/`.
  These demonstrate a name, a picture, a countdown, and the still grid. They do
  not replace the colour shorts or the long tours.
- **Update a film:** edit the scene, caption, capture, or soundtrack settings that
  implement the request, then regenerate the actual MP4 and preview images.
- **Looping quote reel:** `--video quotes` renders one 41-second film that
  opens and closes on `Try it now!` so the picture can loop. The opening line
  and each quote resolve out of the rain the way the closing invitation does.
  The poster's @handle sits on the next row. This film does not burn style
  names into the lower left. Output is
  `output/marketing/quotes/matrixcode-quotes.mp4`. Its score is the original
  `matrix` arrangement, not the shared industrial score and not music from The Matrix.
- **Make a new film:** use the `Film` and `Scene` definitions in `marketing_model.py` as the starting
  recipe. Choose the audience, scenes, copy, duration, and destination from the
  request. Reuse `INVITATION` when the established ending is requested.

Read [references/production.md](references/production.md) for setup, commands,
capture mechanics, editing points, verification, and cleanup. The bundled
`scripts/requirements.txt` lists the Python dependencies. Node dependencies and
the app itself come from the enclosing MatrixCode checkout.

## Production constraints

- Capture the actual app with normal query controls. Make marketing edits in the
  capture/finishing pipeline; renderer or simulation changes follow the project's
  cross-platform parity workflow.
- Style-only reels use query controls for each look and keep body-scene intros,
  image reveals, messages, actions, and comparison demos disabled. Reserve the
  in-rain message for the shared closing invitation. Name the looks in captions.
- Preserve the current film's preferences unless the user changes them: style
  titles and a readable corner URL, no extra scene subtitles or navigation labels,
  a closing in-rain `Try it now!` reveal, and the final URL. The removed
  `Web app and screen savers` caption stays removed.
- The default score is original synthesized industrial electronic music. Keep its
  driving bass and beat, use descending percussion fills instead of transition
  swooshes, and preserve clear drum attacks. External music or samples are optional
  only when requested and usable for the intended distribution.
- Social captions must work without sound. Keep ordinary scene titles above player
  controls: the current 1080p recipes use a 200-pixel bottom margin and a 56-pixel
  top-right URL. The centered closing headline and URL use 50 and 66 pixels.
  Inspect downscaled frames and preserve clear gaps around the invitation when changing copy, size, or placement.
  A different format needs its own checked safe area.
- The closing invitation uses the app's message scheduler and existing glyphs.
  Its final second settles to plain green letters without head highlights while
  ambient rain continues. All recipes share the same `INVITATION` scene and
  finishing. Do not replace it with separately drawn CTA text unless the user
  explicitly requests a different presentation. Feature-scene storage documents
  belong in `Scene.documents`; reserve `message=True` for the closing invitation.

## Finish the requested deliverable

Use the project's worktree and integration instructions. Render in the worktree
and verify before replacing the primary output. Check the storyboard, a frame at
the smallest intended player width, and the encoded final frame; decode the whole
MP4 and verify its streams against the recipe's derived size, FPS, and duration.
For soundtrack changes, check the generated WAV for clipping and listen when audio
preview is available; numerical checks do not establish subjective sound quality.

Keep the final MP4, poster, storyboard, and final-frame image together. The first
film defaults to `output/marketing/matrixcode-styles.mp4`; the others and their
companions use `features/`, `words/`, `choreography/`, `images/`, and themed
subfolders under `styles/` beneath the same root. Preserve distinct films.
Temporary capture clips and WAVs already clean themselves up. The user requested removal of
superseded versions: after a successful replacement, remove obsolete outputs of
that same film rather than accumulating numbered backups. Preserve distinct films
or explicitly requested archives. Never remove unrelated project files or caches
from other tasks. Commit the relevant source changes, merge as instructed, and
remove the completed worktree and branch. Return a link to the finished video;
posting to X is a separate action requiring an explicit request.
