"""Run with: /private/tmp/claude-501/-Users-james-Library-CloudStorage-Dropbox-Source-MatrixCode/45c98aa4-cd20-4cc0-a910-b06ed5fdb1d9/scratchpad/dmgvenv/bin/python -m pytest test/test_dmg_background.py -v"""
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
