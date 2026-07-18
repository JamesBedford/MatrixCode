# Professional DMG Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship one styled, signed, notarized disk image containing `MatrixCode.app` and `MatrixCode.saver` at `macos/MatrixCodeScreenSaver/build/Release/MatrixCode.dmg`.

**Architecture:** Finder reads window geometry, icon size, icon positions and the background image from a `.DS_Store` at the volume root. That file, the background PNG and the volume icon are generated once by dev-time scripts, committed under `Resources/DMG/`, and simply copied into the staging folder by the release build before its existing `hdiutil create` call. The release build therefore gains **no new dependencies** and stays fully headless.

**Tech Stack:** bash, `hdiutil`, `codesign`/`notarytool`/`stapler`, `SetFile`; Python 3 with Pillow (already used by `scripts/generate_native_icons.py`) plus `ds_store` and `mac_alias` for the dev-time layout generator only.

## Global Constraints

- Volume name is permanently `"Matrix Code"` (`build-release.sh:27`). A `.DS_Store` layout is keyed to the volume name — changing it silently breaks the layout.
- DMG filename is exactly `MatrixCode.dmg`. No version in the name. Each build overwrites the previous.
- All release output lands in `macos/MatrixCodeScreenSaver/build/Release/`. The `dist/` tree is removed entirely.
- Window content area is 700×520 points. `background.png` is rendered at 2× = 1400×1040.
- Icon size 100pt, labels on bottom, `arrangeBy: none`.
- Icon positions (window points, icon centres): `MatrixCode.app` (180, 235), `Applications` (520, 235), `MatrixCode.saver` (350, 400).
- The dev-time scripts are **never invoked by a normal build**. Their output is committed.
- Bundle contents, signing identity and notarization flow are unchanged.

## Validated Findings (do not re-litigate)

These were established experimentally before this plan was written:

1. A **committed `.DS_Store` reused on a brand-new image** correctly applies window bounds, icon size, icon positions **and the background image**, despite the fresh volume having different inodes. Confirmed visually.
2. A **Python-authored** (`ds_store` + `mac_alias`) `.DS_Store` works for this, not just a Finder-authored one. Confirmed visually.
3. The `icvp` payload **must** include `backgroundColorRed/Green/Blue = 1.0` alongside `backgroundType = 2` and `backgroundImageAlias`. Finder's own output includes them; omitting them was the original failure.
4. The background alias must be minted against a **real file on a mounted volume** — `Alias.for_file()` on a staging-folder path is not sufficient. The generator mounts a read-write image named `Matrix Code` to mint it.
5. **AppleScript's `background picture of icon view options` is unreliable** — it reports `NONE` even when a background is demonstrably applied. Do not use it to verify. Verify by opening the image and looking, or by asserting `.DS_Store` contents.

## File Structure

| File | Responsibility |
| --- | --- |
| `scripts/generate_dmg_background.py` | Dev-time. Renders the Matrix-rain backdrop → `Resources/DMG/background.png`. Imports palette/helpers from `generate_native_icons.py`. |
| `scripts/generate_dmg_layout.py` | Dev-time. Mints the alias on a temp RW volume, writes `Resources/DMG/DS_Store`, copies `MatrixCode.icns` → `Resources/DMG/VolumeIcon.icns`. |
| `macos/MatrixCodeScreenSaver/Resources/DMG/background.png` | Committed artwork (1400×1040). |
| `macos/MatrixCodeScreenSaver/Resources/DMG/DS_Store` | Committed Finder layout. |
| `macos/MatrixCodeScreenSaver/Resources/DMG/VolumeIcon.icns` | Committed volume icon. |
| `scripts/verify_dmg.sh` | Structural check of a built DMG. Used as Task 3's test and callable standalone. |
| `scripts/build-release.sh` | Modified: styling files copied in, output relocated, `dist/` retired. |

---

### Task 1: Background artwork

**Files:**
- Create: `scripts/generate_dmg_background.py`
- Create (generated): `macos/MatrixCodeScreenSaver/Resources/DMG/background.png`

