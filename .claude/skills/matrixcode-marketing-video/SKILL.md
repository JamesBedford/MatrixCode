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

- **Recreate the current film:** build the app and run the bundled capture script.
- **Update a film:** edit the scene, caption, capture, or soundtrack settings that
  implement the request, then regenerate the actual MP4 and preview images.
- **Make a new film:** use `Scene` definitions as the starting recipe. Choose the
  audience, scenes, copy, duration, and destination from the request; use the current
  landscape showcase as the default when no new direction is given.

Read [references/production.md](references/production.md) for setup, commands,
capture mechanics, editing points, verification, and cleanup. The bundled
`scripts/requirements.txt` lists the Python dependencies. Node dependencies and
the app itself come from the enclosing MatrixCode checkout.

## Production constraints

- Capture the actual app with normal query controls. Make marketing edits in the
  capture/finishing pipeline; renderer or simulation changes follow the project's
  cross-platform parity workflow.
- Preserve the current film's preferences unless the user changes them: style
  titles and a readable corner URL, no extra scene subtitles or navigation labels,
  a closing in-rain `Try it now!` reveal, and the final URL. The removed
  `Web app and screen savers` caption stays removed.
- The default score is original synthesized industrial electronic music. Keep its
  driving bass and beat, use descending percussion fills instead of transition
  swooshes, and preserve clear drum attacks. External music or samples are optional
  only when requested and usable for the intended distribution.
- Social captions must work without sound. Keep ordinary scene titles above player
  controls: the current 1080p recipe uses a 200-pixel bottom margin and a 28-pixel
  top-right URL. Inspect downscaled frames when changing copy, size, or placement.
  A different format needs its own checked safe area.
- The closing invitation uses the app's message scheduler and existing glyphs.
  Its final second settles to plain green letters without head highlights while
  ambient rain continues. Do not replace it with separately drawn CTA text unless
  the user explicitly requests a different presentation.

## Finish the requested deliverable

Use the project's worktree and integration instructions. Render in the worktree
and verify before replacing the primary output. Check the storyboard, a frame at
the smallest intended player width, and the encoded final frame; decode the whole
MP4 and verify its streams against the recipe's derived size, FPS, and duration.
For soundtrack changes, check the generated WAV for clipping and listen when audio
preview is available; numerical checks do not establish subjective sound quality.

Keep the final MP4, poster, storyboard, and final-frame image together. Temporary
capture clips and WAVs already clean themselves up. The user requested removal of
superseded versions: after a successful replacement, remove obsolete outputs of
that same film rather than accumulating numbered backups. Preserve distinct films
or explicitly requested archives. Never remove unrelated project files or caches
from other tasks. Commit the relevant source changes, merge as instructed, and
remove the completed worktree and branch. Return a link to the finished video;
posting to X is a separate action requiring an explicit request.
