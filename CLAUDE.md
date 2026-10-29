# CLAUDE.md

## Workflow

- Implement changes in a fresh git worktree. After checking for bugs and verifying the work, commit only relevant paths, rebase onto the latest main, merge/fast-forward into main, and clean up the worktree and branch.
- The browser/WebGL app under `src/` is the visual and behavioral source of truth. Native implementations live under `macos/MatrixCodeScreenSaver/` (Objective-C/AppKit/Metal), `windows/MatrixCode/` (C++20/Win32/Direct3D 11), and `linux/MatrixCode/` (C++20/Qt/OpenGL). Whenever a feature, behavior, bug fix, configuration change, token/countdown/image rule, or visual tuning change is made to one implementation, make the equivalent change to the other applicable implementations in the same workstream so all four stay aligned. If exact parity is impossible, document the intentional difference in the relevant README and tests.
- Wallpaper Engine is a web-wallpaper distribution of the browser app, not another native renderer. Host-property or lifecycle changes belong in `src/platform/wallpaperEngine.ts`, the canonical catalog in `wallpaper-engine/property-spec.json`, generated `wallpaper-engine/project.json`, and the package tests/docs as applicable.

## Project skills

For producing a marketing video from scratch, creating a new one, or updating an existing one, use [the MatrixCode marketing video skill](.claude/skills/matrixcode-marketing-video/SKILL.md). Project skills live in `.claude/skills/`; `.agents/skills` points to that same source. `AGENTS.md` is a relative symlink to this file so Claude and Codex share the same guidance.

## Commands

- `npm run dev` — Vite dev server (`DEV_PORT` 5188 in `vite.config.ts`, registered with LanternPad; assume it is already running).
- `npm run build` — `tsc --noEmit`, then Vite emits a single inlined `dist/matrixcode.html` (`vite-plugin-singlefile` plus a rename plugin in `vite.config.ts`).
- `npm test` / `npm run test:watch` — Vitest over `test/**/*.test.ts`, `environment: "node"` (no DOM), 30s per-test timeout.
- Single test: `npx vitest run test/rainSim.test.ts` (add `-t "<name>"` to filter).
- `npm run verify:parity` — the full gate: web tests + build, then the native `./test.sh` and `./build.sh`. Needs a Mac with full Xcode.
- `npm run build:wallpaper` — builds the browser artifact and packages an offline Wallpaper Engine web wallpaper in `dist/wallpaper-engine/`. `npm run verify:wallpaper` checks the generated project against the canonical property catalog.
- `npm run preview` — serves the production build.
- Native Windows: `npm run build:windows` stages an x64 Release app/`.scr` without tests; `npm run test:windows` builds x64 Debug and runs native tests; `npm run verify:windows` also creates the deterministic WARP capture; `npm run release:windows` builds x64/ARM64 MSI, portable, symbol, and checksum artifacts. These require Windows, Visual Studio 2022 with Desktop C++, and CMake 3.29+; release packaging also requires WiX v4. Signing is optional unless `-RequireSigning` is passed through to `Build-Release.ps1`.
- Native Ubuntu: `npm run build:linux` builds the Release Qt/OpenGL app; `npm run test:linux` builds Debug and runs the shared native and Linux platform suites; `npm run verify:linux` runs both; `npm run release:linux` creates the architecture-native Debian package. The Ubuntu 24.04 baseline requires Qt 6 development packages, OpenGL/EGL development headers, Ninja, and CMake 3.28+.
- Native Omarchy: `npm run release:arch` creates an Arch package from the current checkout using makepkg; `-- --prepare-only` stages a checksummed source archive and PKGBUILD without building. `npm run test:omarchy` checks the installer and saver lifecycle with mocked desktop commands. Current Omarchy 4.x uses Hyprland/Quickshell, not XScreenSaver; see `linux/MatrixCode/OMARCHY.md`. Preserve Omarchy's lock screen and timing, and use the user-owned idle-plugin clone for reversible integration.
- Native, from `macos/MatrixCodeScreenSaver/`: `./test.sh` (xcodegen + `xcodebuild test`), `./build.sh` (thin wrapper over `scripts/build-release.sh --auto-signing`), `./install.sh` (release build → `~/Library/Screen Savers`). For a signed/notarized DMG use `scripts/build-release.sh --release` from the repo root. Xcode is located by `scripts/lib/xcode-developer-dir.sh` (DEVELOPER_DIR → XCODE_APP → non-CLT `xcode-select -p` → usual paths → Spotlight), so an Xcode outside `/Applications` needs no `xcode-select --switch`; set `XCODE_APP` to pin one.
- `test/test_dmg_*.py` are pytest, **not** part of `npm test`. They need their own venv: `python3 -m venv /tmp/dmgvenv && /tmp/dmgvenv/bin/pip install ds_store mac_alias pillow pytest`.
- `scripts/capture_share_card.py` recaptures `public/share-card.jpg`, the link-preview image named by the Open Graph tags in `index.html`, from a built `dist/` (Playwright for Python and Pillow in their own venv; see `docs/share-card.md`). Rerun it when the rendered look changes.