**Interfaces:**
- Consumes: `scripts/generate_native_icons.py` module-level names — `BACKGROUND`, `TAIL`, `BODY`, `BRIGHT`, `HEAD`, `RAIN_GLYPHS`, `HEAD_GLYPHS`, `LIGHT_FONTS`, `HEAVY_FONTS`, `Rgb`, and functions `mix(a, b, t)`, `trail_color(t)`, `font_path(candidates)`, `safe_composite(base, tile, pos)`, `radial_layer(size, center, radius, color, peak_alpha, invert=False, falloff=1.0)`. Its `main()` is guarded by `if __name__ == "__main__"`, so importing is side-effect free.
- Produces: `WINDOW_W = 700`, `WINDOW_H = 520`, `SCALE = 2`, `ICON_POSITIONS: dict[str, tuple[int, int]]`, and `render() -> PIL.Image.Image`. Task 2 imports `WINDOW_W`, `WINDOW_H` and `ICON_POSITIONS` from this module — they are defined here so the artwork and the layout can never disagree.

- [ ] **Step 1: Write the failing test**

Create `test/test_dmg_background.py`:

```python
"""Run with: /tmp/dmgvenv/bin/python -m pytest test/test_dmg_background.py -v"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "generate_dmg_background.py"
OUT = ROOT / "macos" / "MatrixCodeScreenSaver" / "Resources" / "DMG" / "background.png"


def test_renders_at_2x_window_size():
    sys.path.insert(0, str(ROOT / "scripts"))
    import generate_dmg_background as g

    img = g.render()
    assert img.size == (g.WINDOW_W * g.SCALE, g.WINDOW_H * g.SCALE)


def test_is_deterministic():
    sys.path.insert(0, str(ROOT / "scripts"))
    import generate_dmg_background as g

    assert g.render().tobytes() == g.render().tobytes()


def test_writes_committed_artwork():
    subprocess.run([sys.executable, str(SCRIPT)], check=True)
    assert OUT.exists()
    from PIL import Image
    assert Image.open(OUT).size == (1400, 1040)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/tmp/dmgvenv/bin/python -m pytest test/test_dmg_background.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'generate_dmg_background'`

- [ ] **Step 3: Write the generator**

Create `scripts/generate_dmg_background.py`:

