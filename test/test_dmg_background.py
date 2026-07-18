"""Run with: /tmp/dmgvenv/bin/python -m pytest test/test_dmg_background.py -v

Set up that venv with:
    python3 -m venv /tmp/dmgvenv
    /tmp/dmgvenv/bin/pip install ds_store mac_alias pillow pytest
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "generate_dmg_background.py"
OUT = ROOT / "macos" / "MatrixCodeScreenSaver" / "Resources" / "DMG" / "background.tiff"

sys.path.insert(0, str(ROOT / "scripts"))
import generate_dmg_background as g  # noqa: E402


def test_renders_at_requested_scale():
    for scale in g.SCALES:
        assert g.render(scale).size == (g.CANVAS_W * scale, g.CANVAS_H * scale)


def test_canvas_bleeds_past_the_window():
    """Finder anchors the backdrop top-left and never scales it, so a window
    larger than the artwork would show bare white. The canvas must overhang."""
    assert g.CANVAS_W > g.WINDOW_W
    assert g.CANVAS_H > g.WINDOW_BOUNDS_H


def test_is_deterministic():
    assert g.render(1).tobytes() == g.render(1).tobytes()


def test_every_element_sits_inside_the_safe_area():
    """Finder's window chrome eats into the content area, so anything below
    SAFE_H can be clipped. The saver plate is the lowest element."""
    lowest_icon = max(cy for _, cy in g.ICON_POSITIONS.values())
    plate_bottom = lowest_icon + 12 + g.PLATE_H // 2
    assert plate_bottom <= g.SAFE_H, f"plate reaches {plate_bottom}, past {g.SAFE_H}"
    assert g.WINDOW_H > g.SAFE_H, "canvas must outlast the safe area"
    # The window must be tall enough that the content area still clears SAFE_H
    # once the title bar and tab bar have taken their share.
    assert g.WINDOW_BOUNDS_H >= g.SAFE_H + 100


def test_writes_a_hidpi_tiff():
    subprocess.run([sys.executable, str(SCRIPT)], check=True)
    assert OUT.exists()

    from PIL import Image

    with Image.open(OUT) as img:
        # Finder maps one image pixel to one point, so the base representation
        # must match the canvas exactly or the backdrop renders cropped.
        assert img.size == (g.CANVAS_W, g.CANVAS_H)
        assert getattr(img, "n_frames", 1) == len(g.SCALES)
        img.seek(1)
        assert img.size == (g.CANVAS_W * 2, g.CANVAS_H * 2)
