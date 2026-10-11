# Link-preview share card

`index.html` carries Open Graph and Twitter tags so that sharing
<https://julimbob.com/matrixcode/> in Messages, Slack, social apps and similar
shows a large preview. The tags use absolute `https://julimbob.com/matrixcode/`
URLs because preview crawlers do not resolve relative ones; update `og:url`,
`og:image` and `test/sharePreview.test.ts` together if the hosted location changes.

`public/share-card.jpg` is the preview image. Vite copies it next to
`matrixcode.html`, so a build with `--base /matrixcode/` serves it at
`/matrixcode/share-card.jpg`. It is a 1200 × 630 progressive JPEG,
which `test/sharePreview.test.ts` checks along with the tags and a 300 KB ceiling.

## Provenance

The card is an unretouched frame of the real running effect, made by
`scripts/capture_share_card.py`:

- Captured 2026-10-11 from the production build (`npm run build`, version 1.0.0
  plus the share tags), served from a loopback port.
- Headless Chromium 148.0.7778.96 (Playwright for Python 1.60.0),
  WebGL2 on ANGLE Metal, Apple M4, macOS.
- 1200 × 630 CSS viewport at device scale 2 (2400 × 1260 device pixels; the
  app caps `devicePixelRatio` at 2), dark color scheme, no reduced motion.
- Fresh browser storage plus three settings a viewer can pick in the panel,
  passed as URL params: `?density=12&size=1.5&glow=1.3` (density 12, glyph
  size 1.5, glow 1.3). The defaults (density 2, size 1, glow 0.9) give a sparse,
  dim frame that reads as a mostly black rectangle at Messages thumbnail size.
  The denser rain, larger glyphs and stronger glow keep it legible as Matrix
  rain when small. Everything else is default: classic green theme, high
  quality, no scanlines or vignette, messages and images off. Not a calendar
  occasion, so no holiday colour override or greeting applied.
- `?adaptive=0`, which only stops adaptive resolution from lowering the render
  target, so each frame renders at the full 2× resolution. The look is unchanged.
- Escape dismissed the settings panel shown on load and skipped the typed
  intro. The rain then ran for 25 seconds to finish its density ramp and fill
  the screen. 30 frames were sampled with 1.2-second pauses between them, and
  the frame whose bright leading glyphs were spread most evenly was kept
  (frame 27: near-white glyphs in 23% of a 12 × 7 block grid).
- Lanczos downscale 2:1 to 1200 × 630, saved by Pillow as a progressive JPEG,
  quality 90, 4:4:4 chroma, no metadata (170,328 bytes).

## Regenerating

Regenerate the card when the look changes (glyphs, bloom, colours, density or
trail tuning). The showcase settings live in `SHOWCASE_SETTINGS` in the script;
keep them to values a viewer can pick in the settings panel. Capture on an
ordinary day: on 14 February, 17 March, 25 December or a full moon the app
applies an occasion colour theme or greeting.

```sh
python3 -m venv /tmp/sharecardvenv
/tmp/sharecardvenv/bin/pip install playwright pillow
/tmp/sharecardvenv/bin/python -m playwright install chromium
npm run build
/tmp/sharecardvenv/bin/python scripts/capture_share_card.py --candidates /tmp/share-card-frames
```

The script fails if the page logs an error or warning, or falls back to the
Canvas2D renderer. It writes the best-scoring frame to `public/share-card.jpg`.
`--candidates` also saves every sampled frame with its score, so you
can review them and copy in a better frame. Then update the provenance above
and run `npm test`.
