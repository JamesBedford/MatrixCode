# CLAUDE.md

## Workflow

- After making changes, check for any bugs, make fixes, and then commit the changes to main when done.
- This repository contains two separate implementations of MatrixCode: the browser/WebGL app under `src/` and the native macOS AppKit/Metal app + screen saver under `macos/MatrixCodeScreenSaver/`. Whenever a feature, behavior, bug fix, configuration change, token/countdown rule, or visual tuning change is made to one implementation, make the equivalent change to the other implementation in the same workstream so the two codebases stay in sync. If exact parity is impossible, document the intentional difference in the relevant README and tests — `docs/macos-web-parity.md` is the parity contract and already lists the accepted platform-only surfaces.

## Commands

- `npm run dev` — Vite dev server (`DEV_PORT` 5188 in `vite.config.ts`, registered with LanternPad; assume it is already running).
- `npm run build` — `tsc --noEmit`, then Vite emits a single inlined `dist/matrixcode.html` (`vite-plugin-singlefile` plus a rename plugin in `vite.config.ts`).
- `npm test` / `npm run test:watch` — Vitest over `test/**/*.test.ts`, `environment: "node"` (no DOM; every suite tests pure functions), 30s per-test timeout.
- Single test: `npx vitest run test/rainSim.test.ts` (add `-t "<name>"` to filter).
- `npm run verify:parity` — the full gate: web tests + build, then the native `./test.sh` and `./build.sh`. Needs a Mac with full Xcode.
- Native, from `macos/MatrixCodeScreenSaver/`: `./test.sh` (xcodegen + `xcodebuild test`), `./build.sh` (thin wrapper over `scripts/build-release.sh --auto-signing`), `./install.sh` (release build → `~/Library/Screen Savers`). For a signed/notarized DMG use `scripts/build-release.sh --release` from the repo root. Xcode is located by `scripts/lib/xcode-developer-dir.sh` (DEVELOPER_DIR → XCODE_APP → non-CLT `xcode-select -p` → usual paths → Spotlight), so an Xcode outside `/Applications` needs no `xcode-select --switch`; set `XCODE_APP` to pin one.
- `test/test_dmg_*.py` are pytest, **not** part of `npm test`. They need their own venv: `python3 -m venv /tmp/dmgvenv && /tmp/dmgvenv/bin/pip install ds_store mac_alias pillow pytest`.

## Cross-implementation traps

`npm test` is not web-only. Several suites reach outside `src/`, so an innocuous edit elsewhere can fail it:

- `test/renderParityContract.test.ts` reads the native `MatrixCodeMetalView.m`, `MatrixCodeShaders.msl`, `MatrixCodeAdaptiveResolution.m` and `MatrixCodeAppDelegate.m` **as text** and pins their constants against the web ones. Changing `ATLAS_CELL_PX`, bloom level counts, blur/composite constants, preset colors, or `DEFAULT_ADAPTIVE_CONFIG` fails the web suite until the Objective-C/MSL side matches.
- `test/rainSimGolden.test.ts` pins FNV-1a checksums of the packed `state` bytes, and `test/messageScheduler.test.ts` has a cross-language golden; both are mirrored by XCTests in `macos/MatrixCodeScreenSaver/Tests/`. Any simulation or scheduler behavior change must regenerate both sides deliberately, never one.
- `test/buildReleaseScript.test.ts` executes `scripts/build-release.sh --help` and greps its source; `test/webIcons.test.ts` reads `index.html`, `public/manifest.webmanifest` and the `public/icons/*.png` pixels, checking them against `colorPresets`.

## Web architecture

Full-viewport WebGL2 rain bundled into one self-contained HTML file. Entry `src/main.ts` → `mountMatrixRain(container)` in `src/app.ts`, which owns the RAF loop, resize/visibility/fullscreen, WebGL context loss/restore, and the lane + adaptive-resolution wiring.

The rendering model is film-accurate: glyphs sit on a **stationary grid** and a wave of illumination sweeps down each column leaving an exponentially decaying trail — the grid never scrolls.

One direction of flow per frame:

