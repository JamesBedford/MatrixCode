# Matrix Code marketing videos

Use the project-local [MatrixCode marketing video skill](../.claude/skills/matrixcode-marketing-video/SKILL.md)
to recreate a film, produce a new one, or update the scenes, captions, soundtrack,
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

`--video first` is the default, so the original command still regenerates the
first film. `both` selects the first two, `new` selects the third through fifth,
`styles` selects the sixth through eighth, and `all` selects all eight. Every film is 36 seconds at 1920 × 1080 and 30 FPS, with the same
original synthesized soundtrack style and shared in-rain `Try it now!` ending.

| Selection | Showcase | Default MP4 |
| --- | --- | --- |
| `first` | Classic green, blue binary, amber terminal, purple, fine columns, overlap comparison | `output/marketing/matrixcode-styles.mp4` |
| `second` | Red symbols, golden slow motion, monochrome Latin, custom teal, rabbit image reveal, live countdown | `output/marketing/features/matrixcode-features.mp4` |
| `third` | Personal names, custom phrases, a live clock, count-up, vertical words, positioned messages | `output/marketing/words/matrixcode-words.mp4` |
| `fourth` | Typed intros, rain behind text, load ramp, glyph mirroring, density shortcuts, intro skip | `output/marketing/choreography/matrixcode-choreography.mp4` |
| `fifth` | Greyscale moon, panoramic skyline, image scale, placement, soft fades, image playlist | `output/marketing/images/matrixcode-images.mp4` |
| `sixth` | Six saturated neon rain styles | `output/marketing/styles/neon/matrixcode-neon.mp4` |
| `seventh` | Six retro phosphor and terminal rain styles | `output/marketing/styles/phosphor/matrixcode-phosphor.mp4` |
| `eighth` | Six spacious, layered, and flowing rain styles | `output/marketing/styles/atmospheres/matrixcode-atmospheres.mp4` |

The `styles` films show only rain looks before the closing invitation. Their body
scenes contain no intros, image reveals, messages, or interactive demonstrations.

Each film keeps its poster, storyboard, and encoded final frame beside its MP4.
`--output-dir DIRECTORY` changes the output root for individual films or groups;
`--out PATH.mp4` overrides one film's destination and cannot be used with a group.
Use a separate directory for each film when choosing custom destinations so their
companion JPEGs stay separate. Preview-only runs replace the poster and storyboard
but leave existing MP4s and encoded final frames untouched.

New captures use a 56-pixel top-right URL. The closing headline is 50 pixels and
the centered closing URL is 66 pixels, with clear spacing around the original
in-rain invitation. Existing exports receive this typography when regenerated.

The script verifies audio and video before publishing a full render. Each run
prints a unique log path and a concise pass/fail result. Outputs and logs under
`output/marketing/` are ignored by Git. Keep distinct films and remove
superseded versions of the same film after validating replacements.
