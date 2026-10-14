# Matrix Code marketing video

Use the project-local [MatrixCode marketing video skill](../.claude/skills/matrixcode-marketing-video/SKILL.md)
to recreate the film, produce a new one, or update the scenes, captions, soundtrack,
and social-player layout. It bundles the canonical Python capture and soundtrack
scripts and their dependencies.

The [production reference](../.claude/skills/matrixcode-marketing-video/references/production.md)
covers setup from a fresh checkout, preview/full render commands, editing points,
verification, output handoff, and cleanup. Follow it before replacing a finished video.

Claude and Codex use the same skill source: `.agents/skills` is a relative symlink
to `.claude/skills`. The established `scripts/capture_marketing_video.py` and
`scripts/marketing_audio.py` command paths also link to the bundled source files.

The latest finished video and its poster, storyboard, and encoded final frame live
under `output/marketing/`, which is ignored by Git. Keep current deliverables there
and remove superseded versions after validating their replacements.
