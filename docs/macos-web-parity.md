# Cross-platform parity contract

MatrixCode has four renderers: WebGL in `src/`, AppKit/Metal in
`macos/MatrixCodeScreenSaver/`, Win32/Direct3D 11 in `windows/MatrixCode/`, and
Qt/OpenGL in `linux/MatrixCode/`. The web implementation is the visual and
behavioral reference; platform integration remains native on each operating
system, while Windows and Linux compile the same portable C++ core.

Parity has three independently verifiable layers:

1. **Feature parity** — the same controls, defaults, validation, rain/intro/message
   rules, tokens, and multi-display behavior.
2. **Simulation parity** — a fixed seed, grid, control sequence, and timestep
   sequence produce the same packed RGBA8 cell state.
3. **Render parity** — the same packed state and glyph coverage produce the same
   color ramps, scene-alpha bloom signal, ACES composite, scanlines, and vignette.

## Canonical comparison conditions

Cross-backend image comparisons must fix every input that can legitimately vary:

- the same seed, epoch, controls, viewport size, grid, and 60 Hz timestep;
- a fixed output scale and color space, with adaptive resolution disabled in
  every implementation under comparison (`?adaptive=0` on web and the
  platform-specific native capture setting);
- image reveals disabled in compared captures, or driven by the same fixed portable
  masks, schedule, and epoch;
- the same glyph mode, font selection, and mirror setting;
- an offscreen output target, so window occlusion and display refresh rate do not
  affect the capture.

Live output cannot be promised bit-identical across arbitrary browsers, GPUs,
font rasterizers, and display profiles. For a manual canonical comparison, the
review target is no structural difference, SSIM of at least 0.999, and at least
99.5% of channel values within 2/255. The automated gate does not currently
capture every graphics backend or calculate those image metrics, so they must
not be presented as a CI guarantee. Packed simulation fixtures remain byte-exact.

## Intentional platform surfaces

The following are platform integration differences, not rain-feature gaps:

- Screen Saver Options uses the System Settings sheet supplied by macOS.
- Native date fields use `NSDatePicker`; web uses `datetime-local`.
- Browser fullscreen and multi-monitor entry require a user gesture; the native
  app can restore its previous presentation mode.
- A blank native viewer name uses the capitalized macOS login or home-folder
  name. A local `file://` web build can infer that home-folder name from its URL,
  but an HTTP-served browser page cannot access the operating-system account and
  therefore retains the portable `Neo` fallback.
- PWA metadata and browser fallback rendering have no native equivalent.
- Stock GNOME Wayland has no supported third-party secure lock-screen renderer;
  Ubuntu provides full application/fullscreen/multi-monitor behavior there and
  XScreenSaver integration on X11 without replacing the GNOME lock screen.
- Image reveals are optional and off by default on every platform. Strict
  comparisons either disable them or provide the same `mx-images` document and
  deterministic timing inputs to the compared renderers.

## Verification

Run the complete gate from the repository root on a Mac with full Xcode:

```sh
npm run verify:parity
```

This runs the web tests and single-file build, followed by the native XCTest and
release-build/package checks. Cross-language state fixtures and native
render-graph/shader-contract tests are part of those suites. It verifies the
deterministic inputs and rendering algorithm, but not the manual cross-backend
image threshold described above.

On Ubuntu 24.04 with the documented Qt/OpenGL build dependencies, run the Linux
native gate separately:

```sh
npm run verify:linux
```

Windows validation remains `npm run verify:windows` on an appropriate Visual
Studio host. Architecture-specific release and hardware gates in each native
README are additional to these source/test commands.

Xcode is located by `scripts/lib/xcode-developer-dir.sh`, which prefers
`DEVELOPER_DIR`, then `XCODE_APP`, then a non-Command-Line-Tools `xcode-select
-p`, then the usual install locations, then Spotlight. An Xcode outside
`/Applications` therefore needs no `xcode-select --switch`; set `XCODE_APP` to
pin a specific one.
