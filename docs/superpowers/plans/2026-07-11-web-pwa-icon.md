# Web PWA / Installable-Icon Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the browser MatrixCode an installable PWA whose home-screen / touch icon is the same seeded cinematic render the macOS app uses, while the browser tab keeps its live SVG favicon.

**Architecture:** Reuse the existing deterministic renderer in `scripts/generate_native_icons.py` to emit five web PNGs into `public/icons/`; ship a hand-written `public/manifest.webmanifest`; wire an apple-touch-icon, manifest link, and PWA meta into `index.html`. Assets are plain relative sibling files, exactly like the existing `public/favicon.svg`.

**Tech Stack:** Python 3 + Pillow 12 (icon generation), static JSON manifest, Vite (`vite-plugin-singlefile`) build, Vitest (Node env) for verification.

## Global Constraints

- Icon render is deterministic — one seed drives both macOS and web icons; web and macOS icons must be the same image (no separate art).
- Manifest/theme colors must equal the classic preset background from `src/config/colorPresets.ts` (`#0D0208`), not a free-floating literal.
- Reference all web assets with the same path style as the existing `<link rel="icon" ... href="/favicon.svg">` (root-absolute in source; Vite rewrites to relative at build).
- No new npm dependencies. Tests run in Node env (no DOM).
- Commit messages: concise single line, no `Co-Authored-By`. Stage explicit paths only.
- Do all work in the `worktree-web-pwa-icon` worktree; integrate to `main` by fast-forward at the end.

---

### Task 1: Emit web icons from the shared renderer

**Files:**
- Modify: `scripts/generate_native_icons.py` (add `WEB_ICONS` const near the other path consts ~line 30; add `IconRenderer.master()` and refactor `IconRenderer.render()` ~line 421-432; add `write_web_icons()` after `write_preview()` ~line 483; call it from `main()` ~line 491-493)
- Create (generated): `public/icons/apple-touch-icon.png`, `public/icons/icon-192.png`, `public/icons/icon-512.png`, `public/icons/icon-192-maskable.png`, `public/icons/icon-512-maskable.png`

**Interfaces:**
- Consumes: existing `render_master_art() -> Image.Image` (full-bleed square scene) and `compose_canvas(art, size) -> Image.Image` (Big Sur inset).
- Produces: `write_web_icons(renderer: IconRenderer) -> None` writing the five PNGs; `IconRenderer.master() -> Image.Image` returning the cached master art. Maskable + apple-touch icons are opaque full-bleed squares (`render_master_art`); `any` icons are the Big Sur inset (`compose_canvas`).

- [ ] **Step 1: Add the web icons output directory constant**

In the path-constants block near the top (after `APPICONSET = ...`), add:

```python
WEB_ICONS = ROOT / "public" / "icons"
```

- [ ] **Step 2: Give `IconRenderer` a public cached-master accessor**

Replace the `IconRenderer.render` body so the master is fetched through a reusable method:

```python
class IconRenderer:
    """Renders any canvas size, caching the master artwork across sizes."""

    def __init__(self) -> None:
        self._master: Image.Image | None = None

    def master(self) -> Image.Image:
        if self._master is None:
            self._master = render_master_art()
        return self._master

    def render(self, size: int) -> Image.Image:
        if size <= 64:
            return render_small_icon(size)
        return compose_canvas(self.master(), size)
```

- [ ] **Step 3: Add `write_web_icons()`**

Add after `write_preview()`:

```python
def write_web_icons(renderer: IconRenderer) -> None:
    """Emit the web PWA icon set from the same seeded artwork as the macOS icons.

    Maskable + apple-touch icons are opaque full-bleed squares so iOS/Android
    apply their own corner mask cleanly; the `any`-purpose icons use the Big Sur
    inset so they look polished (and match the macOS Dock icon) when shown
    un-masked.
    """
    WEB_ICONS.mkdir(parents=True, exist_ok=True)
    master = renderer.master()
    for size, name in ((180, "apple-touch-icon.png"),
                       (192, "icon-192-maskable.png"),
                       (512, "icon-512-maskable.png")):
        master.resize((size, size), Image.LANCZOS).convert("RGB").save(WEB_ICONS / name)
    for size, name in ((192, "icon-192.png"), (512, "icon-512.png")):
        compose_canvas(master, size).save(WEB_ICONS / name)
    print(f"Web icons written to {WEB_ICONS}")
```

- [ ] **Step 4: Call it from `main()`**

In `main()`, after `write_icns(renderer)` and before the function ends, add:

```python
    write_web_icons(renderer)
```

- [ ] **Step 5: Run the generator**

Run: `python3 scripts/generate_native_icons.py`
Expected: prints `Web icons written to .../public/icons` with no traceback.

- [ ] **Step 6: Verify the five PNGs exist at the right dimensions and modes**

Run:

```bash
python3 - <<'PY'
from PIL import Image
from pathlib import Path
base = Path("public/icons")
expected = {
    "apple-touch-icon.png": (180, 180),
    "icon-192-maskable.png": (192, 192),
    "icon-512-maskable.png": (512, 512),
    "icon-192.png": (192, 192),
    "icon-512.png": (512, 512),
}
for name, size in expected.items():
    im = Image.open(base / name)
    assert im.size == size, (name, im.size)
    print(f"{name}: {im.size} {im.mode}")
print("OK")
PY
```

Expected: five lines then `OK`. apple-touch and maskable are mode `RGB`; `icon-192.png`/`icon-512.png` are `RGBA`.

- [ ] **Step 7: Confirm the generator did not churn the macOS assets**

Run: `git status --short macos/`
Expected: no output (deterministic render → byte-identical macOS PNGs/icns).

- [ ] **Step 8: Commit**

```bash
git add scripts/generate_native_icons.py public/icons
git commit -m "Generate web PWA icon set from the shared cinematic renderer"
```

---

### Task 2: Manifest, HTML wiring, and automated tests

**Files:**
- Create: `public/manifest.webmanifest`
- Create: `test/webIcons.test.ts`
- Modify: `index.html` (head, after the existing favicon `<link>` and after the `theme-color` meta)

**Interfaces:**
- Consumes: the five PNGs from Task 1; `getPreset` from `src/config/colorPresets.ts`.
- Produces: `public/manifest.webmanifest` listing the four `192/512 × any/maskable` icons; index.html links (`apple-touch-icon`, `manifest`) and PWA metas.

- [ ] **Step 1: Write the test**