```python
#!/usr/bin/env python3
"""Renders the MatrixCode DMG window backdrop.

Deterministic: regenerating always produces identical bytes. Shares its palette
and drawing helpers with generate_native_icons.py so the disk image, the app
icon and the web icons stay one visual family.

Usage: python3 scripts/generate_dmg_background.py
"""
from __future__ import annotations

import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from generate_native_icons import (
    BACKGROUND,
    BRIGHT,
    HEAD,
    HEAD_GLYPHS,
    HEAVY_FONTS,
    LIGHT_FONTS,
    RAIN_GLYPHS,
    font_path,
    radial_layer,
    safe_composite,
    trail_color,
)

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "macos" / "MatrixCodeScreenSaver" / "Resources" / "DMG"
OUT_PATH = OUT_DIR / "background.png"

# Finder window content area, in points. The PNG is rendered at 2x so it stays
# crisp on Retina; Finder scales it to the window.
WINDOW_W = 700
WINDOW_H = 520
SCALE = 2

# Icon centres in window points. Task 2 reads these so artwork and layout agree.
ICON_POSITIONS = {
    "MatrixCode.app": (180, 235),
    "Applications": (520, 235),
    "MatrixCode.saver": (350, 400),
}

SEED = 0x4D58444D  # "MXDM"
CELL = 26          # glyph cell size in points
TITLE = "MATRIX CODE"
CAPTION = "Double-click to install the screen saver"


def _rain_layer(size: tuple[int, int], rng: random.Random) -> Image.Image:
    """Columns of glyphs with exponentially decaying trails, as in the rain sim."""
    w, h = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cell = CELL * SCALE
    glyph_font = ImageFont.truetype(str(font_path(LIGHT_FONTS)), int(cell * 0.86))
    head_font = ImageFont.truetype(str(font_path(HEAVY_FONTS)), int(cell * 0.86))

    for col in range(0, w // cell + 1):
        x = col * cell
        head_row = rng.uniform(-14, h / cell + 6)
        trail = rng.randint(7, 20)
        for i in range(trail):
            row = head_row - i
            y = row * cell
            if y < -cell or y > h:
                continue
            t = 1.0 - (i / trail)
            is_head = i == 0
            glyph = rng.choice(HEAD_GLYPHS if is_head else RAIN_GLYPHS)
            color = HEAD if is_head else trail_color(t)
            # Trails fade out; the head stays bright.
            alpha = int(235 * (t ** 1.5)) if not is_head else 245
            draw.text((x, y), glyph, font=head_font if is_head else glyph_font,
                      fill=color + (alpha,))
    return layer


def _wordmark(size: tuple[int, int]) -> Image.Image:
    """Glowing MATRIX CODE title centred in the upper band."""
    w, _ = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    font = ImageFont.truetype(str(font_path(HEAVY_FONTS)), 34 * SCALE)
    box = draw.textbbox((0, 0), TITLE, font=font)
    x = (w - (box[2] - box[0])) // 2 - box[0]
    y = 52 * SCALE
    draw.text((x, y), TITLE, font=font, fill=BRIGHT + (255,))

    glow = layer.filter(ImageFilter.GaussianBlur(9 * SCALE))
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    out.alpha_composite(glow)
    out.alpha_composite(glow)
    out.alpha_composite(layer)
    return out


def _arrow(size: tuple[int, int]) -> Image.Image:
    """Chevron pointing from the app icon toward the Applications folder."""
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    y = ICON_POSITIONS["MatrixCode.app"][1] * SCALE
    x0 = (ICON_POSITIONS["MatrixCode.app"][0] + 78) * SCALE
    x1 = (ICON_POSITIONS["Applications"][0] - 78) * SCALE
    draw.line([(x0, y), (x1 - 16 * SCALE, y)], fill=BRIGHT + (170,), width=3 * SCALE)
    draw.polygon(
        [(x1, y), (x1 - 18 * SCALE, y - 11 * SCALE), (x1 - 18 * SCALE, y + 11 * SCALE)],
        fill=BRIGHT + (210,),
    )
    return layer


def _caption(size: tuple[int, int]) -> Image.Image:
    """The saver has no drag target, so the gesture is spelled out instead."""
    w, _ = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    font = ImageFont.truetype(str(font_path(LIGHT_FONTS)), 13 * SCALE)
    box = draw.textbbox((0, 0), CAPTION, font=font)
    x = (w - (box[2] - box[0])) // 2 - box[0]
    draw.text((x, 466 * SCALE), CAPTION, font=font, fill=BRIGHT + (200,))
    return layer


def render() -> Image.Image:
    size = (WINDOW_W * SCALE, WINDOW_H * SCALE)
    rng = random.Random(SEED)

    base = Image.new("RGBA", size, BACKGROUND + (255,))
    safe_composite(base, _rain_layer(size, rng), (0, 0))

    # Dim the middle so icon labels stay legible over the rain.
    base.alpha_composite(
        radial_layer(size, (size[0] / 2, size[1] / 2), size[0] * 0.62,
                     BACKGROUND, 215, falloff=1.5)
    )
    base.alpha_composite(_wordmark(size))
    base.alpha_composite(_arrow(size))
    base.alpha_composite(_caption(size))
    return base.convert("RGB").convert("RGBA")


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    render().convert("RGB").save(OUT_PATH)
    print(f"DMG background written to {OUT_PATH}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/tmp/dmgvenv/bin/python -m pytest test/test_dmg_background.py -v`
Expected: 3 passed.

- [ ] **Step 5: Visual review — STOP HERE**

Run: `open macos/MatrixCodeScreenSaver/Resources/DMG/background.png`

Show the rendered image to the user and get explicit approval before committing.
Automated tests cannot judge "beautiful"; this gate is the only thing that can.
If rejected, adjust and repeat this step. Do not proceed to Step 6 without approval.

- [ ] **Step 6: Commit**

```bash
git add scripts/generate_dmg_background.py test/test_dmg_background.py \
        macos/MatrixCodeScreenSaver/Resources/DMG/background.png
git commit -m "Add the DMG window background artwork and its generator"
```

---

### Task 2: Finder layout and volume icon

**Files:**
- Create: `scripts/generate_dmg_layout.py`
- Create (generated): `macos/MatrixCodeScreenSaver/Resources/DMG/DS_Store`
- Create (generated): `macos/MatrixCodeScreenSaver/Resources/DMG/VolumeIcon.icns`

**Interfaces:**
- Consumes: `WINDOW_W`, `WINDOW_H`, `ICON_POSITIONS` from `generate_dmg_background`.
- Produces: the committed `DS_Store` that Task 3 copies into the volume as `.DS_Store`.

