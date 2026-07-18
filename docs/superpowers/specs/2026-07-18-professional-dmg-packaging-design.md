# Professional DMG packaging

**Date:** 2026-07-18
**Status:** Approved design

## Goal

Ship one styled disk image containing both native products — `MatrixCode.app` and
`MatrixCode.saver` — at `macos/MatrixCodeScreenSaver/build/Release/MatrixCode.dmg`.

`scripts/build-release.sh` already builds a DMG with both products and an
`/Applications` symlink, signs it, notarizes it and staples it. Two things are
wrong with it: it is a bare `hdiutil create` volume with no window styling of any
kind, and it is published to a separate `dist/` tree under a versioned filename.

This design fixes both. It is a packaging change only — no change to the app, the
saver, or their signing and notarization.

## Output layout

The `dist/` tree is retired. Everything a release produces lands in the single
existing output directory:

```
macos/MatrixCodeScreenSaver/build/Release/
├── MatrixCode.dmg              <- styled, signed, notarized, stapled
├── MatrixCode.app.zip
├── MatrixCode.saver.zip
├── MatrixCode-dSYMs.zip
├── MatrixCode-UUIDs.txt
└── SHA256SUMS.txt              <- now also covers MatrixCode.dmg
```

The DMG filename carries no version. Each release overwrites the previous DMG;
the version remains readable inside the image (both bundles' `Info.plist`) and in
the `-UUIDs.txt` sidecar.

Implementation notes:

- The DMG is created inside `PACKAGE_STAGE`, so it rides the existing atomic
  publish-swap (`build-release.sh:435-452`) rather than adding a second one.
- `MatrixCode.dmg` joins `checksum_files` so `SHA256SUMS.txt` covers it.
- The `DIST_DIR` / `DIST_STAGE` / `DIST_PUBLISH_DIR` / `DIST_BACKUP_DIR` /
  `DIST_OUTPUT_DIR` machinery is deleted, along with its `cleanup()` arms
  (`build-release.sh:177-185`), its publish block (`:462-493`) and its summary
  lines (`:507-515`). Signature, checksum and staple verification of the DMG is
  preserved — it moves into the main path rather than being dropped.
- The `Release` legacy-symlink loop at `:454-460` gains `MatrixCode.dmg`.
- `dist/` is removed from `macos/MatrixCodeScreenSaver/.gitignore`.

## How the styling is applied

Finder reads a volume's window geometry, icon size, icon positions and background
image from a `.DS_Store` at the volume root. Three files are committed under
`macos/MatrixCodeScreenSaver/Resources/DMG/`:

| Committed file    | Copied into the volume as | Purpose                          |
| ----------------- | ------------------------- | -------------------------------- |
| `DS_Store`        | `.DS_Store`               | window geometry + icon positions  |
| `background.png`  | `.background/background.png` | window backdrop                |
| `VolumeIcon.icns` | `.VolumeIcon.icns`        | volume icon in Finder / desktop   |

The build copies these three into the staging folder before the existing
`hdiutil create -srcfolder` call, which preserves them. **The build therefore
stays fully headless and gains no new dependencies** — no Finder scripting, no
AppleScript, no Automation (TCC) permission, no change to the hermetic temp-tree
approach the script already uses.

`.VolumeIcon.icns` additionally needs the volume's custom-icon bit set, via
`${DEVELOPER_DIR}/usr/bin/SetFile -a C` (verified present). Because
`hdiutil create -srcfolder` builds the image directly from a folder, the bit is
set on the staging folder's copy.

### Generating the layout

`.DS_Store` is a binary format, so it is produced by a dev-time script,
`scripts/generate_dmg_layout.py`, using the pure-Python `ds_store` and `mac_alias`
libraries. That script is **never invoked by a normal build** — it is run by hand
when the layout changes, and its output is committed. This keeps layout
regeneration repeatable and reviewable while leaving the release build
dependency-free.

Rejected alternative: `create-dmg`, or hand-rolled AppleScript, which drive Finder
to place icons. Both need a GUI session and Automation permission, which is a poor
fit for a script this hermetic, and neither is reproducible in CI.

**Constraint this imposes:** a `.DS_Store` layout is keyed to the volume name, so
`VOLUME_NAME` stays `"Matrix Code"` permanently and must not become versioned.

**Risk:** if `ds_store` cannot produce a layout that current Finder honours, the
fallback is a one-time Finder pass whose `.DS_Store` output is committed instead.
Same end state; regeneration becomes manual rather than scripted.

## The artwork

`background.png` is rendered by `scripts/generate_dmg_background.py`, a sibling of
the existing `scripts/generate_native_icons.py`, reusing that script's Matrix-rain
drawing and `trail_color` phosphor ramp so the DMG matches the app icon rather
than inventing a second visual language.

Window content area 700×480; the PNG is rendered at 2× (1400×960) so it stays
crisp on Retina.

```
┌──────────────────────────────────────────┐
│   ▒ ░ █ ▒   MATRIX CODE   ░ █ ▒ ░        │
│                                          │
│    [MatrixCode.app]  ──▶  [Applications] │
│                                          │
│         [MatrixCode.saver]               │
│    Double-click to install the saver     │
└──────────────────────────────────────────┘
```

- Dark phosphor-green rain columns, attenuated toward the centre so icon labels
  stay legible against it.
- Glowing "MATRIX CODE" wordmark in the title band.
- Icon size 100px, label position bottom, toolbar and sidebar hidden.

**Two install gestures, deliberately.** The app gets a drag-to-`/Applications`
target. The saver cannot: `~/Library/Screen Savers` is a per-user absolute path,
so no symlink to it is portable across machines. The caption therefore has to
carry the second gesture — double-clicking the saver hands it to System Settings,
which installs it.

## Testing

The release path cannot run unattended (it needs the Developer ID identity in the
Keychain and a notarization round-trip), so verification is split:

1. **Layout generation** — `scripts/generate_dmg_layout.py` is deterministic;
   regenerating it produces a byte-identical `DS_Store`.
2. **Structural check on the built DMG** — attach the image and assert it
   contains `MatrixCode.app`, `MatrixCode.saver`, the `Applications` symlink,
   `.DS_Store`, `.background/background.png` and `.VolumeIcon.icns`; then detach.
   This runs against the real product without needing notarization.
3. **Existing verification is preserved** — `codesign --verify`, the
   `spctl -a -t install` Gatekeeper assessment, `stapler validate`, and the
   published-artifact checksum check all still run against the DMG in its new
   location.
4. **Visual confirmation** — the rendered `background.png` is reviewed before it
   is committed. Automated tests cannot judge "beautiful".

## Out of scope

- No change to app/saver behaviour, code signing identity, or notarization setup.
- No versioned DMG filenames or release archiving — successive builds overwrite.
- No web-side (`src/`) changes; this is native packaging only, so the CLAUDE.md
  parity rule does not apply.