1. **`src/sim/rainSim.ts`** — `RainSim`, a deterministic headless CPU sim over a `cols × rows` grid, packing each cell into RGBA8 (`state`). Channel layout and flag bits are LOCKED in `src/types.ts`. DOM-free and seedable (`src/util/rng.ts`), so it is fully unit-testable.
2. **`src/gl/stateTexture.ts`** — uploads each lane's byte array as a texture every frame.
3. **`src/gl/renderer.ts`** — draws glyphs from atlas + state texture(s), then multi-level bloom (brightpass → blur → composite, with scanlines/vignette). `BLOOM_LEVELS` = low 1 / med 2 / high 3. Shaders live in `src/gl/shaders/*.glsl`, imported as raw strings via Vite's `?raw`; `twgl.js` handles GL boilerplate.
4. **`src/gl/glyphAtlas.ts`** — rasterizes `src/sim/glyphSet.ts` into an atlas. Rebuilt when `mirror`, `glyphFont`, or `glyphMode` changes; `glyphScale` instead recomputes the grid.

Invariants and gotchas:

- The glyph order in `src/sim/glyphSet.ts` is the index contract shared by the sim, the atlas, and the native port. The atlas may substitute a fallback character a font cannot render, but must never change the count or order.
- `src/sim/frameSteps.ts` splits each frame's elapsed time into substeps of at most 1/15 s with at most 0.25 s of catch-up, so low render FPS does not slow the rain (and does not fast-forward when adaptive resolution recovers).
- Overlap lanes: with `allowOverlap` on and density above `OVERLAP_ONSET_DENSITY` (20), `app.ts` runs extra `RainSim` layers at van der Corput fractional column offsets and composites them additively. `src/sim/overlapLanes.ts` is the pure mapping from density/tier to lanes (cap 2/4/8 by tier) and never touches `RainSim`, so the golden determinism holds. Overlap is disabled in multi-monitor mode.
- `src/gl/adaptiveResolution.ts` (pure EMA + hysteresis) scales the render target only — the grid and look are unchanged. `?adaptive=0` disables it.
- No WebGL2 → `src/fallback/canvas2dRain.ts` plus a compatibility notice. Reduced motion or a hidden tab → the loop stops and renders one static frame.

## Configuration & state

`ControlsStore` (`src/config/controls.ts`) merges defaults < `localStorage` < URL query, and every `set()` writes the non-default controls back into the query string via `history.replaceState`, so the address bar round-trips a look (and rewrites itself as sliders move). Static tuning is `src/config/simConfig.ts`; themes are `src/config/colorPresets.ts`.

Every persisted document follows the same shape: a `DEFAULT_*`, a `sanitize*`/`clone*` pair over the coercion helpers in `src/config/sanitize.ts` (`num`/`text`/`bool`/`capArray`), and a localStorage store. Keys: `mx-controls`, `mx-intro`, `mx-messages`, `mx-countdown`, `mx-ui-state`, `mx-user-name` (native adds `mx-images`). Other URL params: `?name=`, `?hud`, `?native=screensaver|configuration`.

## Overlays & UI

`src/ui/controlsPanel.ts` is the settings panel. Four modal editors extend `ModalEditor` (`src/ui/modalKit.ts`, styled by `.mx-modal*`/`.mx-line*`/`.mx-field` in `src/styles.css`): characters, intro, messages, countdown — the open one is tracked as `ActiveSettingsSurface` in `src/config/uiState.ts`.

Keys (`onKey` in `app.ts`): `H` panel, `F` fullscreen, `I`/`M`/`C` open the intro/messages/countdown editors, `N` or `Shift+M` toggle messages, `P` pause, `Alt+F` FPS HUD, `-`/`=` nudge density, `Escape` skips the intro. Double-click enters fullscreen, triple-click enters multi-monitor (`src/sim/multiClick.ts`).