**Dependencies:** this script needs `ds_store` and `mac_alias`, which are NOT in the
release build's dependency set. Install them into a throwaway venv:

```bash
python3 -m venv /tmp/dmgvenv
/tmp/dmgvenv/bin/pip install ds_store mac_alias pillow pytest
```

- [ ] **Step 1: Write the failing test**

Create `test/test_dmg_layout.py`:

```python
"""Run with: /tmp/dmgvenv/bin/python -m pytest test/test_dmg_layout.py -v"""
import plistlib
from pathlib import Path

from ds_store import DSStore

ROOT = Path(__file__).resolve().parents[1]
DS = ROOT / "macos" / "MatrixCodeScreenSaver" / "Resources" / "DMG" / "DS_Store"


def _icvp():
    with DSStore.open(str(DS), "r") as d:
        for entry in d:
            if entry.filename == "." and entry.code in (b"icvp", "icvp"):
                value = entry.value
                if isinstance(value, (bytes, bytearray)):
                    return plistlib.loads(bytes(value))
                return value
    raise AssertionError("no icvp entry")


def test_background_is_a_picture_with_an_alias():
    icvp = _icvp()
    # backgroundType 2 == picture. The colour keys must be present alongside it;
    # Finder ignores the background image without them.
    assert icvp["backgroundType"] == 2
    assert icvp["backgroundColorRed"] == 1.0
    assert icvp["backgroundColorGreen"] == 1.0
    assert icvp["backgroundColorBlue"] == 1.0
    assert len(bytes(icvp["backgroundImageAlias"])) > 100


def test_icon_metrics():
    icvp = _icvp()
    assert icvp["iconSize"] == 100.0
    assert icvp["labelOnBottom"] is True
    assert icvp["arrangeBy"] == "none"


def test_icon_positions_match_the_artwork():
    import sys
    sys.path.insert(0, str(ROOT / "scripts"))
    from generate_dmg_background import ICON_POSITIONS

    with DSStore.open(str(DS), "r") as d:
        found = {e.filename: e.value for e in d if e.code in (b"Iloc", "Iloc")}
    for name, pos in ICON_POSITIONS.items():
        assert found[name][:2] == pos, f"{name} at {found.get(name)} not {pos}"


def test_window_geometry():
    with DSStore.open(str(DS), "r") as d:
        bwsp = next(e.value for e in d
                    if e.filename == "." and e.code in (b"bwsp", "bwsp"))
    if isinstance(bwsp, (bytes, bytearray)):
        bwsp = plistlib.loads(bytes(bwsp))
    assert "{700, 520}" in bwsp["WindowBounds"]
    assert bwsp["ShowToolbar"] is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/tmp/dmgvenv/bin/python -m pytest test/test_dmg_layout.py -v`
Expected: FAIL — `DS_Store` does not exist.

- [ ] **Step 3: Write the layout generator**

Create `scripts/generate_dmg_layout.py`:

```python
#!/usr/bin/env python3
"""Generates the committed Finder layout for the MatrixCode DMG.

The background is stored as an *alias*, which can only be minted against a real
file on a mounted volume — so this builds a throwaway read-write image named
"Matrix Code", writes the layout onto it, and copies the resulting .DS_Store out.

The volume name matters: Finder keys a layout to it. It must match VOLUME_NAME in
scripts/build-release.sh.

Requires ds_store + mac_alias (not needed by the release build):
    python3 -m venv /tmp/dmgvenv
    /tmp/dmgvenv/bin/pip install ds_store mac_alias pillow
    /tmp/dmgvenv/bin/python scripts/generate_dmg_layout.py
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_dmg_background import ICON_POSITIONS, WINDOW_H, WINDOW_W  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "macos" / "MatrixCodeScreenSaver" / "Resources"
DMG_DIR = RESOURCES / "DMG"
BACKGROUND = DMG_DIR / "background.png"
OUT_DS_STORE = DMG_DIR / "DS_Store"
OUT_VOLUME_ICON = DMG_DIR / "VolumeIcon.icns"
SOURCE_ICNS = RESOURCES / "MatrixCode.icns"

VOLUME_NAME = "Matrix Code"  # must match build-release.sh


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=True, capture_output=True, text=True)


def attach(dmg: Path) -> Path:
    out = run("hdiutil", "attach", str(dmg), "-nobrowse", "-noautoopen").stdout
    for line in out.splitlines():
        if "/Volumes/" in line:
            return Path("/Volumes/" + line.split("/Volumes/")[1].strip())
    raise RuntimeError(f"could not find mount point in:\n{out}")


def detach(mount: Path) -> None:
    for _ in range(4):
        try:
            run("hdiutil", "detach", str(mount), "-quiet")
            return
        except subprocess.CalledProcessError:
            subprocess.run(["sync"], check=False)
            time.sleep(1)
    subprocess.run(["hdiutil", "detach", str(mount), "-force", "-quiet"], check=False)


def write_layout(volume: Path) -> None:
    alias = Alias.for_file(str(volume / ".background" / "background.png"))
    icvp = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,               # 2 == picture
        # Finder writes these alongside a picture background and ignores the
        # image if they are absent.
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "backgroundImageAlias": alias.to_bytes(),
        "iconSize": 100.0,
        "gridSpacing": 100.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "textSize": 12.0,
        "labelOnBottom": True,
        "showItemInfo": False,
        "showIconPreview": True,
        "arrangeBy": "none",
    }
    bwsp = {
        "WindowBounds": f"{{{{200, 200}}, {{{WINDOW_W}, {WINDOW_H}}}}}",
        "ShowSidebar": False,
        "ShowToolbar": False,
        "ShowStatusBar": False,
        "ShowPathbar": False,
        "SidebarWidth": 0,
    }
    with DSStore.open(str(volume / ".DS_Store"), "w+") as d:
        d["."]["bwsp"] = bwsp
        d["."]["icvp"] = icvp
        for name, position in ICON_POSITIONS.items():
            d[name]["Iloc"] = position


def main() -> None:
    if not BACKGROUND.exists():
        raise SystemExit("Run generate_dmg_background.py first.")
    if not SOURCE_ICNS.exists():
        raise SystemExit(f"Missing {SOURCE_ICNS}")

    DMG_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copy(SOURCE_ICNS, OUT_VOLUME_ICON)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        stage = tmp_path / "stage"
        (stage / ".background").mkdir(parents=True)
        shutil.copy(BACKGROUND, stage / ".background" / "background.png")
        # Placeholders only — the layout stores positions by name, and the real
        # bundles are supplied by the release build.
        for name in ICON_POSITIONS:
            if name == "Applications":
                (stage / name).symlink_to("/Applications")
            else:
                (stage / name).mkdir()
                (stage / name / ".placeholder").write_text("")

        dmg = tmp_path / "layout.dmg"
        run("hdiutil", "create", "-volname", VOLUME_NAME, "-srcfolder", str(stage),
            "-ov", "-format", "UDRW", "-size", "80m", "-quiet", str(dmg))
        mount = attach(dmg)
        try:
            write_layout(mount)
            subprocess.run(["sync"], check=False)
            shutil.copy(mount / ".DS_Store", OUT_DS_STORE)
        finally:
            detach(mount)

    print(f"Layout written to {OUT_DS_STORE} ({OUT_DS_STORE.stat().st_size} bytes)")
    print(f"Volume icon written to {OUT_VOLUME_ICON}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Generate the layout and run the tests**

```bash
/tmp/dmgvenv/bin/python scripts/generate_dmg_layout.py
/tmp/dmgvenv/bin/python -m pytest test/test_dmg_layout.py -v
```

Expected: layout written, 4 passed.

- [ ] **Step 5: Commit**

```bash
git add scripts/generate_dmg_layout.py test/test_dmg_layout.py \
        macos/MatrixCodeScreenSaver/Resources/DMG/DS_Store \
        macos/MatrixCodeScreenSaver/Resources/DMG/VolumeIcon.icns
git commit -m "Add the committed DMG Finder layout and volume icon"
```

---

### Task 3: Wire styling into the release build and retire dist/

**Files:**
- Create: `scripts/verify_dmg.sh`
- Modify: `scripts/build-release.sh` (see per-step line references)
- Modify: `macos/MatrixCodeScreenSaver/.gitignore`
- Modify: `macos/MatrixCodeScreenSaver/README.md`

**Interfaces:**
- Consumes: `Resources/DMG/{DS_Store,background.png,VolumeIcon.icns}` from Tasks 1–2.
- Produces: `macos/MatrixCodeScreenSaver/build/Release/MatrixCode.dmg`.

- [ ] **Step 1: Write the verification script**

Create `scripts/verify_dmg.sh` and `chmod +x` it:

```bash
#!/usr/bin/env bash
#
# Structural check of a built MatrixCode DMG. Mounts it, asserts it carries both
# products and the styling files, then detaches.
#
# Usage: ./scripts/verify_dmg.sh path/to/MatrixCode.dmg

