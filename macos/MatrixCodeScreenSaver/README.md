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

## Requirements

- macOS 13 or later on Apple Silicon
- Xcode and the Xcode command-line tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build and test

From this directory:

```sh
./test.sh
./build.sh
```

The release products are written to `build/MatrixCode.saver`,
`build/MatrixCode.saver.zip`, `build/MatrixCode.app`, and
`build/MatrixCode.app.zip`. The zips are copied directly from Xcode's signed
temporary output and are the safest artifacts to move out of a cloud-synced
working tree.

The project is generated from `project.yml` with XcodeGen. Source files live in
`Source/`, Metal shaders live in `Resources/MatrixCodeShaders.msl`, and native
regression tests live in `Tests/`.

## Install

```sh
./install.sh
```

Alternatively, expand `build/MatrixCode.saver.zip` outside the cloud-synced
working tree and double-click the resulting saver. Select **MatrixCode** in
System Settings → Screen Saver. To run it as a standalone app, open
`build/MatrixCode.app` or expand and open `build/MatrixCode.app.zip`.

Use **Options…** in System Settings, or **MatrixCode → Settings…** in the
standalone app, to edit the rain controls, viewer name, intro, in-rain messages,
and countdown/countup moments.

The Options sheet is transactional: **OK** saves all changes and **Cancel**
discards them. In the standalone app, double-click the rain to toggle native
fullscreen and triple-click it to start the continuous multi-monitor
presentation. Press `P` to pause or resume the animation; the presentation
commands are also available from the **View** menu.
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
- `MatrixCodeMetalView` owns the Metal device, render loop, rain state,
  multi-display virtual-grid mapping, themes, glow, scanlines, vignette, and
  in-rain message rendering.
- `MatrixCodeRainLifecycle` mirrors the web load/intro ramp and deterministic
  weighted glyph selection.
- `MatrixCodeIntroOverlayView` renders the native typewriter intro and resolves
  tokens before measuring/playing each line.
- `MatrixCodeConfigurationController` builds the AppKit Options sheet and
  sanitizes settings using the same ranges, caps, defaults, and `mx-*`
  persistence keys as the browser stores.
- `MatrixCodePreferences` reads and writes the shared preference documents.
- `MatrixCodeTokenResolver` mirrors `src/sim/tokens.ts`, including named
  countdown/countup moments and astronomical/calendar token calculations.
- `MatrixCodeSession` provides deterministic per-session seeds and timing data
  so independent saver views stay visually aligned.

## Keeping parity with the web app

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
