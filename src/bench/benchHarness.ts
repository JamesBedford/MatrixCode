// Deterministic benchmark mode (activated by the `?bench` URL param). It drives the
// SAME atlas/sim/renderer modules as the live site, but under fixed, reproducible
// conditions — fixed seed, fixed grid + backing resolution, fixed timestep, no intro
// or messages — so two builds can be compared apples-to-apples and screenshots of a
// given frame are bit-reproducible. Inert unless `?bench` is present; the normal
// render path never imports this file.
//
// It measures per-frame CPU+GPU cost by calling gl.finish() after each renderFrame
// (forcing the GPU to drain so the wall-clock interval includes GPU work) and samples
// the JS heap. Results are exposed on window.__bench for a Playwright runner to pull.

import type { Controls, Grid, QualityTier } from "../types.ts";
import { DEFAULT_CONTROLS } from "../config/controls.ts";
import { DEFAULT_SIM_CONFIG } from "../config/simConfig.ts";
import { getPreset } from "../config/colorPresets.ts";
import { createGlyphSet } from "../sim/glyphSet.ts";
import { RainSim } from "../sim/rainSim.ts";
import { buildGlyphAtlas, type GlyphAtlas } from "../gl/glyphAtlas.ts";
import { StateTexture } from "../gl/stateTexture.ts";
import { Renderer } from "../gl/renderer.ts";

const ATLAS_CELL_PX = 64;
const BENCH_SEED = 0x1a2b3c;
const FIXED_DT = 1 / 60;
const WARMUP_SECONDS = 2.5;

interface RunOptions {
  frames?: number;
  /** Sample the JS heap every N frames (0 disables). */
  memEvery?: number;
  /** Yield to the event loop every N frames so the page stays responsive. */
  yieldEvery?: number;
}

interface Summary {
  count: number;
  avg: number;
  min: number;
  max: number;
  p50: number;
  p95: number;
  p99: number;
  stddev: number;
}

export interface BenchResult {
  config: { cssW: number; cssH: number; dpr: number; deviceW: number; deviceH: number; cols: number; rows: number; quality: string; seed: number; frames: number };
  frameMs: Summary;
  simMs: Summary;
  uploadMs: Summary;
  renderMs: Summary;
  fps: Summary;
  /** JS heap used, in bytes (Chromium only; empty if unavailable). */
  heapBytes: Summary | null;
  raw: { frameMs: number[]; simMs: number[]; uploadMs: number[]; renderMs: number[] };
}

function summarize(xs: number[]): Summary {
  const n = xs.length;
  if (n === 0) return { count: 0, avg: 0, min: 0, max: 0, p50: 0, p95: 0, p99: 0, stddev: 0 };
  const sorted = [...xs].sort((a, b) => a - b);
  const sum = xs.reduce((a, b) => a + b, 0);
  const avg = sum / n;
  const variance = xs.reduce((a, b) => a + (b - avg) * (b - avg), 0) / n;
  const pct = (p: number): number => sorted[Math.min(n - 1, Math.floor((p / 100) * n))]!;
  return {
    count: n,
    avg,
    min: sorted[0]!,
    max: sorted[n - 1]!,
    p50: pct(50),
    p95: pct(95),
    p99: pct(99),
    stddev: Math.sqrt(variance),
  };
}

function heapUsed(): number | null {
  const mem = (performance as Performance & { memory?: { usedJSHeapSize: number } }).memory;
  return mem ? mem.usedJSHeapSize : null;
}