## Cross-implementation traps

`npm test` is not web-only. Several suites reach outside `src/`, so an innocuous edit elsewhere can fail it:

- `test/renderParityContract.test.ts` reads the macOS, Windows, and Linux render sources **as text** and pins their constants against the web source of truth. Changing atlas resolution, bloom levels, blur/composite constants, preset colors, or adaptive defaults fails the web suite until every applicable native renderer matches.
- `test/rainSimGolden.test.ts` pins FNV-1a checksums of the packed `state` bytes, and `test/messageScheduler.test.ts` has a cross-language golden; these are mirrored by macOS XCTests and the shared Windows/Linux C++ tests. Any simulation or scheduler behavior change must regenerate every applicable fixture deliberately.
- `test/buildReleaseScript.test.ts` executes `scripts/build-release.sh --help` and greps its source; `test/webIcons.test.ts` reads `index.html`, `public/manifest.webmanifest` and the `public/icons/*.png` pixels, checking them against `colorPresets`; `test/sharePreview.test.ts` pins those Open Graph tags and the share card's JPEG dimensions and size.

## Web architecture

Full-viewport WebGL2 rain bundled into one self-contained HTML file. Entry `src/main.ts` → `mountMatrixRain(container)` in `src/app.ts`, which owns the RAF loop, resize/visibility/fullscreen, WebGL context loss/restore, and the lane + adaptive-resolution wiring.

The rendering model is film-accurate: glyphs sit on a **stationary grid** and a wave of illumination sweeps down each column leaving an exponentially decaying trail — the grid never scrolls.

One direction of flow per frame:

1. **`src/sim/rainSim.ts`** — `RainSim`, a deterministic headless CPU sim over a `cols × rows` grid, packing each cell into RGBA8 (`state`). Channel layout and flag bits are LOCKED in `src/types.ts`. DOM-free and seedable (`src/util/rng.ts`), so it is fully unit-testable.
2. **`src/gl/stateTexture.ts`** — uploads each lane's byte array as a texture every frame.
3. **`src/sim/imageScheduler.ts` / `src/sim/imageReveal.ts`** — schedule imported image masks on a separate deterministic hash timeline and build per-cell image influence without perturbing rain or message RNG.
4. **`src/gl/renderer.ts`** — draws glyphs from atlas + state texture(s), composites message/image influence, then multi-level bloom (brightpass → blur → composite, with scanlines/vignette). `BLOOM_LEVELS` = low 1 / med 2 / high 3. Shaders live in `src/gl/shaders/*.glsl`, imported as raw strings via Vite's `?raw`; `twgl.js` handles GL boilerplate.
5. **`src/gl/glyphAtlas.ts`** — rasterizes `src/sim/glyphSet.ts` into an atlas. Rebuilt when `mirror`, `glyphFont`, or `glyphMode` changes; `glyphScale` instead recomputes the grid.

Invariants and gotchas:

