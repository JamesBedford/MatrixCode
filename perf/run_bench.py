#!/usr/bin/env python3
"""Benchmark + fidelity runner for the Matrix-rain builds.

For each version HTML it:
  1. loads `file://<html>?bench=1&...` headless, waits for window.__bench, runs the
     deterministic per-frame benchmark (GPU-inclusive via gl.finish) and pulls the stats.
  2. captures a canvas screenshot of a fixed deterministic frame for a fidelity diff
     against the baseline (mean abs / max abs pixel delta).
  3. loads the page normally to read window.__mxFirstFrame (time-to-first-frame).

Outputs perf/results.json and per-version screenshots in perf/shots/.

Rendering is headless (SwiftShader software raster on most machines): treat the timing
numbers as a stable RELATIVE proxy for GPU fragment/sample cost, not absolute device FPS.
The fidelity diffs and the deterministic frames are exact regardless of backend.
"""
import argparse
import json
import os
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

PERF_DIR = Path(__file__).resolve().parent
SHOTS_DIR = PERF_DIR / "shots"


def cdp_heap(cdp):
    """Clean JS-heap bytes via CDP, after forcing a GC so retained-only footprint is measured."""
    try:
        cdp.send("HeapProfiler.collectGarbage")
    except Exception:
        pass
    metrics = {m["name"]: m["value"] for m in cdp.send("Performance.getMetrics")["metrics"]}
    return metrics.get("JSHeapUsedSize")


def bench_one(page, cdp, html_path: Path, q: dict, frames: int):
    params = f"bench=1&w={q['w']}&h={q['h']}&dpr={q['dpr']}&quality={q['quality']}"
    url = f"file://{html_path}?{params}"
    page.goto(url)
    page.wait_for_function("window.__bench && window.__bench.ready === true", timeout=60000)
    info = page.evaluate("window.__bench.info()")
    idle_heap = cdp_heap(cdp)  # clean, post-warmup, pre-run
    result = page.evaluate(
        "async (frames) => await window.__bench.run({ frames })", frames
    )
    retained_heap = cdp_heap(cdp)  # clean, post-run
    return info, result, idle_heap, retained_heap


def screenshot_canvas(page, out_path: Path):
    canvas = page.query_selector("canvas")
    canvas.screenshot(path=str(out_path))


def measure_ttff(page, html_path: Path, q: dict):
    # Normal load (no bench): read the first-frame marker the app stamps.
    url = f"file://{html_path}?quality={q['quality']}&size=1"
    page.goto(url)
    try:
        page.wait_for_function("window.__mxFirstFrame !== undefined", timeout=30000)
        nav = page.evaluate("performance.timing ? performance.timing.navigationStart : 0")
        first = page.evaluate("window.__mxFirstFrame")
        # __mxFirstFrame is performance.now()-based (relative to navigation start of the doc).
        return float(first)
    except Exception as e:
        return None


def fidelity_diff(base_png: Path, other_png: Path):
    try:
        from PIL import Image
        import numpy as np
    except Exception:
        return None
    a = np.asarray(Image.open(base_png).convert("RGB")).astype("int32")
    b = np.asarray(Image.open(other_png).convert("RGB")).astype("int32")
    if a.shape != b.shape:
        return {"error": f"shape mismatch {a.shape} vs {b.shape}"}
    d = np.abs(a - b)
    return {
        "mean_abs": float(d.mean()),
        "max_abs": int(d.max()),
        "pct_pixels_differing": float((d.sum(axis=2) > 0).mean() * 100.0),
        "pct_pixels_diff_gt2": float((d.max(axis=2) > 2).mean() * 100.0),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--versions", nargs="+", required=True,
                    help="label=path pairs, e.g. baseline=perf/baseline.html vA=perf/vA.html")
    ap.add_argument("--frames", type=int, default=300)
    ap.add_argument("--w", type=int, default=1920)
    ap.add_argument("--h", type=int, default=1080)
    ap.add_argument("--dpr", type=int, default=1)
    ap.add_argument("--quality", default="high")
    ap.add_argument("--out", default=str(PERF_DIR / "results.json"))
    args = ap.parse_args()

    q = {"w": args.w, "h": args.h, "dpr": args.dpr, "quality": args.quality}
    SHOTS_DIR.mkdir(parents=True, exist_ok=True)

    versions = []
    for pair in args.versions:
        label, path = pair.split("=", 1)
        versions.append((label, Path(path).resolve()))

    out = {"config": {**q, "frames": args.frames}, "versions": {}}

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, args=[
            "--use-gl=angle",
            "--ignore-gpu-blocklist",
            "--enable-precise-memory-info",  # populate performance.memory for the heap metric
            "--js-flags=--expose-gc",
        ])
        for label, path in versions:
            if not path.exists():
                print(f"!! missing {path}", file=sys.stderr)
                continue
            print(f"== {label}: {path}")
            # Fresh page per version so JS heap + GL state never carry across versions.
            page = browser.new_page(viewport={"width": args.w, "height": args.h})
            cdp = page.context.new_cdp_session(page)
            cdp.send("Performance.enable")
            cdp.send("HeapProfiler.enable")
            info, result, idle_heap, retained_heap = bench_one(page, cdp, path, q, args.frames)
            shot = SHOTS_DIR / f"{label}.png"
            screenshot_canvas(page, shot)
            ttff = measure_ttff(page, path, q)
            out["versions"][label] = {
                "info": info,
                "result": result,
                "ttff_ms": ttff,
                "idle_heap_bytes": idle_heap,
                "retained_heap_bytes": retained_heap,
                "screenshot": str(shot),
            }
            page.close()
            fm = result["frameMs"]
            fps = result["fps"]
            ih = f"{idle_heap/1e6:.2f}MB" if idle_heap else "n/a"
            print(f"   frameMs avg={fm['avg']:.3f} min={fm['min']:.3f} max={fm['max']:.3f} "
                  f"p95={fm['p95']:.3f} | fps avg={fps['avg']:.1f} | idle heap {ih}")
        browser.close()

    # Fidelity diffs vs baseline.
    if "baseline" in out["versions"]:
        base_shot = Path(out["versions"]["baseline"]["screenshot"])
        for label, v in out["versions"].items():
            if label == "baseline":
                continue
            v["fidelity_vs_baseline"] = fidelity_diff(base_shot, Path(v["screenshot"]))

    Path(args.out).write_text(json.dumps(out, indent=2))
    print(f"\nWrote {args.out}")


if __name__ == "__main__":
    main()
