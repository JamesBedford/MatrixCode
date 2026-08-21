# Wallpaper Engine web wallpaper

MatrixCode must be distributed to Wallpaper Engine as a **web wallpaper**. The package is
fully offline and uses the same WebGL application as the ordinary browser build. It does
not use an executable/application wallpaper, because those cannot be published through
the Steam Workshop.

## Build and import

From the repository root, run:

```powershell
npm run build:wallpaper
```

The importable directory is `dist/wallpaper-engine/`. In Wallpaper Engine, choose
**Create Wallpaper** and import that directory's `index.html`. Do not import the repository
root: Wallpaper Engine copies the complete selected directory into its project area.

The generated package contains the inlined application, `project.json`, preview and PWA
assets, MatrixCode and twgl.js license notices, and no remote runtime dependencies.
`property-spec.json` is the canonical catalog; do not edit generated `project.json` by hand.

Useful direct commands:

```powershell
node scripts/wallpaper-engine/generate-project.mjs --check
node scripts/wallpaper-engine/generate-project.mjs --write
node scripts/wallpaper-engine/package.mjs
node scripts/wallpaper-engine/verify.mjs dist/wallpaper-engine
```

## Host behavior

- Wallpaper Engine's property pane is authoritative. Browser `localStorage`, URL settings,
  fullscreen controls and the in-page settings editors must be disabled in hosted mode.
- The global property listener must be installed before `mountMatrixRain()` is called. Its
  initial full property payload is applied atomically; later changed-only payloads are
  merged with the retained snapshot.
- `applyGeneralProperties.fps` controls the render limiter. A value at or below zero is
  uncapped. Elapsed time is accumulated between emitted frames and then passed through the
  application's normal bounded catch-up policy.
- `setPaused` freezes app-relative timelines. Wall-clock time and countdown tokens catch up
  naturally when the wallpaper resumes.
- The image-folder property accepts supported Wallpaper Engine image formats, de-duplicates
  paths, sorts deterministically, and decodes candidates until it has at most 64 valid images.
  Candidate indexing is defensively bounded at 4096 paths.
- Host file paths are exposed to the renderer both raw and as escaped `file:///` URLs.

## Multiple displays

For continuous rain across monitors, select Wallpaper Engine's **Span** display mode. This
creates one virtual CEF canvas and therefore one continuous MatrixCode grid. Messages and
image reveals are centered once on that canvas.

Wallpaper Engine does not expose virtual display offsets to separate per-monitor web
instances. In that mode, each monitor intentionally runs an independent rain simulation;
the browser Window Management API must not be started.

## Fixed property slots

Wallpaper Engine properties cannot represent reorderable arrays. The project therefore
publishes fixed slots for:

- 12 intro lines, each with enabled/text/hold/pause fields;
- 12 in-rain messages, each with enabled/text fields;
- 12 named countdown/countup moments, each with enabled/name/local-target fields.

Local targets use `YYYY-MM-DDTHH:mm` or `YYYY-MM-DDTHH:mm:ss`. Invalid or nonexistent local
times are treated as unset. Property keys are stable lowercase ASCII-alphanumeric names so
saved Wallpaper Engine presets remain compatible.

## Runtime integration

The property listener is installed before application bootstrap. Hosted runs use in-memory
stores, suppress browser settings/fullscreen/multi-window controls, decode the selected image
folder through the shared portable-mask pipeline, obey Wallpaper Engine's FPS setting, and
freeze app-relative intro, message, rain-ramp, image, and uptime clocks while paused. Ordinary
browser and native-host runs retain their existing persisted settings and lifecycle behavior.
The packager injects a private HTML marker so hosted mode is detected before the first property
callback, without relying on a user-agent string or an optional file-property API.

## Reference

- <https://docs.wallpaperengine.io/en/web/customization/properties.html>
- <https://docs.wallpaperengine.io/en/web/api/propertylistener.html>
- <https://docs.wallpaperengine.io/en/web/performance/fps.html>
- <https://docs.wallpaperengine.io/en/web/first/gettingstarted.html>