- The glyph order in `src/sim/glyphSet.ts` is the index contract shared by the sim, the atlas, and the native port. The atlas may substitute a fallback character a font cannot render, but must never change the count or order.
- `src/sim/frameSteps.ts` splits each frame's elapsed time into substeps of at most 1/15 s with at most 0.25 s of catch-up, so low render FPS does not slow the rain (and does not fast-forward when adaptive resolution recovers).
- Overlap lanes: with `allowOverlap` on and density above `OVERLAP_ONSET_DENSITY` (20), `app.ts` runs extra `RainSim` layers at van der Corput fractional column offsets and composites them additively. `src/sim/overlapLanes.ts` is the pure mapping from density/tier to lanes (cap 2/4/8 by tier) and never touches `RainSim`, so the golden determinism holds. Overlap is disabled in multi-monitor mode.
- `src/gl/adaptiveResolution.ts` (pure EMA + hysteresis) scales the render target only — the grid and look are unchanged. `?adaptive=0` disables it.
- No WebGL2 or GPU initialization failure → `src/fallback/canvas2dRain.ts` plus a compatibility notice. Reduced motion or a hidden tab → the loop stops and renders one static frame.

## Configuration & state

`ControlsStore` (`src/config/controls.ts`) merges defaults < `localStorage` < URL query, and every `set()` writes the non-default controls back into the query string via `history.replaceState`, so the address bar round-trips a look (and rewrites itself as sliders move). Static tuning is `src/config/simConfig.ts`; themes are `src/config/colorPresets.ts`.

Every persisted document follows the same shape: a `DEFAULT_*`, a `sanitize*`/`clone*` pair over the coercion helpers in `src/config/sanitize.ts` (`num`/`text`/`bool`/`capArray`), and a localStorage store. Keys: `mx-controls`, `mx-intro`, `mx-messages`, `mx-images`, `mx-countdown`, `mx-ui-state`, and `mx-user-name`. Other URL params: `?name=`, `?hud`, `?native=screensaver|configuration`.

## Image reveals

`src/config/imagesStore.ts` owns the portable `mx-images` document: at most 64 masks, each at most 96 × 96 cells, with standard padded Base64 containing exactly one greyscale byte per cell. `src/sim/imageMask.ts` aspect-fits imports without upscaling and preserves the established alpha-squared edge treatment. `ImageScheduler` independently selects images and placement and drives appear/hold/disappear, flicker, and brightness-fade envelopes. `imageReveal.ts` defines bilinear mask sampling, contrast/brightness signal, clamped border extension, virtual-grid placement, falling-rain gate, cell identity, and glyph selection. These constants and rounding rules are cross-platform contracts; change them in web, macOS, and the shared Windows/Linux core together with fixtures/tests.

## Overlays & UI

`src/ui/controlsPanel.ts` is the settings panel. Five modal editors extend `ModalEditor` (`src/ui/modalKit.ts`, styled by `.mx-modal*`/`.mx-line*`/`.mx-field` in `src/styles.css`): characters, intro, messages, images, and countdown — the open one is tracked as `ActiveSettingsSurface` in `src/config/uiState.ts`.

Keys (`onKey` in `app.ts`): `H` panel, `F` fullscreen, `I`/`M`/`C` open the intro/messages/countdown editors, `N` or `Shift+M` toggle messages, `P` pause, `Alt+F` FPS HUD, `-`/`=` nudge density, `Escape` skips the intro. Double-click enters fullscreen, triple-click enters multi-monitor (`src/sim/multiClick.ts`).

- **Intro** — `src/sim/messageOverlay.ts` is the pure typing timeline (`MessageLine`/`TypeConfig`) plus a thin DOM renderer. It plays on **every** load while `IntroScript.enabled` (default true) and reduced motion is off (`shouldPlayIntro`); there is no "seen once" gate. Click or `Escape` skips it. `src/config/introStore.ts` holds the editable script (lines, timing, rain during vs. after); `src/sim/introRain.ts` owns the load-time density ramp (`densityRampFactor`/`loadRampMs`/`rampEase`), used on ordinary reloads too.
- **In-rain messages** — periodic phrases rendered as rain glyphs. `src/config/messagesStore.ts` holds the pool and timing; `MessageScheduler` (`src/sim/messageScheduler.ts`) times and jitters them against a `RainSim`-shaped `MessageSink`. It optionally takes rectangular `MessageRegion`s so multi-monitor can place a copy inside each physical display slice.
- **Images** — `src/ui/imagesEditor.ts` imports images into portable masks and edits their schedule/placement; `X` opens the editor and `Shift+X` toggles reveals. Images use full virtual-grid coordinates so a reveal remains continuous across browser multi-monitor slices.
- **Tokens** — one resolver for both text surfaces: `src/sim/tokens.ts`, pure and driven by an injected `TokenContext`. `{name}`, `{greeting}`, `{uptime}`, `{fps}`, `{time[:strftime]}`, `{countdown[:NAME]}`, `{countup[:NAME]}`. A `:NAME` resolves to a user moment (`src/config/countdownStore.ts`) first, then a built-in holiday or moon phase (`src/sim/holidays.ts`, `HOLIDAY_TOKENS`), else 00:00. Unknown `{foo}` passes through.
- `src/ui/favicon.ts` renders a live theme-coloured favicon, recoloured when the preset changes.

