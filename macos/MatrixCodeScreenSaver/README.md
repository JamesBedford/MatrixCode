# MatrixCode for macOS

`MatrixCode.saver` and `MatrixCode.app` are independent, Apple-Silicon macOS 13+
implementations of MatrixCode. Playback uses AppKit and Metal, with
ScreenSaver.framework used for the saver entry point. The Options sheet is
native AppKit. The bundles contain no TypeScript, HTML, WebGL, JavaScript
runtime, or WKWebView.

The web and macOS versions intentionally remain separate products. They share
the same feature contract and persisted JSON keys, but the screen saver does
not build, embed, or execute the web app. When behavior changes in the web app,
the equivalent native behavior should be updated here too, and vice versa.

## Feature contract

The native saver is expected to match the browser app's user-visible behavior:

- stationary-grid Matrix rain, where illumination moves through fixed glyph
  cells instead of scrolling text;
- weighted Katakana/digit/Latin/symbol glyph selection and glyph scrambling;
- rain controls for ramp-up, trail decay, speed, glyph change, glyph size, glow,
  lead glow, vignette, theme, quality, mirroring, scanlines, and overlap lanes;
- native intro typewriter overlay with click/Escape skip, optional rain during
  intro, post-intro delay, and the same token resolver as the web app;
- scheduled in-rain messages that resolve tokens and materialize through the
  rain cells instead of drawing a separate text overlay;
- viewer name, greeting, time formatting, countdown/countup, named moments, and
  calendar tokens;
- continuous multi-display rendering using one virtual display grid so rain can
  fall across monitor seams in native macOS screen-saver playback;
- reduced-motion behavior that avoids animated playback while still rendering a
  valid static frame.

If exact parity is intentionally impossible because of platform constraints,
document the difference here and cover the native behavior with tests.

## App icon

`scripts/generate_native_icons.py` (repo root) regenerates
`Resources/Assets.xcassets/AppIcon.appiconset` and `Resources/MatrixCode.icns`.
Small sizes (canvas ≤ 64 px) rasterize the web favicon model parsed from
`public/favicon.svg`, so they stay identical to the browser favicon. Large
sizes (≥ 128 px) are an intentional difference from the web favicon: a
deterministic, seeded cinematic render (Big Sur-style inset rounded rect with
drop shadow, three depth layers of rain, bloomed heads, vignette, scanlines)
that the 64-unit favicon grid cannot express. Both size classes derive their
palette from the classic preset in `src/config/colorPresets.ts`.

The same script also emits the browser build's PWA icon set (`public/icons/*.png`)
from the identical seeded artwork, alongside a hand-written
`public/manifest.webmanifest` and an apple-touch-icon wired into `index.html`, so
the installed web app shows the same cinematic icon. That PWA manifest is a
web-only surface with no native equivalent (macOS has its own icon system).

## Requirements

- macOS 13 or later on Apple Silicon
- Xcode and the Xcode command-line tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build and test

From this directory:

```sh
./test.sh
./build.sh --release
./build.sh --debug
```

`./build.sh` defaults to Release and also accepts `--configuration Debug` or
`--configuration Release`. The products are written to the matching
`build/Debug/` or `build/Release/` directory. Each contains `MatrixCode.saver`,
`MatrixCode.saver.zip`, `MatrixCode.app`, `MatrixCode.app.zip`, and SHA-256
checksums for the packaged archives. Release output also includes matching
dSYMs and executable UUIDs for symbolicating crash reports. Packaging stages,
ad-hoc signs, and verifies the products before publishing them, so a failed
build leaves the last successful artifacts untouched. These contributor builds
are local and are not notarized. The established `build/MatrixCode.*` paths
continue to point at the latest Release products.

For a distributable Release, use the repository-root entry point:

```sh
./scripts/build-release.sh --release               # sign, notarize, and staple
./scripts/build-release.sh --release --skip-notarize
./scripts/build-release.sh --debug
```

The distribution workflow mirrors the SpotifyCDFinder release script. It uses
the `Developer ID Application: James Bedford (7NBMEUUG5K)` identity and the
`notarytool` Keychain profile, then writes a versioned DMG, dSYMs, UUID report,
and checksums to `dist/`. `--skip-notarize` still uses Developer ID signing but
avoids the Apple notarization round trip. The script discovers Xcode without
changing the system-wide `xcode-select` setting. Set `XCODE_APP` for a
nonstandard Xcode application path or `DEVELOPER_DIR` for an explicit developer
directory.

