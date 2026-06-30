#!/usr/bin/env python3
"""Tier C resolution curve: bench one build at several DPRs and diff each render against the
full-resolution (dpr 2.0) reference. This is the frame-time / fidelity tradeoff space the adaptive
controller navigates — under load it settles at the highest scale that keeps the frame budget."""
import json
import sys
from pathlib import Path
from playwright.sync_api import sync_playwright
from PIL import Image
import numpy as np

PERF = Path(__file__).resolve().parent
HTML = (PERF / "vABC.html").resolve()
W, H, FRAMES, QUALITY = 1920, 1080, 400, "high"
DPRS = [2.0, 1.5, 1.0]


def summary(xs):
    s = sorted(xs); n = len(s)
    return {"avg": sum(s)/n, "min": s[0], "max": s[-1], "p50": s[n//2], "p95": s[min(n-1, int(0.95*n))]}


def diff(a_png, b_png):
    a = np.asarray(Image.open(a_png).convert("RGB")).astype("int32")
    b = np.asarray(Image.open(b_png).convert("RGB")).astype("int32")
    d = np.abs(a-b)
    return {"mean_abs": float(d.mean()), "max_abs": int(d.max()),
            "pct_diff_gt2": float((d.max(axis=2) > 2).mean()*100)}


def main():
    out = {}
    with sync_playwright() as p:
        br = p.chromium.launch(headless=True, args=["--use-gl=angle", "--ignore-gpu-blocklist"])
        for dpr in DPRS:
            pg = br.new_page(viewport={"width": W, "height": H})
            url = f"file://{HTML}?bench=1&w={W}&h={H}&dpr={dpr}&quality={QUALITY}&adaptive=0"
            pg.goto(url)
            pg.wait_for_function("window.__bench && window.__bench.ready === true", timeout=60000)
            r = pg.evaluate("async (f) => await window.__bench.run({ frames: f })", FRAMES)
            shot = PERF / "shots" / f"dpr_{dpr}.png"
            pg.locator("canvas").screenshot(path=str(shot))
            out[str(dpr)] = {"frameMs": r["frameMs"], "backing": f"{int(W*dpr)}x{int(H*dpr)}", "shot": str(shot)}
            print(f"dpr {dpr}: {int(W*dpr)}x{int(H*dpr)}  frameMs p50={r['frameMs']['p50']:.2f} avg={r['frameMs']['avg']:.2f}")
            pg.close()
        br.close()
    ref = out["2.0"]["shot"]
    for dpr in DPRS:
        out[str(dpr)]["fidelity_vs_dpr2"] = {"mean_abs": 0.0, "max_abs": 0, "pct_diff_gt2": 0.0} if dpr == 2.0 \
            else diff(ref, out[str(dpr)]["shot"])
    (PERF / "dpr_curve.json").write_text(json.dumps(out, indent=2))
    print("\nwrote perf/dpr_curve.json")


if __name__ == "__main__":
    main()
