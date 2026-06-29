# MatrixCode

Film-accurate Matrix digital rain — full-viewport WebGL2 effect, bundled into a single self-contained HTML file.

The rendering model is faithful to the films: glyphs sit on a stationary grid and a wave of illumination sweeps down each column, leaving an exponentially decaying trail. The grid does not scroll.

## Features

- **WebGL2 renderer** with multi-level bloom (brightpass → blur → composite), scanlines, and vignette
- **Film-accurate simulation** — stationary glyph grid, wave-of-illumination model, per-cell brightness decay
- **Single-file build** — `vite build` produces one inlined `matrixcode.html` with no external dependencies
- **Multi-monitor super fullscreen** — triple-click spans the rain across every connected display as one continuous grid (Chromium only; see [docs/multimonitor-setup.md](docs/multimonitor-setup.md))
- **Settings panel** — press `H` to toggle; controls for color theme, quality tier, glyph scale, and more
- **Intro typewriter message** — plays once per visitor; `Escape` or click skips it
- **Canvas 2D fallback** — displayed automatically if WebGL2 is unavailable

## Controls

| Key / Gesture | Action |
|---|---|
| `H` | Toggle settings panel |
| `F` | Toggle fullscreen |
| Double-click | Toggle fullscreen |
| Triple-click | Super fullscreen (all monitors) |
| `Escape` / click | Skip intro message |

## Getting Started

```sh
npm install
npm run dev        # dev server at http://localhost:5188
npm run build      # produces dist/matrixcode.html (single inlined file)
npm run preview    # serve the production build
npm test           # run the Vitest suite
```

## Architecture

Data flows in one direction each frame:

1. **`src/sim/rainSim.ts`** — headless CPU simulation; packs per-cell state (brightness, glyph index, phase, head flags) into a `Uint8Array`. DOM-free and seedable, so it is fully unit-testable.
2. **`src/gl/stateTexture.ts`** — uploads the byte array as a GPU texture each frame.
3. **`src/gl/renderer.ts`** — draws glyphs sampling a glyph atlas + state texture, then runs the bloom post-process. Bloom level count scales with the quality tier (`low` / `med` / `high`). Uses `twgl.js` for GL boilerplate.
4. **`src/gl/glyphAtlas.ts`** — rasterizes the glyph set into a texture atlas; rebuilt when the `mirror` control changes.

**Configuration:** `ControlsStore` (`src/config/controls.ts`) is an observable store of user-facing settings. Static tuning lives in `src/config/simConfig.ts`; color themes in `src/config/colorPresets.ts`.

**Multi-monitor:** all windows run the same deterministic simulation against a shared seed and `Date.now()` epoch — same clock ⇒ pixel-aligned seams with no per-frame cross-window messaging. A `BroadcastChannel` is used only to coordinate exit. See `src/super/`.