Create `test/webIcons.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { getPreset } from "../src/config/colorPresets.ts";

const ROOT = fileURLToPath(new URL("../", import.meta.url));
const read = (rel: string): Buffer => readFileSync(ROOT + rel);

/** Normalized [0..1] RGB tuple -> #rrggbb. */
function toHex(rgb: readonly [number, number, number]): string {
  const c = (n: number): string =>
    Math.round(Math.max(0, Math.min(1, n)) * 255)
      .toString(16)
      .padStart(2, "0");
  return `#${c(rgb[0])}${c(rgb[1])}${c(rgb[2])}`;
}

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** Read a PNG's pixel dimensions from its IHDR chunk. */
function pngSize(buf: Buffer): { width: number; height: number } {
  expect(buf.subarray(0, 8).equals(PNG_MAGIC)).toBe(true);
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

interface ManifestIcon {
  src: string;
  sizes: string;
  type: string;
  purpose?: string;
}
interface Manifest {
  name: string;
  short_name: string;
  start_url: string;
  display: string;
  background_color: string;
  theme_color: string;
  icons: ManifestIcon[];
}

const manifest: Manifest = JSON.parse(read("public/manifest.webmanifest").toString("utf8"));

describe("web app manifest", () => {
  it("declares the required top-level fields", () => {
    expect(manifest.name).toBe("MatrixCode");
    expect(manifest.short_name).toBe("Matrix");
    expect(typeof manifest.start_url).toBe("string");
    expect(manifest.display).toBe("standalone");
    expect(Array.isArray(manifest.icons)).toBe(true);
  });

  it("uses the classic preset background for theme and background colors", () => {
    const bg = toHex(getPreset("classic").background);
    expect(manifest.theme_color.toLowerCase()).toBe(bg);
    expect(manifest.background_color.toLowerCase()).toBe(bg);
  });

  it("covers 192 and 512 in both any and maskable purposes", () => {
    const has = (sizes: string, purpose: string): boolean =>
      manifest.icons.some(
        (i) => i.sizes === sizes && (i.purpose ?? "any").split(" ").includes(purpose),
      );
    expect(has("192x192", "any")).toBe(true);
    expect(has("512x512", "any")).toBe(true);
    expect(has("192x192", "maskable")).toBe(true);
    expect(has("512x512", "maskable")).toBe(true);
  });

  it("points every icon at a real PNG whose pixels match its declared size", () => {
    for (const icon of manifest.icons) {
      expect(icon.type).toBe("image/png");
      const [w, h] = icon.sizes.split("x").map(Number);
      const actual = pngSize(read(`public/${icon.src}`));
      expect({ src: icon.src, ...actual }).toEqual({ src: icon.src, width: w, height: h });
    }
  });
});

describe("apple-touch-icon", () => {
  it("is a 180x180 PNG", () => {
    expect(pngSize(read("public/icons/apple-touch-icon.png"))).toEqual({
      width: 180,
      height: 180,
    });
  });
});

describe("index.html icon wiring", () => {
  const html = read("index.html").toString("utf8");

  it("links the manifest and apple-touch-icon and keeps the svg favicon", () => {
    expect(html).toContain('rel="manifest"');
    expect(html).toContain("manifest.webmanifest");
    expect(html).toContain('rel="apple-touch-icon"');
    expect(html).toContain("icons/apple-touch-icon.png");
    expect(html).toContain('rel="icon"');
    expect(html).toContain("favicon.svg");
  });

  it("declares the app is installable / web-app capable", () => {
    expect(html).toContain('name="mobile-web-app-capable"');
    expect(html).toContain('name="apple-mobile-web-app-capable"');
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx vitest run test/webIcons.test.ts`
Expected: FAIL — `public/manifest.webmanifest` does not exist yet, so the top-level `read(...)` throws `ENOENT` and the suite errors out.

- [ ] **Step 3: Create the manifest**

Create `public/manifest.webmanifest`:

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

- [ ] **Step 4: Wire the head of `index.html`**

After the existing `<link rel="icon" type="image/svg+xml" href="/favicon.svg" />` line add:

```html
    <link rel="apple-touch-icon" href="/icons/apple-touch-icon.png" />
    <link rel="manifest" href="/manifest.webmanifest" />
```

After the existing `<meta name="theme-color" content="#0D0208" />` line add:

```html
    <meta name="mobile-web-app-capable" content="yes" />
    <meta name="apple-mobile-web-app-capable" content="yes" />
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
    <meta name="apple-mobile-web-app-title" content="Matrix" />
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npx vitest run test/webIcons.test.ts`
Expected: PASS (all specs green).

- [ ] **Step 6: Commit**

```bash
git add public/manifest.webmanifest index.html test/webIcons.test.ts
git commit -m "Add web manifest, apple-touch-icon, and PWA meta with icon tests"
```

---

### Task 3: Parity note, full verification, integrate to main

**Files:**
- Modify: `macos/MatrixCodeScreenSaver/README.md` (App icon section)

**Interfaces:**
- Consumes: everything from Tasks 1-2.
- Produces: documented web-only PWA surface; verified full test suite + production build; branch fast-forwarded into `main`.

- [ ] **Step 1: Add the parity note**

In `macos/MatrixCodeScreenSaver/README.md`, at the end of the App icon section, add a sentence:

```markdown
The browser build reuses the same generator (`scripts/generate_native_icons.py`) to emit a web PWA icon set (`public/icons/*.png`) plus a `public/manifest.webmanifest` and apple-touch-icon, so the installed web app shows the identical cinematic icon. The PWA manifest is a web-only surface with no native equivalent (macOS has its own icon system).
```

- [ ] **Step 2: Run the full test suite**

Run: `npm test`
Expected: all suites pass, including `test/webIcons.test.ts` and the unchanged `test/favicon.test.ts`.

- [ ] **Step 3: Type-check and build**

Run: `npm run build`
Expected: `tsc --noEmit` clean, Vite build succeeds, emits `dist/matrixcode.html`.

- [ ] **Step 4: Verify the build ships the manifest and icons**

Run:

```bash
find dist -type f | sort
grep -o 'rel="manifest"[^>]*' dist/matrixcode.html
grep -o 'rel="apple-touch-icon"[^>]*' dist/matrixcode.html
```

Expected: `dist/` contains `manifest.webmanifest` and `icons/` PNGs alongside `matrixcode.html`; both `<link>`s are present in the built HTML.

- [ ] **Step 5: Commit the parity note**

```bash
git add macos/MatrixCodeScreenSaver/README.md
git commit -m "Document web PWA icon delivery in native README"
```

- [ ] **Step 6: Integrate to main**

From the main working tree, fast-forward `main` to the branch tip (verify `main` still equals the pre-work sha `05f08aa` first; if it advanced, rebase the branch onto it, re-run `npm test`, then fast-forward). Then remove the worktree.

---

## Self-Review

**Spec coverage:**
- Delivery as real sibling files → Tasks 1-2 (PNGs + manifest in `public/`, relative links). ✓
- Two visual variants (full-bleed maskable/apple-touch; Big Sur inset `any`) → Task 1 `write_web_icons`. ✓
- Manifest fields + classic-preset colors → Task 2 manifest + color test. ✓
- index.html links/metas → Task 2 Step 4. ✓
- Generation via the shared script → Task 1. ✓
- Tests (manifest parse, color parity, icon existence/dimensions, apple-touch 180, html wiring) → Task 2 test. ✓
- Parity note in native README → Task 3 Step 1. ✓
- Out-of-scope items (no service worker, no live recolour, no favicon change) → not implemented, correct. ✓

**Placeholder scan:** No TBD/TODO; every code and command step is complete.

**Type consistency:** `IconRenderer.master()` defined in Task 1 Step 2 and consumed in Task 1 Step 3; `write_web_icons` signature matches its call in Step 4. Manifest icon `src` values (`icons/icon-192.png`, etc.) match the filenames written in Task 1 and read by the Task 2 test. `toHex`/`pngSize` are defined before use within the test file.
