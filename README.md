# MatrixCode — Film-Accurate Matrix Digital Rain for the Browser (WebGL2)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

MatrixCode is an open-source **Matrix digital rain effect** that runs directly in the browser: a full-viewport WebGL2 "code rain" screensaver, bundled into one self-contained HTML file with no server, no build step, and no external dependencies at runtime. Unlike most Matrix rain demos, the rendering model is film-accurate — glyphs sit on a **stationary grid** and a wave of illumination sweeps down each column, leaving an exponentially decaying trail, rather than scrolling text down the screen.

![MatrixCode running in a browser — green Matrix-style glyphs falling down a black background with a soft bloom glow](docs/screenshot.png)

## Contents

- [Why MatrixCode](#why-matrixcode)
- [Features](#features)
- [Controls](#controls)
- [Getting Started](#getting-started)
- [Architecture](#architecture)
- [License](#license)

## Why MatrixCode

Most "Matrix rain" projects (including the classic terminal `cmatrix`) scroll a column of text downward. MatrixCode instead reproduces how the effect actually works in the films: every glyph cell is fixed in place, and only its *brightness* animates as a wave of light travels down the column and decays behind it. Combined with a single-file, dependency-free build, that makes MatrixCode a good fit for:

- A **Matrix-style screensaver** you can open from a local file or a kiosk browser with no install
- A **digital rain effect** to drop into another site or an art installation, with no bundler or CDN required
- A **multi-monitor Matrix wall** — triple-click to span the same continuous rain across every connected display

## Features

- **WebGL2 renderer** with multi-level bloom (brightpass → blur → composite), scanlines, and vignette
- **Film-accurate simulation** — stationary glyph grid, wave-of-illumination model, per-cell brightness decay (not scrolling text)
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

The build output, `matrixcode.html`, is a single self-contained file — copy it anywhere and open it directly in a browser, no server required.

## Architecture

Data flows in one direction each frame:

1. **`src/sim/rainSim.ts`** — headless CPU simulation; packs per-cell state (brightness, glyph index, phase, head flags) into a `Uint8Array`. DOM-free and seedable, so it is fully unit-testable.
2. **`src/gl/stateTexture.ts`** — uploads the byte array as a GPU texture each frame.
3. **`src/gl/renderer.ts`** — draws glyphs sampling a glyph atlas + state texture, then runs the bloom post-process. Bloom level count scales with the quality tier (`low` / `med` / `high`). Uses `twgl.js` for GL boilerplate.
4. **`src/gl/glyphAtlas.ts`** — rasterizes the glyph set into a texture atlas; rebuilt when the `mirror` control changes.

**Configuration:** `ControlsStore` (`src/config/controls.ts`) is an observable store of user-facing settings. Static tuning lives in `src/config/simConfig.ts`; color themes in `src/config/colorPresets.ts`.

**Multi-monitor:** all windows run the same deterministic simulation against a shared seed and `Date.now()` epoch — same clock ⇒ pixel-aligned seams with no per-frame cross-window messaging. A `BroadcastChannel` is used only to coordinate exit. See `src/super/`.

## License

[MIT](LICENSE)