set -euo pipefail

DMG="${1:?Usage: verify_dmg.sh <path-to-dmg>}"
[[ -f "${DMG}" ]] || { printf 'No such DMG: %s\n' "${DMG}" >&2; exit 1; }

MOUNT=""
cleanup() {
    if [[ -n "${MOUNT}" && -d "${MOUNT}" ]]; then
        hdiutil detach "${MOUNT}" -quiet 2>/dev/null \
            || hdiutil detach "${MOUNT}" -force -quiet 2>/dev/null || true
    fi
}
trap cleanup EXIT

MOUNT="$(hdiutil attach "${DMG}" -nobrowse -noautoopen -readonly \
    | grep -o '/Volumes/.*' | head -1)"
[[ -n "${MOUNT}" ]] || { printf 'Could not mount %s\n' "${DMG}" >&2; exit 1; }

failures=0
check() {
    if [[ -e "${MOUNT}/$1" ]]; then
        printf '  ok      %s\n' "$1"
    else
        printf '  MISSING %s\n' "$1"
        failures=$((failures + 1))
    fi
}

printf 'Verifying %s (mounted at %s)\n' "$(basename "${DMG}")" "${MOUNT}"
check "MatrixCode.app"
check "MatrixCode.saver"
check "Applications"
check ".DS_Store"
check ".background/background.png"
check ".VolumeIcon.icns"

[[ -L "${MOUNT}/Applications" ]] || {
    printf '  Applications is not a symlink\n'; failures=$((failures + 1)); }

volume_name="$(basename "${MOUNT}")"
if [[ "${volume_name}" != "Matrix Code" ]]; then
    printf '  Volume name is "%s", expected "Matrix Code" — the committed\n' "${volume_name}"
    printf '  layout is keyed to that name and will not apply.\n'
    failures=$((failures + 1))
fi

if [[ "${failures}" -eq 0 ]]; then
    printf '\nDMG structure OK\n'
else
    printf '\n%d problem(s) found\n' "${failures}" >&2
    exit 1
fi
```

- [ ] **Step 2: Run it against a DMG to confirm it fails cleanly**

Run: `./scripts/verify_dmg.sh /nonexistent.dmg`
Expected: `No such DMG: /nonexistent.dmg`, exit 1.

- [ ] **Step 3: Add the styling constants to build-release.sh**

After `readonly VOLUME_NAME="Matrix Code"` (`build-release.sh:27`), add:

```bash
readonly DMG_NAME="MatrixCode.dmg"
```

Then after `readonly DIST_DIR=...` is removed (Step 5), add near the other path
constants (around `build-release.sh:124-128`):

```bash
readonly DMG_RESOURCES="${NATIVE_DIR}/Resources/DMG"
```

- [ ] **Step 4: Replace the DMG build block**

Replace `build-release.sh:383-428` (the whole `if [[ "${LOCAL_SIGNING}" == false ]]` DMG block) with:

```bash
readonly DMG_STAGE="${TEMP_ROOT}/dmg-stage"
readonly DMG_PATH="${PACKAGE_STAGE}/${DMG_NAME}"
mkdir -p "${DMG_STAGE}/.background"
ditto "${PACKAGE_STAGE}/MatrixCode.app" "${DMG_STAGE}/MatrixCode.app"
ditto "${PACKAGE_STAGE}/MatrixCode.saver" "${DMG_STAGE}/MatrixCode.saver"
ln -s /Applications "${DMG_STAGE}/Applications"

# Finder reads the window geometry, icon positions and background from these.
# They are generated by scripts/generate_dmg_{background,layout}.py and committed;
# a normal build only copies them in, so it needs no extra tooling.
for styling in DS_Store background.png VolumeIcon.icns; do
    [[ -f "${DMG_RESOURCES}/${styling}" ]] \
        || fail "Missing DMG styling resource: ${DMG_RESOURCES}/${styling}"