- **Intro** — `src/sim/messageOverlay.ts` is the pure typing timeline (`MessageLine`/`TypeConfig`) plus a thin DOM renderer. It plays on **every** load while `IntroScript.enabled` (default true) and reduced motion is off (`shouldPlayIntro`); there is no "seen once" gate. `src/config/introStore.ts` holds the editable script (lines, timing, rain during vs. after); `src/sim/introRain.ts` owns the load-time density ramp (`densityRampFactor`/`loadRampMs`/`rampEase`), used on ordinary reloads too.
- **In-rain messages** — periodic phrases rendered as rain glyphs. `src/config/messagesStore.ts` holds the pool and timing; `MessageScheduler` (`src/sim/messageScheduler.ts`) times and jitters them against a `RainSim`-shaped `MessageSink`. It optionally takes rectangular `MessageRegion`s so multi-monitor can place a copy inside each physical display slice.
- **Tokens** — one resolver for both surfaces: `src/sim/tokens.ts`, pure and driven by an injected `TokenContext`. `{name}`, `{greeting}`, `{uptime}`, `{fps}`, `{time[:strftime]}`, `{countdown[:NAME]}`, `{countup[:NAME]}`. A `:NAME` resolves to a user moment (`src/config/countdownStore.ts`) first, then a built-in holiday or moon phase (`src/sim/holidays.ts`, `HOLIDAY_TOKENS`), else 00:00. Unknown `{foo}` passes through.
- `src/ui/favicon.ts` renders a live theme-coloured favicon, recoloured when the preset changes.

## Multi-monitor (`src/multimonitor/`)

One fullscreen window per display, each rendering a slice of a single shared virtual grid so the rain is continuous across the physical arrangement. `multiMonitorGrid.ts` is the pure, unit-tested geometry (virtual grid, per-screen slices, slice extraction, fixed-timestep stepping); `multiMonitorFullscreen.ts` drives the Chromium Window Management API (`getScreenDetails`, `requestFullscreen({ screen })`) and passes each window its slice in the URL hash. Chromium-only; degrades to ordinary fullscreen. See `docs/multimonitor-setup.md`.

Windows stay in lockstep with **no per-frame messaging** — deterministic sims and schedulers over a shared seed + `Date.now()` epoch. Each window reloads the persisted message document on entry so a fresh panel cannot diverge from the controller. Two BroadcastChannels only: `mx-multimonitor-fullscreen` (exit) and `mx-multimonitor-controls` (mirror control changes). With vignette off a message is centered once in the virtual grid; with any vignette each window targets a copy in its own slice, scrambled from a separate RNG so local targets do not perturb the shared rain motion.

## Native macOS

`macos/MatrixCodeScreenSaver/` is Objective-C AppKit + ScreenSaver.framework + Metal, generated by XcodeGen from `project.yml` (arm64, macOS 13+). Two targets share `Source/`: `MatrixCode` → `Matrix Code.saver`, and `MatrixCodeApp` (+ `AppSource/`) → `Matrix Code.app`. Shaders are `Resources/MatrixCodeShaders.msl`; tests are `Tests/`.

It intentionally contains no TypeScript, HTML, WebGL, JavaScript runtime, or WKWebView. (`src/platform/nativeHost.ts` is a web-side WKWebView/native-host bridge with no in-repo native consumer — do not read it as evidence the saver embeds a web view.)

Keep these aligned with the browser implementation:

- `MatrixCodeMetalView` — stationary-grid rain, glyph scrambling, bloom compositing, themes, scanlines, vignette, overlap lanes, continuous virtual-grid multi-display. Honours `MATRIXCODE_ADAPTIVE=0` (the native counterpart of `?adaptive=0`).
- `MatrixCodeRainLifecycle` — intro/load ramp and glyph-distribution rules.
- `MatrixCodeIntroOverlayView` — typewriter intro, click/Escape skip, timing, token resolution.
- `MatrixCodeConfigurationController` — native Options sheet (rain, intro, messages, countdown/countup, and the native-only `mx-images` reveals); persists the same `mx-*` JSON keys with the same sanitization rules as the web app.
- `MatrixCodeTokenResolver` — same token grammar and regex as `src/sim/tokens.ts`, holidays included.

Any parity change should usually include tests in both the web suite and `macos/MatrixCodeScreenSaver/Tests`.
