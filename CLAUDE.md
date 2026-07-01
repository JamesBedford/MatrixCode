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

Tests run in a Node environment (no DOM) and cover the headless simulation, glyph set, overlap-lane/adaptive-resolution controllers, and the message/intro overlay logic.

## Architecture

A full-viewport WebGL2 Matrix digital rain, bundled into one self-contained HTML file. Entry: `src/main.ts` → `mountMatrixRain(container)` in `src/app.ts`, which wires everything together and owns the RAF loop, resize/visibility/fullscreen handling, WebGL context loss/restore, and the overlap-lane/adaptive-resolution controllers described below.

The rendering model is film-accurate: glyphs sit on a **stationary grid** and a wave of illumination sweeps down each column, leaving an exponentially decaying trail — the grid does not scroll.

Data flows in one direction each frame:

1. **`src/sim/rainSim.ts`** — `RainSim`, a deterministic, headless CPU simulation over a `cols × rows` grid. Packs per-cell state (brightness, glyph index, phase, head flags) into an RGBA8 `Uint8Array` (`state`). Channel layout and flag bits are defined in `src/types.ts`. Being DOM-free and seedable (`src/util/rng.ts`), it is fully unit-testable. Above density 20, `app.ts` runs several independent `RainSim` layers ("lanes") offset to fractional column positions and composites them additively so drops interleave between whole columns; `src/sim/overlapLanes.ts` is the pure, unit-tested module mapping density/tier to that set of lanes (it never touches `RainSim` itself, so the core sim's golden-file determinism is untouched).
2. **`src/gl/stateTexture.ts`** — uploads each lane's byte array as a texture every frame.
3. **`src/gl/renderer.ts`** — `Renderer` draws glyphs sampling the atlas + state texture(s), then runs a multi-level bloom post-process (brightpass → blur → composite, with scanline/vignette). Bloom level count scales with the quality tier (`low`/`med`/`high`). The actual render-target resolution is separately scaled by `src/gl/adaptiveResolution.ts`, a pure/tested EMA+hysteresis controller that lowers resolution under sustained frame-time pressure and restores it when headroom returns. Shaders live in `src/gl/shaders/*.glsl`, imported as raw strings via Vite's `?raw`. Uses `twgl.js` for GL boilerplate.
4. **`src/gl/glyphAtlas.ts`** — rasterizes the glyph set (`src/sim/glyphSet.ts`) into a texture atlas; rebuilt when the `mirror` control changes.

**Fallback:** if WebGL2 is unavailable or GPU init throws, `src/fallback/canvas2dRain.ts` runs a simpler Canvas2D rain and a compatibility notice is shown.

**Configuration & state:** `ControlsStore` (`src/config/controls.ts`) is an observable store of user-facing settings; `app.ts` subscribes to react to changes (e.g. `glyphScale` recomputes the grid, `mirror` rebuilds the atlas). Static tuning lives in `src/config/simConfig.ts`; color themes in `src/config/colorPresets.ts`. Other persisted docs (intro, messages, countdown) follow the same pattern — a `DEFAULT_*` value, a `sanitize*`/`clone*` pair built on the shared coercion helpers in `src/config/sanitize.ts` (`num`/`text`/`bool`/`capArray`), and a `localStorage`-backed store.

**Overlays:** `src/ui/controlsPanel.ts` is the settings UI (toggle with `H`); `F` toggles fullscreen. Two text surfaces share one typing engine and token resolver:
- **Intro** — `src/sim/messageOverlay.ts` is the pure typing timeline (`MessageLine`/`TypeConfig`) plus its thin DOM renderer; it plays once per visitor (gated by `localStorage`), `Escape`/click skips it. `src/config/introStore.ts` holds the user-editable script (lines, timing, whether rain falls during vs. after the intro); `src/sim/introRain.ts` computes the load-time density ramp-up (`densityRampFactor`/`loadRampMs`) so rain builds in smoothly both on the intro and on ordinary reloads. Edited via `src/ui/introEditor.ts` (`I` shortcut).
- **In-rain messages** — periodic phrases rendered as rain glyphs. `src/config/messagesStore.ts` holds the list, frequency, appear/hold/disappear timing, vertical position/jitter, and flicker/fade options; `src/sim/messageScheduler.ts` (`MessageScheduler`) times and jitters their appearance against a `RainSim`-shaped `MessageSink`. Edited via `src/ui/messagesEditor.ts` (`M` shortcut); `N` toggles messages on/off.

Both surfaces substitute `{name}`, `{time}`, `{time:fmt}`, and `{countdown}` through one path: `src/sim/tokens.ts`, a pure/tested resolver driven by an injected `TokenContext` (clock + countdown target). The countdown target itself is persisted by `src/config/countdownStore.ts` and edited via `src/ui/countdownEditor.ts`. `src/ui/modalKit.ts`'s `ModalEditor` base class supplies the shared backdrop/dialog/Escape/reorderable-list scaffolding for the intro/messages/countdown editors, styled by the `.mx-modal*`/`.mx-line*`/`.mx-field` classes in `src/styles.css`.

`src/ui/favicon.ts` renders a live, theme-coloured favicon (three staggered rain columns) recoloured whenever the active preset changes.

**Super fullscreen (`src/super/`):** triple-clicking the backdrop spans the rain across every monitor — one fullscreen window per display, each rendering a slice of one shared virtual grid so the rain is continuous across the physical arrangement. `superGrid.ts` is the pure, unit-tested geometry (virtual grid + per-screen slices + slice extraction + fixed-timestep stepping); `superFullscreen.ts` orchestrates it via the Chromium Window Management API (`getScreenDetails` / `requestFullscreen({ screen })`), opening per-screen windows that carry their config in the URL hash. Windows stay in lockstep with no per-frame messaging by running the *same* deterministic sim against a shared seed + `Date.now()` epoch; a `BroadcastChannel` only coordinates exit. Chromium-only; degrades to ordinary fullscreen otherwise. See `docs/multimonitor-setup.md`.

Reduced-motion (`prefers-reduced-motion`) and page-visibility are respected — the loop stops and renders a single static frame instead of animating.