## Multi-monitor (`src/multimonitor/`)

One fullscreen window per display, each rendering a slice of a single shared virtual grid so the rain is continuous across the physical arrangement. `multiMonitorGrid.ts` is the pure, unit-tested geometry (virtual grid, per-screen slices, slice extraction, fixed-timestep stepping); `multiMonitorFullscreen.ts` drives the Chromium Window Management API (`getScreenDetails`, `requestFullscreen({ screen })`) and passes each window its slice in the URL hash. Chromium-only; degrades to ordinary fullscreen. See `docs/multimonitor-setup.md`.

Windows stay in lockstep with **no per-frame messaging** — deterministic sims and schedulers over a shared seed + `Date.now()` epoch. Each window reloads the persisted message document on entry so a fresh panel cannot diverge from the controller. BroadcastChannels coordinate exit and mirror control changes. Windows carry the session's message-placement mode in the URL hash: `singleMonitor` positions one message across the full virtual grid; otherwise each display gets a copy. `independentMonitorPositions` gives copies separate deterministic jitter samples; by default copies share relative placement. These choices are independent of vignette. Message-only scramble uses a separate RNG so message targets do not perturb the shared rain motion.

## Wallpaper Engine web wallpaper

`src/main.ts` installs `src/platform/wallpaperEngine.ts` before mounting the app. The adapter queues callbacks that arrive before attachment, retains initial property state across changed-only deltas, maps fixed property slots into ordinary app documents, accepts a deterministically sorted/bounded image directory, applies the host FPS limiter, and freezes app-relative timelines while paused. Hosted mode uses in-memory stores and suppresses browser settings, fullscreen, and multi-window controls. The Canvas2D fallback must honor the same property, FPS, pause, visibility, and image lifecycle as WebGL.

`wallpaper-engine/property-spec.json` is canonical and `wallpaper-engine/project.json` is generated; do not hand-edit the latter. `scripts/wallpaper-engine/package.mjs` turns `dist/matrixcode.html` into the importable offline package and validates its contents. Continuous multi-display output relies on Wallpaper Engine's Span mode; separate web instances intentionally run independently because the host does not expose their virtual offsets.

## Native macOS

`macos/MatrixCodeScreenSaver/` is Objective-C AppKit + ScreenSaver.framework + Metal, generated by XcodeGen from `project.yml` (arm64, macOS 13+). Two targets share `Source/`: `MatrixCode` → `Matrix Code.saver`, and `MatrixCodeApp` (+ `AppSource/`) → `Matrix Code.app`. Shaders are `Resources/MatrixCodeShaders.metal`; tests are `Tests/`.

It intentionally contains no TypeScript, HTML, WebGL, JavaScript runtime, or WKWebView. (`src/platform/nativeHost.ts` is a web-side WKWebView/native-host bridge with no in-repo native consumer — do not read it as evidence the saver embeds a web view.)

Keep these aligned with the browser implementation:

- `MatrixCodeMetalView` — stationary-grid rain, glyph scrambling, bloom compositing, themes, scanlines, vignette, overlap lanes, continuous virtual-grid multi-display. Honours `MATRIXCODE_ADAPTIVE=0` (the native counterpart of `?adaptive=0`).
- `MatrixCodeRainLifecycle` — intro/load ramp and glyph-distribution rules.
- `MatrixCodeIntroOverlayView` — typewriter intro, click/Escape skip, timing, token resolution.
- `MatrixCodeConfigurationController` — native Options sheet for rain, intro, messages, images, and countdown/countup moments; persists the same `mx-*` JSON keys with the same sanitization rules as the web app.
- `MatrixCodeTokenResolver` — same token grammar and regex as `src/sim/tokens.ts`, holidays included.
- `MatrixCodeImageContract` and `MatrixCodeMetalView` — portable-mask sanitization/import, deterministic scheduling/placement, and falling-glyph reveal rendering. The native Images editor persists the same `mx-images` JSON document.

