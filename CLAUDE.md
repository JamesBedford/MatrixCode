# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow

- After making changes, check for any bugs, make fixes, and then commit the changes to main when done.

## Commands

- `npm run dev` — Vite dev server (port 5188, registered with LanternPad; assume it is already running).
- `npm run build` — type-checks (`tsc --noEmit`) then builds a single inlined `matrixcode.html` via `vite-plugin-singlefile`.
- `npm run preview` — serve the production build.
- `npm test` — run the Vitest suite once. `npm run test:watch` for watch mode.
- Run a single test: `npx vitest run test/rainSim.test.ts` (or `-t "<name>"` to filter by test name).

Tests run in a Node environment (no DOM) and cover the headless simulation, glyph set, and message overlay logic.

## Architecture

A full-viewport WebGL2 Matrix digital rain, bundled into one self-contained HTML file. Entry: `src/main.ts` → `mountMatrixRain(container)` in `src/app.ts`, which wires everything together and owns the RAF loop, resize/visibility/fullscreen handling, and WebGL context loss/restore.

The rendering model is film-accurate: glyphs sit on a **stationary grid** and a wave of illumination sweeps down each column, leaving an exponentially decaying trail — the grid does not scroll.

Data flows in one direction each frame:

1. **`src/sim/rainSim.ts`** — `RainSim`, a deterministic, headless CPU simulation over a `cols × rows` grid. Packs per-cell state (brightness, glyph index, phase, head flags) into an RGBA8 `Uint8Array` (`state`). Channel layout and flag bits are defined in `src/types.ts`. Being DOM-free and seedable (`src/util/rng.ts`), it is fully unit-testable.
2. **`src/gl/stateTexture.ts`** — uploads that byte array as a texture each frame.
3. **`src/gl/renderer.ts`** — `Renderer` draws glyphs sampling the atlas + state texture, then runs a multi-level bloom post-process (brightpass → blur → composite, with scanline/vignette). Bloom level count scales with the quality tier (`low`/`med`/`high`). Shaders live in `src/gl/shaders/*.glsl`, imported as raw strings via Vite's `?raw`. Uses `twgl.js` for GL boilerplate.
4. **`src/gl/glyphAtlas.ts`** — rasterizes the glyph set (`src/sim/glyphSet.ts`) into a texture atlas; rebuilt when the `mirror` control changes.

**Fallback:** if WebGL2 is unavailable or GPU init throws, `src/fallback/canvas2dRain.ts` runs a simpler Canvas2D rain and a compatibility notice is shown.

**Configuration & state:** `ControlsStore` (`src/config/controls.ts`) is an observable store of user-facing settings; `app.ts` subscribes to react to changes (e.g. `glyphScale` recomputes the grid, `mirror` rebuilds the atlas). Static tuning lives in `src/config/simConfig.ts`; color themes in `src/config/colorPresets.ts`.

**Overlays:** `src/ui/controlsPanel.ts` is the settings UI (toggle with `H`). `src/sim/messageOverlay.ts` plays the intro typewriter message (once per visitor, gated by `localStorage`); `F` toggles fullscreen, `Escape`/click skips the message.

Reduced-motion (`prefers-reduced-motion`) and page-visibility are respected — the loop stops and renders a single static frame instead of animating.
