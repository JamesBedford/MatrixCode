# Web PWA / installable-icon support

**Date:** 2026-07-11
**Status:** Approved design

## Goal

Make the browser MatrixCode an installable web app whose home-screen / install /
touch icon is the *same seeded cinematic render* the macOS app uses. The browser
**tab** keeps the crisp, live-recoloured SVG favicon — the cinematic scene turns
to mush at 16–32px, which is exactly why the macOS small sizes also stay on the
favicon model.

This is a web-only delivery feature. The native macOS app already exposes the
cinematic icon through its `.icns` / `AppIcon.appiconset`. The web now exposes the
*same render* through a PWA manifest + apple-touch-icon. Both icon families are
produced by one deterministic script (`scripts/generate_native_icons.py`), so
web and macOS stay visually identical — that shared render is the parity story.

## Delivery: real sibling files

The production build is a single self-contained `matrixcode.html`
(`vite-plugin-singlefile`, CSP `connect-src 'none'`), but it already ships
`favicon.svg` as a **sibling** file referenced by a relative href (`./favicon.svg`),
and the runtime swaps in a data-URI favicon once JS runs. So the artifact is
really "`matrixcode.html` + relative static assets," and adding more relative
sibling assets is consistent with the existing pattern — no inlining plugin or
data-URI gymnastics.

New committed assets under `public/`:

- `public/icons/apple-touch-icon.png` — 180×180
- `public/icons/icon-192.png`, `public/icons/icon-512.png` — `purpose: "any"`
- `public/icons/icon-192-maskable.png`, `public/icons/icon-512-maskable.png` — `purpose: "maskable"`
- `public/manifest.webmanifest`

All referenced with **relative** hrefs (`./manifest.webmanifest`, `./icons/…`) to
match the existing `./favicon.svg` and work at any host path.

**CSP:** no change needed. `connect-src 'none'` governs fetch/XHR/WebSocket only.
The manifest is governed by `manifest-src`, which falls back to `default-src`
(unset → unrestricted); icons load under `img-src`/`default-src` (also unset).

## Two visual variants (both from the existing renderer)

- **Maskable icons + apple-touch-icon** → the **full-bleed square** scene
  (`render_master_art`), opaque. iOS and Android apply their own corner mask to a
  full square cleanly; an inset/transparent-margin icon would double-round or
  float on a black fill on iOS.
- **`purpose: "any"` icons** → the **Big Sur inset** version (`compose_canvas`),
  rounded with transparent margins — looks polished when shown un-masked and
  matches the macOS Dock icon exactly.

Both derive from the same seed, so web and macOS icons are the same image.

## Manifest (`public/manifest.webmanifest`)

```json
{
  "name": "MatrixCode",
  "short_name": "Matrix",
  "description": "A full-viewport WebGL Matrix digital rain.",
  "start_url": ".",
  "scope": ".",
  "display": "standalone",
  "background_color": "#0D0208",
  "theme_color": "#0D0208",
  "icons": [
    { "src": "icons/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any" },
    { "src": "icons/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any" },
    { "src": "icons/icon-192-maskable.png", "sizes": "192x192", "type": "image/png", "purpose": "maskable" },
    { "src": "icons/icon-512-maskable.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}
```

- Colors `#0D0208` are the classic preset background from
  `src/config/colorPresets.ts`; a test ties the manifest color to that source of
  truth rather than a hard-coded literal drifting out of sync.
- Hand-written and committed (it is config, not a render). A test cross-checks
  that every icon it lists exists on disk at the declared pixel dimensions.
- `display: standalone`, `name: MatrixCode`, `short_name: Matrix` per approval.

## `index.html` additions

Add, alongside the unchanged SVG favicon `<link>` and `theme-color`:

```html
<link rel="apple-touch-icon" href="./icons/apple-touch-icon.png" />
<link rel="manifest" href="./manifest.webmanifest" />
<meta name="apple-mobile-web-app-capable" content="yes" />
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
<meta name="apple-mobile-web-app-title" content="Matrix" />
<meta name="mobile-web-app-capable" content="yes" />
```

## Generation

Extend `scripts/generate_native_icons.py` with a `write_web_icons()` step that
emits the five PNGs into `public/icons/`, wired into the script's default run so
one command regenerates both the macOS and web icon families from the same seed:

- Full-bleed square (`render_master_art` → LANCZOS resize, opaque) at 180, 192,
  512 → `apple-touch-icon.png`, `icon-192-maskable.png`, `icon-512-maskable.png`.
- Big Sur inset (`compose_canvas`) at 192, 512 → `icon-192.png`, `icon-512.png`.

The `manifest.webmanifest` is authored by hand (not emitted by the script); the
cross-check test guards manifest ↔ file drift.

## Tests (`test/webIcons.test.ts`, Node env)

1. `public/manifest.webmanifest` parses as JSON and has `name`, `short_name`,
   `start_url`, `display`, `icons`.
2. `background_color` and `theme_color` equal the classic preset background
   imported from `src/config/colorPresets.ts`.
3. Manifest declares at least one 192 and one 512 icon, and at least one
   `maskable` and one `any` purpose.
4. Every manifest icon `src` resolves to a file under `public/`, begins with the
   PNG magic bytes, and its IHDR width/height (big-endian at byte offsets 16/20)
   match the declared `sizes` string.
5. `public/icons/apple-touch-icon.png` exists and is a 180×180 PNG.
6. `index.html` contains the manifest link, the apple-touch-icon link, and the
   `mobile-web-app-capable` meta; the SVG favicon link is still present.

## Parity note

Add one line to `macos/MatrixCodeScreenSaver/README.md` (App icon section) noting
that the web build additionally ships a PWA manifest + apple-touch-icon around the
same shared icon render; there is no native equivalent to add (macOS has its own
icon system), so this is an intentional web-only surface.

## Out of scope

- No service worker / offline caching (the app is already self-contained; a SW
  adds no user value here).
- No live per-theme recolouring of the home-screen icon — installed icons are
  captured once by the OS and cannot update; fixed classic palette matches macOS.
- No change to the browser-tab favicon behaviour.
