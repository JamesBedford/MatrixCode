#!/usr/bin/env python3
"""Generates the committed Finder layout for the MatrixCode DMG.

The background is stored as an *alias*, which can only be minted against a real
file on a mounted volume — so this builds a throwaway read-write image named
"Matrix Code", writes the layout onto it, and copies the resulting .DS_Store out.

The volume name matters: Finder keys a layout to it. It must match VOLUME_NAME in
scripts/build-release.sh.

Requires ds_store + mac_alias (not needed by the release build):
    python3 -m venv /tmp/dmgvenv
    /tmp/dmgvenv/bin/pip install ds_store mac_alias pillow pytest
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
from generate_dmg_background import (  # noqa: E402
    ICON_POSITIONS,
    WINDOW_BOUNDS_H,
    WINDOW_W,
)

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "macos" / "MatrixCodeScreenSaver" / "Resources"
DMG_DIR = RESOURCES / "DMG"
BACKGROUND = DMG_DIR / "background.tiff"
OUT_DS_STORE = DMG_DIR / "DS_Store"
OUT_VOLUME_ICON = DMG_DIR / "VolumeIcon.icns"
SOURCE_ICNS = RESOURCES / "MatrixCode.icns"

VOLUME_NAME = "Matrix Code"  # must match build-release.sh


def run(*args: str) -> subprocess.CompletedProcess:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(args)}\n"
            f"{result.stderr.strip()}"
        )
    return result


def attach(dmg: Path) -> Path:
    out = run("hdiutil", "attach", str(dmg), "-nobrowse", "-noautoopen").stdout
    device = None
    for line in out.splitlines():
        stripped = line.strip()
        if device is None and stripped.startswith("/dev/"):
            device = stripped.split()[0]
        if "/Volumes/" in line:
            return Path("/Volumes/" + line.split("/Volumes/")[1].strip())
    # hdiutil reported success but we could not parse a mount point out of its
    # output, so the image may still be attached. Detach it — by device node
    # if we found one, otherwise by the volume name we asked hdiutil to use —
    # before raising, so a parsing failure here can never leak a mounted volume.
    try:
        detach(device or f"/Volumes/{VOLUME_NAME}")
    except RuntimeError as detach_exc:
        raise RuntimeError(
            f"could not find mount point in:\n{out}\n"
            f"cleanup after this failure also failed: {detach_exc}"
        ) from detach_exc
    raise RuntimeError(f"could not find mount point in:\n{out}")


def detach(target: Path | str) -> None:
    for _ in range(4):
        try:
            run("hdiutil", "detach", str(target), "-quiet")
            return
        except RuntimeError:
            subprocess.run(["sync"], check=False)
            time.sleep(1)
    result = subprocess.run(
        ["hdiutil", "detach", str(target), "-force", "-quiet"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"failed to detach {target} even with -force; a mount may have "
            f"leaked (stderr: {result.stderr.strip()})"
        )


def write_layout(volume: Path) -> None:
    alias = Alias.for_file(str(volume / ".background" / "background.tiff"))
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
        # Height covers the window chrome, not just the content area.
        "WindowBounds": f"{{{{200, 160}}, {{{WINDOW_W}, {WINDOW_BOUNDS_H}}}}}",
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
        shutil.copy(BACKGROUND, stage / ".background" / "background.tiff")
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
            # If a volume called "Matrix Code" is already mounted, macOS mounts
            # this one as "Matrix Code 1" and the alias would capture that path,
            # producing a layout that does not belong to the shipped volume.
            if mount.name != VOLUME_NAME:
                raise SystemExit(
                    f"Mounted as {mount.name!r}, expected {VOLUME_NAME!r}. "
                    f"Detach the other volume first:\n"
                    f'    hdiutil detach "/Volumes/{VOLUME_NAME}" -force'
                )
            write_layout(mount)
            subprocess.run(["sync"], check=False)
            shutil.copy(mount / ".DS_Store", OUT_DS_STORE)
        finally:
            detach(mount)

    print(f"Layout written to {OUT_DS_STORE} ({OUT_DS_STORE.stat().st_size} bytes)")
    print(f"Volume icon written to {OUT_VOLUME_ICON}")


if __name__ == "__main__":
    main()