done
cp "${DMG_RESOURCES}/DS_Store" "${DMG_STAGE}/.DS_Store"
cp "${DMG_RESOURCES}/background.png" "${DMG_STAGE}/.background/background.png"
cp "${DMG_RESOURCES}/VolumeIcon.icns" "${DMG_STAGE}/.VolumeIcon.icns"
"${DEVELOPER_DIR}/usr/bin/SetFile" -a C "${DMG_STAGE}" \
    || fail "Could not set the custom-icon attribute on the DMG staging folder."

info "Building styled DMG"
hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${DMG_STAGE}" \
    -ov -format UDZO -quiet "${DMG_PATH}" \
    || fail "DMG creation failed"

if [[ "${LOCAL_SIGNING}" == true ]]; then
    codesign --force --sign - "${DMG_PATH}" >/dev/null
else
    codesign_with_retry "${DMG_NAME}" \
        --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG_PATH}"

    if [[ "${SKIP_NOTARIZE}" == false ]]; then
        info "Notarizing DMG"
        xcrun notarytool submit "${DMG_PATH}" \
            --keychain-profile "${NOTARY_PROFILE}" --wait \
            || fail "DMG notarization failed"
        xcrun stapler staple "${DMG_PATH}" || fail "Stapling DMG failed"
    fi

    codesign --verify --verbose=2 "${DMG_PATH}" \
        || fail "DMG signature verification failed"
    if [[ "${SKIP_NOTARIZE}" == false ]]; then
        assessment="$(spctl -a -vvv -t install "${DMG_PATH}" 2>&1 || true)"
        grep -q "source=Notarized Developer ID" <<<"${assessment}" \
            || fail "Gatekeeper did not accept the notarized DMG: ${assessment}"
        xcrun stapler validate "${DMG_PATH}" >/dev/null \
            || fail "DMG staple validation failed"
    fi
fi

info "Verifying DMG structure"
"${REPO_ROOT}/scripts/verify_dmg.sh" "${DMG_PATH}" || fail "DMG structure check failed"

checksum_files+=("${DMG_NAME}")
```

Note this block is now **outside** any `LOCAL_SIGNING` guard, so `./build.sh`
produces a DMG too — that is the only way the styling is testable without a
Developer ID identity and a notarization round-trip.

- [ ] **Step 5: Delete the dist/ machinery**

Remove each of these from `build-release.sh`:

- `readonly DIST_DIR="${NATIVE_DIR}/dist"` (line 127)
- `DIST_PUBLISH_DIR=""`, `DIST_BACKUP_DIR=""`, `DIST_OUTPUT_DIR=""` (lines 163-165)
- the two `DIST_*` arms inside `cleanup()` (lines 177-185)
- `readonly DIST_STAGE="${TEMP_ROOT}/dist"` and `"${DIST_STAGE}"` from the `mkdir -p` (lines 205-206)
- the entire `if [[ "${LOCAL_SIGNING}" == false ]]` publish block (lines 462-493)
- in the summary, the `Distribution` / `DMG` / `Release SHA-256` lines (lines 507-515)

Move `hdiutil`, `security`, `spctl`, `xcrun` out of the `LOCAL_SIGNING == false`
guard at lines 142-145 into the unconditional required-command loop at line 137,
since `hdiutil` is now always needed. Keep the identity and notary-profile checks
inside the guard.

Update the usage text (lines 43, 50-56):

```
  --local-signing              Ad-hoc sign for local use (used by build.sh).
```

```
Outputs:
  macos/MatrixCodeScreenSaver/build/Debug/
  macos/MatrixCodeScreenSaver/build/Release/

Release builds also include matching dSYMs and a UUID report. The styled
MatrixCode.dmg is Developer ID signed and notarized unless --local-signing or
--skip-notarize is supplied.
```

- [ ] **Step 6: Add the DMG to the summary and legacy symlinks**

In the legacy-symlink loop (line 456), add `MatrixCode.dmg`:

```bash
    for legacy_product in \
        MatrixCode.app MatrixCode.app.zip MatrixCode.saver MatrixCode.saver.zip \
        MatrixCode.dmg; do
```

In the summary block after line 501, add:

```bash
printf '  DMG            %s\n' "${OUTPUT_DIR}/${DMG_NAME}"
```

- [ ] **Step 7: Update the existing Vitest build-script test**

`test/buildReleaseScript.test.ts:44` asserts the usage text contains
`"MatrixCodeScreenSaver/dist"`, which this task deletes. Change that assertion to
expect the DMG's new home instead:

```ts
    expect(result.stdout).toContain("build/Release");
    expect(result.stdout).toContain("MatrixCode.dmg");
