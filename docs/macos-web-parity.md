# macOS/Web parity contract

MatrixCode has two independent renderers: WebGL in `src/` and AppKit/Metal in
`macos/MatrixCodeScreenSaver/`. The web implementation is the behavioral
reference; platform integration remains native on macOS.

Parity has three independently verifiable layers:

1. **Feature parity** — the same controls, defaults, validation, rain/intro/message
   rules, tokens, and multi-display behavior.
2. **Simulation parity** — a fixed seed, grid, control sequence, and timestep
   sequence produce the same packed RGBA8 cell state.
3. **Render parity** — the same packed state and glyph coverage produce the same
   color ramps, head-only bloom, ACES composite, scanlines, and vignette.

## Canonical comparison conditions

Cross-backend image comparisons must fix every input that can legitimately vary:

- the same seed, epoch, controls, viewport size, grid, and 60 Hz timestep;
- a fixed output scale and color space, with adaptive resolution disabled in
  both implementations (`?adaptive=0` on web and `MATRIXCODE_ADAPTIVE=0` for
  the native process);
- native-only image reveals disabled;
- the same glyph mode, font selection, and mirror setting;
- an offscreen output target, so window occlusion and display refresh rate do not
  affect the capture.

Live output cannot be promised bit-identical across arbitrary browsers, GPUs,
font rasterizers, and display profiles. For a manual canonical comparison, the
review target is no structural difference, SSIM of at least 0.999, and at least
99.5% of channel values within 2/255. The automated gate does not currently
capture both graphics backends or calculate those image metrics, so they must
not be presented as a CI guarantee. Packed simulation fixtures remain byte-exact.

## Intentional platform surfaces

The following are platform integration differences, not rain-feature gaps:

- Screen Saver Options uses the System Settings sheet supplied by macOS.
- Native date fields use `NSDatePicker`; web uses `datetime-local`.
- Browser fullscreen and multi-monitor entry require a user gesture; the native
  app can restore its previous presentation mode.
- PWA metadata and browser fallback rendering have no native equivalent.
- Native image reveals are an optional extension. They are off by default and
  excluded from strict render comparisons until the web renderer supports the
  same `mx-images` document.

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

Xcode is located by `scripts/lib/xcode-developer-dir.sh`, which prefers
`DEVELOPER_DIR`, then `XCODE_APP`, then a non-Command-Line-Tools `xcode-select
-p`, then the usual install locations, then Spotlight. An Xcode outside
`/Applications` therefore needs no `xcode-select --switch`; set `XCODE_APP` to
pin a specific one.