Any parity change should usually include the web suite plus the applicable macOS, Windows, and Linux native tests.

## Native Windows app and screen saver

`windows/MatrixCode` is a separate C++20 implementation with no browser runtime:

- `MatrixCodeCore` contains the deterministic RGBA8 rain sim, Mulberry32 RNG, bounded frame stepping, controllers, settings sanitizers, compact image masks, and image scheduling/reveal math. Its golden fixtures are derived from the web source of truth.
- `MatrixCodeRenderD3D11` renders through an RGBA16F scene whose alpha channel carries the bloom signal, one to three Gaussian bloom levels, ACES tone mapping, scanlines, and vignette. A floating-point influence texture preserves the full HDR image-reveal range. DirectWrite builds the glyph atlas and the post-composite intro/HUD/toast surfaces; hardware D3D11 is preferred and WARP is the fallback/capture path.
- `MatrixCodeWin32` owns app and screen-saver lifecycle. `MatrixCode.exe` is the standalone host. `Matrix Code.scr` supports no-argument or `/c[:HWND]` configuration, `/s` full-screen playback, and `/p HWND` Control Panel preview. Full-screen mode coordinates one topmost window per physical monitor over one shared virtual-grid simulation.
- Settings are stored in `%LOCALAPPDATA%\MatrixCode\settings.json`. CMake builds `MatrixCodeNativeTests.exe` and `MatrixCodeRenderCapture.exe`; the PowerShell scripts under `windows/MatrixCode/scripts` configure, build, test, stage, sign, package, and verify.

Do not overstate Windows validation. The source implements the typed intro presentation, messages, image reveals, countdown tokens, structured document editors, WIC import, full 1.45 image brightness, per-display logical topology, and nonblocking multi-window presentation. A release claim still requires the MSVC native suite and WARP capture, x64 and ARM64 packaging, `.scr` shell-mode checks, and mixed-DPI/mixed-refresh hardware comparison. DirectWrite glyph pixels may vary with installed Windows fonts; keep that boundary documented in `windows/MatrixCode/README.md` and capture tolerances.

## Native Ubuntu app and XScreenSaver mode

The Ubuntu implementation under `linux/MatrixCode` is C++20 with Qt 6 Widgets
and OpenGL 3.3 Core. It compiles the portable `MatrixCodeCore` sources housed in
the Windows tree, so Linux and Windows share simulation, settings, scheduling,
image-reveal, token, holiday, controller, and topology behavior instead of
maintaining another translation.

- `MatrixCodeRenderGL` mirrors the RGBA16F scene, bloom tiers, ACES tone map,
  scanlines, vignette, glyph atlas, overlays, and adaptive-resolution contract.
- The Qt host owns the standalone, fullscreen, continuous multi-display,
  settings, structured editor, reduced-motion, pause, and capture lifecycles.
- `SettingsStoreLinux` persists the versioned `mx-*` snapshot atomically below
  the XDG configuration root, and `ImageImportQt` preserves the portable mask
  conversion rules.
- The application and multi-monitor presentation work on Wayland and X11.
  XScreenSaver embedding is X11-only. Stock GNOME Wayland does not provide a
  supported third-party secure lock-screen surface; do not bypass, patch, or
  weaken the system lock screen to simulate one.

Do not overstate Linux validation. Release claims require native arm64 and amd64
tests/packages, deterministic software capture comparison, NVIDIA and Mesa runs,
GNOME Wayland/X11 checks, mixed-DPI/mixed-refresh hardware, context recovery,
suspend/resume, monitor hot-plug, and `.deb` install/upgrade/uninstall tests.
System font pixels may vary; keep that boundary documented in
`linux/MatrixCode/README.md` and canonical capture tolerances.