```

Then run the suite to confirm nothing else in it depended on `dist/`:

Run: `npm test -- test/buildReleaseScript.test.ts`
Expected: all tests pass.

- [ ] **Step 8: Update .gitignore and README**

In `macos/MatrixCodeScreenSaver/.gitignore`, delete the `dist/` line.

In `macos/MatrixCodeScreenSaver/README.md`, document the new output path and the
regeneration workflow:

```markdown
## Disk image

`./build.sh` and `scripts/build-release.sh` produce a styled
`build/Release/MatrixCode.dmg` containing both `MatrixCode.app` and
`MatrixCode.saver`. Drag the app to `Applications`; double-click the saver to
install it (a screen saver cannot have a drag target, because
`~/Library/Screen Savers` is a per-user path).

The window's background, size and icon positions come from three committed files
in `Resources/DMG/` — a normal build only copies them in and needs no extra
tooling. To change the look:

    python3 scripts/generate_dmg_background.py       # artwork
    python3 -m venv /tmp/dmgvenv && /tmp/dmgvenv/bin/pip install ds_store mac_alias pillow
    /tmp/dmgvenv/bin/python scripts/generate_dmg_layout.py   # window + icon layout

Then commit the regenerated `Resources/DMG/` files. The volume name must stay
`Matrix Code`: Finder keys the layout to it.
```

- [ ] **Step 9: Build and verify end-to-end**

```bash
cd macos/MatrixCodeScreenSaver && ./build.sh
```

Expected: build succeeds; summary lists `DMG  .../build/Release/MatrixCode.dmg`;
`Verifying DMG structure` reports all `ok` lines.

Then confirm `dist/` is gone and the DMG is where it should be:

```bash
test ! -d macos/MatrixCodeScreenSaver/dist && echo "dist/ retired"
ls -la macos/MatrixCodeScreenSaver/build/Release/MatrixCode.dmg
./scripts/verify_dmg.sh macos/MatrixCodeScreenSaver/build/Release/MatrixCode.dmg
```

- [ ] **Step 10: Visual review — STOP HERE**

```bash
open macos/MatrixCodeScreenSaver/build/Release/MatrixCode.dmg
```

Confirm with the user that the mounted window shows the artwork, is 700×520, and
has all three icons in position. Note that `SetFile -a C` on the staging folder
may not carry the custom-icon bit through `hdiutil create`; if the volume icon is
generic, restyle by building `-format UDRW`, mounting, running
`SetFile -a C "${MOUNT}"`, detaching, then `hdiutil convert -format UDZO`. Treat a
generic volume icon as a defect to fix, not as acceptable.

- [ ] **Step 11: Commit**

```bash
git add scripts/build-release.sh scripts/verify_dmg.sh test/buildReleaseScript.test.ts \
        macos/MatrixCodeScreenSaver/.gitignore \
        macos/MatrixCodeScreenSaver/README.md
git commit -m "Build a styled MatrixCode.dmg into build/Release and retire dist/"
```

---

## Self-Review

**Spec coverage:** output layout → Task 3 Steps 4-6; `.DS_Store`/background/volume-icon
trio → Tasks 1-2, copied in at Task 3 Step 4; dev-time generation → Tasks 1-2;
artwork → Task 1; two install gestures → Task 1 `_caption`/`_arrow` + README;
testing → Task 1 pytest, Task 2 pytest, Task 3 `verify_dmg.sh` + two visual gates;
preserved signing/notarization/staple/checksums → Task 3 Step 4.

**Deviation from the spec, flagged deliberately:** the spec left unstated which
invocations produce a DMG; `--local-signing` previously produced none. This plan
has it produce an ad-hoc-signed DMG, because otherwise the styling cannot be
tested without a Developer ID identity and a notarization round-trip — and
`./build.sh` giving you a DMG matches the original request.

**Placeholder scan:** none — every step carries its literal content.

**Type consistency:** `WINDOW_W`/`WINDOW_H`/`ICON_POSITIONS` are defined once in
`generate_dmg_background.py` and imported by `generate_dmg_layout.py` and
`test_dmg_layout.py`. `DMG_NAME` is used consistently across the build script.
`VOLUME_NAME` is asserted equal in `verify_dmg.sh` and the layout generator.