function intParam(params: URLSearchParams, key: string, fallback: number): number {
  const v = params.get(key);
  if (v === null) return fallback;
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

export async function startBench(container: HTMLElement, params: URLSearchParams): Promise<void> {
  const cssW = intParam(params, "w", 1920);
  const cssH = intParam(params, "h", 1080);
  const dpr = intParam(params, "dpr", 1);
  const seed = intParam(params, "seed", BENCH_SEED);
  const qualityParam = params.get("quality");
  const quality: QualityTier =
    qualityParam === "low" || qualityParam === "med" || qualityParam === "high" ? qualityParam : "high";

  const deviceW = Math.max(1, Math.round(cssW * dpr));
  const deviceH = Math.max(1, Math.round(cssH * dpr));
  const cell = DEFAULT_SIM_CONFIG.targetCellPx; // glyphScale 1 in bench
  const grid: Grid = { cols: Math.max(8, Math.round(cssW / cell)), rows: Math.max(8, Math.round(cssH / cell)) };

  const controls: Controls = { ...DEFAULT_CONTROLS, quality };

  const canvas = document.createElement("canvas");
  canvas.width = deviceW;
  canvas.height = deviceH;
  canvas.style.width = "100%";
  canvas.style.height = "100%";
  container.appendChild(canvas);

  const gl = canvas.getContext("webgl2", {
    alpha: false,
    antialias: false,
    premultipliedAlpha: false,
    powerPreference: "high-performance",
  });
  if (!gl) {
    (window as Window & { __benchError?: string }).__benchError = "WebGL2 unavailable";
    return;
  }

  const glyphSet = createGlyphSet();
  const atlas: GlyphAtlas = await buildGlyphAtlas(gl, {
    chars: glyphSet.chars,
    mirror: controls.mirror,
    cellPx: ATLAS_CELL_PX,
    mirrorExcludeFrom: glyphSet.ranges.message.start,
  });
  const sim = new RainSim({ cols: grid.cols, rows: grid.rows, config: DEFAULT_SIM_CONFIG, glyphSet, seed });
  const stateTex = new StateTexture(gl, grid.cols, grid.rows);
  const renderer = new Renderer(gl, atlas, stateTex);
  renderer.resize(deviceW, deviceH, quality);
  sim.warmUp(controls, WARMUP_SECONDS);

  const renderParams = {
    glow: controls.glow,
    leadBrightness: controls.leadBrightness,
    scanlines: controls.scanlines,
    vignette: controls.vignette,
    quality,
    preset: getPreset(controls.preset),
  };

  // Force the GPU to fully drain each measured frame. ANGLE/Metal treats gl.finish()
  // loosely (it can return before the GPU is done), so a 1x1 readPixels from the
  // just-composited default framebuffer is used as the real barrier: it must wait for
  // the pixel to exist, so the measured interval includes actual GPU execution.
  const drainPixel = new Uint8Array(4);
  const drainGpu = (): void => {
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, drainPixel);
  };

  // Draw one frame so the canvas has content for a screenshot before run() is called.
  stateTex.upload(sim.state);
  renderer.renderFrame(renderParams, grid);
  drainGpu();

  const run = async (opts: RunOptions = {}): Promise<BenchResult> => {
    const frames = opts.frames ?? 300;
    const memEvery = opts.memEvery ?? 5;
    const yieldEvery = opts.yieldEvery ?? 30;
    const frameMs: number[] = [];
    const simMs: number[] = [];
    const uploadMs: number[] = [];
    const renderMs: number[] = [];
    const heap: number[] = [];

    for (let i = 0; i < frames; i++) {
      const t0 = performance.now();
      sim.update(FIXED_DT, controls);
      const t1 = performance.now();
      stateTex.upload(sim.state);
      const t2 = performance.now();
      renderer.renderFrame(renderParams, grid);
      drainGpu(); // blocks until the GPU has produced the frame (see drainGpu above)
      const t3 = performance.now();

      simMs.push(t1 - t0);
      uploadMs.push(t2 - t1);
      renderMs.push(t3 - t2);
      frameMs.push(t3 - t0);
      if (memEvery > 0 && i % memEvery === 0) {
        const h = heapUsed();
        if (h !== null) heap.push(h);
      }
      if (yieldEvery > 0 && i % yieldEvery === yieldEvery - 1) {
        await new Promise((r) => setTimeout(r, 0));
      }
    }

    const fps = frameMs.map((ms) => (ms > 0 ? 1000 / ms : 0));
    return {
      config: { cssW, cssH, dpr, deviceW, deviceH, cols: grid.cols, rows: grid.rows, quality, seed, frames },
      frameMs: summarize(frameMs),
      simMs: summarize(simMs),
      uploadMs: summarize(uploadMs),
      renderMs: summarize(renderMs),
      fps: summarize(fps),
      heapBytes: heap.length > 0 ? summarize(heap) : null,
      raw: { frameMs, simMs, uploadMs, renderMs },
    };
  };

  const info = (): Record<string, unknown> => ({
    hdr: renderer.hdr,
    atlas: { cols: atlas.atlasCols, rows: atlas.atlasRows, cellPx: atlas.cellPx, glyphCount: atlas.glyphCount },
    grid,
    device: { w: deviceW, h: deviceH },
    quality,
  });

  (window as Window & { __bench?: { run: typeof run; info: typeof info; ready: boolean } }).__bench = {
    run,
    info,
    ready: true,
  };
}
