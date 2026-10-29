# Matrix Code marketing videos

Use the project-local [MatrixCode marketing video skill](../.claude/skills/matrixcode-marketing-video/SKILL.md)
to recreate either film, produce a new one, or update the scenes, captions, soundtrack,
and social-player layout. It bundles the canonical Python capture and soundtrack
scripts and their dependencies.

The [production reference](../.claude/skills/matrixcode-marketing-video/references/production.md)
covers setup from a fresh checkout, preview/full render commands, editing points,
verification, output handoff, and cleanup. Follow it before replacing a finished video.

Claude and Codex use the same skill source: `.agents/skills` is a relative symlink
to `.claude/skills`. The established `scripts/capture_marketing_video.py` and
`scripts/marketing_audio.py` command paths also link to the bundled source files.

After installing the dependencies and building the app as described in the
production reference, run:

```sh
python3 scripts/capture_marketing_video.py --video first
python3 scripts/capture_marketing_video.py --video second
python3 scripts/capture_marketing_video.py --video both
python3 scripts/capture_marketing_video.py --video both --preview-only
```

`--video first` is the default, so the original command still regenerates the
first film. Both films are 36 seconds at 1920 × 1080 and 30 FPS, with the same
original synthesized soundtrack style and shared in-rain `Try it now!` ending.

| Selection | Showcase | Default MP4 |
| --- | --- | --- |
| `first` | Classic green, blue binary, amber terminal, purple, fine columns, overlap comparison | `output/marketing/matrixcode-styles.mp4` |
| `second` | Red symbols, golden slow motion, monochrome Latin, custom teal, rabbit image reveal, live countdown | `output/marketing/features/matrixcode-features.mp4` |

Each film keeps its poster, storyboard, and encoded final frame beside its MP4.
`--output-dir DIRECTORY` changes the output root for either or both films;
`--out PATH.mp4` overrides one film's destination and cannot be used with `both`.
Use a separate directory for each film when choosing custom destinations so their
companion JPEGs stay separate. Preview-only runs replace the poster and storyboard
but leave existing MP4s and encoded final frames untouched.

The script verifies audio and video before publishing a full render. Each run
prints a unique log path and a concise pass/fail result. Outputs and logs under
`output/marketing/` are ignored by Git. Keep both distinct films and remove
superseded versions of the same film after validating replacements.
