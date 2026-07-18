"""Run with: /tmp/dmgvenv/bin/python -m pytest test/test_dmg_layout.py -v

See scripts/generate_dmg_layout.py for how to create that venv.
"""
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