Configure the Keychain profile once before the first notarized build:

```sh
xcrun notarytool store-credentials "notarytool" \
  --key /path/to/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX \
  --issuer <issuer-uuid>
```

The project is generated from `project.yml` with XcodeGen. Source files live in
`Source/`, Metal shaders live in `Resources/MatrixCodeShaders.msl`, and native
regression tests live in `Tests/`.

## Install

```sh
./install.sh
```

Alternatively, expand `build/Release/MatrixCode.saver.zip` outside the
cloud-synced working tree and double-click the resulting saver. Select
**MatrixCode** in System Settings → Screen Saver. To run it as a standalone
app, open `build/Release/MatrixCode.app` or expand and open
`build/Release/MatrixCode.app.zip`.

Use **MatrixCode → Settings…** in the standalone app to edit settings directly
over the running Matrix rain, matching the browser's hover/fade HUD instead of
opening a separate sheet: hovering or moving the pointer over the rain window
fades in the translucent 320-point control panel, then it fades out again after
a short idle delay unless the pointer is over it. **Settings…** (⌘,) and the
web-style **H** shortcut toggle the panel — summoning it when hidden and, when
it is already on screen, dismissing it with the same fade the idle auto-hide
uses (mirroring the browser's `H` toggle). The same native controller is hosted as **Options…** in
System Settings for the screen saver, where ScreenSaver.framework requires
Apple's configure-sheet container.

The settings UI mirrors the browser's Matrix-terminal surface with
preset-coloured native controls and centered Characters, Intro, Messages,
Images, and Countdown editor cards. Root-panel edits apply live to the running
rain and are persisted as they change; a **✕ (Save & close)** button in the
top-right corner of the panel header commits the current values and dismisses
the panel, matching the Escape key. The corner button is a native-only
affordance: the browser panel is an ambient overlay that hover-fades away,
whereas the native controller is also hosted as System Settings' modal Screen
Saver Options sheet, which needs an explicit, always-visible way to dismiss it.
Editor cards still provide their web-equivalent scoped reset and save/cancel
actions.

The implementation uses AppKit controls throughout—there is no embedded web
runtime. Three intentional platform differences remain: System Settings supplies
standard sheet chrome for Screen Saver Options; date/time values use the native
`NSDatePicker` rather than the browser's `datetime-local` control; and the
Images editor is currently native-only, storing compact imported luminance masks
in `mx-images` so Metal can reveal them through falling rain glyph brightness
and glyph-selection bias without requiring ongoing file access. Users can add
any number of image masks, choose how much of the rain field width each reveal
uses, and randomize placement inside the unused area when the reveal is smaller
than the full screen. The Images editor also includes a native-only **Max
Visibility** action that applies the image and rain settings most likely to make
image reveals obvious while leaving unrelated content settings untouched. These keep
keyboard navigation, accessibility, locale handling, Screen Saver Options
hosting, and native image import aligned with macOS while the standalone app's
surrounding geometry, typography, palette, and interaction model match the web UI.

In the standalone app, double-click the rain to toggle native
fullscreen and triple-click the rain or press `Shift-Command-M` to start the
continuous multi-monitor presentation. Press `P` to pause or resume the
animation; press `N` or `Shift-M` to toggle Messages and `Shift-X` to toggle Images. These
shortcut-triggered state changes show a top-right toast using the active Matrix
theme. The presentation commands are also available from the **View** menu.
The standalone app restores
the saved window frame on launch and, if quit while presenting, re-enters
fullscreen or multi-monitor mode on the next launch. The browser build cannot
mirror that launch restoration because browsers require a fresh user gesture
before entering fullscreen or the Window Management API. Native multi-monitor
windows join every Space, including fullscreen auxiliary Spaces, so the Matrix
presentation can appear across displays without being stranded on a different
desktop. During multi-monitor presentation, the controls and settings overlay
remain available on the centremost display only.
During normal screen-saver playback, macOS treats mouse and keyboard input as an
exit request, so fullscreen and multi-display presentation are automatic rather
than gesture-driven.

## Native architecture

- `MatrixCodeRainHostView` owns lifecycle setup, the shared Metal/intro view
  stack, preference reloads, first-responder handling, intro skip gestures, and
  preview/fullscreen/standalone mode differences.
- `MatrixCodeScreenSaverView` is the thin ScreenSaver.framework entry point and
  forwards animation/configuration callbacks into `MatrixCodeRainHostView`.
- `MatrixCodeAppDelegate` is the thin standalone app entry point. It builds the
  standard menu bar, creates resizable native windows and multi-monitor
  presentation windows, and embeds
  `MatrixCodeRainHostView`.
- `MatrixCodeMetalView` owns the Metal device and matching WebGL render graph:
  RGBA16F scene, head-only bright-pass, one-to-three Gaussian bloom levels,
  additive upsample, ACES composite, scanlines, and vignette. It renders local
  slices of one virtual grid for multi-display sessions.
- `MatrixCodeRainSimulation` directly ports `src/sim/rainSim.ts`, including its
  Mulberry32 draw order, Float32 cell semantics, stream lifecycle, and packed
  RGBA8 state. Shared golden checksums are byte-identical across languages.
- `MatrixCodeMessageScheduler` directly ports `src/sim/messageScheduler.ts`
  with its independent seed, live token relayout, row/drop directions,
  per-display regions, and reveal/fade/scramble timing.
- `MatrixCodeRainLifecycle` provides the matching load/intro ramp and canonical
  rain-glyph ranges.
- `MatrixCodeIntroOverlayView` renders the native typewriter intro and resolves
  tokens before measuring/playing each line.
- `MatrixCodeConfigurationController` builds both the AppKit Screen Saver
  Options sheet and the standalone app's embedded settings HUD, sanitizing
  settings using the same ranges, caps, defaults, and `mx-*` persistence keys
  as the browser stores.
- `MatrixCodePreferences` reads and writes the shared preference documents.
- `MatrixCodeTokenResolver` mirrors `src/sim/tokens.ts`, including named
  countdown/countup moments and astronomical/calendar token calculations.
- `MatrixCodeSession` provides deterministic per-session seeds and timing data
  so independent saver views stay visually aligned.

## Keeping parity with the web app

The precise parity contract, canonical capture inputs, manual comparison target,
and automated verification scope live in
[`../../docs/macos-web-parity.md`](../../docs/macos-web-parity.md).
Simulation output is required to be byte-identical. The render graph and shader
math are equivalent; live pixels can still vary slightly because browser Canvas
and CoreText rasterize installed fonts independently and displays apply their
own color profiles. Adaptive resolution uses the same EMA, hysteresis, scale
steps, and bounds in both renderers. Disable it for a canonical comparison with
`?adaptive=0` in the browser and `MATRIXCODE_ADAPTIVE=0` for the native process.

Use the web implementation as the feature oracle for behavior and the native
implementation as the platform oracle for AppKit/Metal integration. For any
change to either side, check whether these areas need a matching change in the
other codebase:

- settings schema, persisted `mx-*` keys, defaults, validation ranges, and
  legacy migrations;
- rain physics, density, overlap-lane behavior, glyph distribution, and timing;
- themes, post-processing controls, scanlines, vignette, and glow semantics;
- intro timing, skip behavior, rain ramp, and reduced-motion behavior;
- message scheduling, message placement, token re-resolution, and countdowns;
- native-only `mx-images` settings and rendering, until/unless the browser app
  gains an equivalent image-rain feature;
- multi-monitor geometry, seam continuity, and per-display message placement;
- tests and documentation.

Useful comparison points:

- browser settings and sanitizers: `src/config/*`;
- browser rain/message/token simulation: `src/sim/*`;
- browser multi-monitor geometry: `src/multimonitor/*`;
- native configuration and persistence tests:
  `Tests/MatrixCodeConfigurationControllerTests.m`;
- native token, lifecycle, intro, Metal, and multi-display regression tests:
  `Tests/MatrixCode*Tests.m`.

## Troubleshooting

- If System Settings has cached an older build, remove
  `~/Library/Screen Savers/MatrixCode.saver`, quit System Settings, and reinstall.
- If the preview stays on an older version, run `./install.sh` again; it clears
  extended attributes, re-signs the local bundle, and replaces the installed copy.
- Metal is required. The current project targets Apple Silicon Macs, all of
  which provide the required Metal feature set.
- If a display is black or a monitor seam does not appear continuous, run the
  native test suite and verify the installed bundle is the one just built:
  `codesign --verify --deep --strict "$HOME/Library/Screen Savers/MatrixCode.saver"`.
