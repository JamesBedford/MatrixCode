import type { Controls, Grid, RenderParams } from "./types.ts";
import { createGlyphSet } from "./sim/glyphSet.ts";
import { RainSim } from "./sim/rainSim.ts";
import { MessageOverlay, buildScript, resolveUserName } from "./sim/messageOverlay.ts";
import { DEFAULT_SIM_CONFIG } from "./config/simConfig.ts";
import { getPreset } from "./config/colorPresets.ts";
import { ControlsStore } from "./config/controls.ts";
import { buildGlyphAtlas, type GlyphAtlas } from "./gl/glyphAtlas.ts";
import { StateTexture } from "./gl/stateTexture.ts";
import { Renderer } from "./gl/renderer.ts";
import { ControlsPanel } from "./ui/controlsPanel.ts";
import { startCanvas2dRain } from "./fallback/canvas2dRain.ts";

export interface MatrixRainHandle {
  destroy: () => void;
  controls: ControlsStore;
}

const ATLAS_CELL_PX = 64;
const INTRO_KEY = "mx-intro-seen";

function paramsOf(c: Controls): RenderParams {
  return {
    glow: c.glow,
    leadBrightness: c.leadBrightness,
    scanlines: c.scanlines,
    vignette: c.vignette,
    quality: c.quality,
    preset: getPreset(c.preset),
  };
}

function computeDims(cssW: number, cssH: number): { grid: Grid; devW: number; devH: number } {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const cell = DEFAULT_SIM_CONFIG.targetCellPx;
  return {
    grid: { cols: Math.max(8, Math.round(cssW / cell)), rows: Math.max(8, Math.round(cssH / cell)) },
    devW: Math.max(1, Math.round(cssW * dpr)),
    devH: Math.max(1, Math.round(cssH * dpr)),
  };
}

function showNotice(parent: HTMLElement, text: string): HTMLElement {
  const n = document.createElement("div");
  n.className = "mx-notice";
  n.textContent = text;
  parent.appendChild(n);
  return n;
}

export async function mountMatrixRain(
  container: HTMLElement,
  options?: Partial<Controls>,
): Promise<MatrixRainHandle> {
  const controls = new ControlsStore();
  if (options) controls.set(options);

  const canvas = document.createElement("canvas");
  container.appendChild(canvas);

  const gl = canvas.getContext("webgl2", {
    alpha: false,
    antialias: false,
    premultipliedAlpha: false,
    powerPreference: "high-performance",
  });

  // ---------- Fallback: no WebGL2 ----------
  if (!gl) {
    const fb = startCanvas2dRain(canvas, controls.get().preset);
    const sizeCanvas = (): void => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round((container.clientWidth || window.innerWidth) * dpr);
      canvas.height = Math.round((container.clientHeight || window.innerHeight) * dpr);
    };
    sizeCanvas();
    const ro = new ResizeObserver(sizeCanvas);
    ro.observe(container);
    showNotice(container, "Compatibility mode — WebGL2 unavailable");
    return {
      controls,
      destroy: () => {
        fb.stop();
        ro.disconnect();
        canvas.remove();
      },
    };
  }

  // ---------- GPU path ----------
  const glyphSet = createGlyphSet();
  let atlas: GlyphAtlas;
  let sim: RainSim;
  let stateTex: StateTexture;
  let renderer: Renderer;
  let grid: Grid = { cols: 1, rows: 1 };
  let cssW = 1;
  let cssH = 1;
  let deviceW = 1;
  let deviceH = 1;
  let pending: { w: number; h: number } | null = null;
  let running = false;
  let raf = 0;
  let last = 0;

  const applySize = (w: number, h: number): void => {
    cssW = w;
    cssH = h;
    const d = computeDims(w, h);
    grid = d.grid;
    deviceW = d.devW;
    deviceH = d.devH;
    canvas.width = deviceW;
    canvas.height = deviceH;
    sim?.resize(grid.cols, grid.rows);
    stateTex?.resize(grid.cols, grid.rows);
    renderer?.resize(deviceW, deviceH, controls.get().quality);
  };

  const flushResize = (): void => {
    if (!pending) return;
    const { w, h } = pending;
    pending = null;
    if (w !== cssW || h !== cssH) applySize(w, h);
  };

  const buildGpu = async (): Promise<void> => {
    atlas = await buildGlyphAtlas(gl, { chars: glyphSet.chars, mirror: controls.get().mirror, cellPx: ATLAS_CELL_PX });
    sim = new RainSim({ cols: grid.cols, rows: grid.rows, config: DEFAULT_SIM_CONFIG, glyphSet, seed: 0x1a2b3c });
    stateTex = new StateTexture(gl, grid.cols, grid.rows);
    renderer = new Renderer(gl, atlas, stateTex);
    renderer.resize(deviceW, deviceH, controls.get().quality);
    sim.warmUp(controls.get(), 2.5);
  };

  // Initial size before building GPU resources (sim needs grid dimensions).
  {
    const r = container.getBoundingClientRect();
    cssW = r.width || window.innerWidth;
    cssH = r.height || window.innerHeight;
    const d = computeDims(cssW, cssH);
    grid = d.grid;
    deviceW = d.devW;
    deviceH = d.devH;
    canvas.width = deviceW;
    canvas.height = deviceH;
  }

  try {
    await buildGpu();
  } catch (err) {
    console.error("Matrix GPU init failed, using fallback:", err);
    const fb = startCanvas2dRain(canvas, controls.get().preset);
    showNotice(container, "Compatibility mode");
    return { controls, destroy: () => fb.stop() };
  }

  // ---------- Overlays ----------
  const message = new MessageOverlay(container, { lines: buildScript(resolveUserName()) });
  const panel = new ControlsPanel(container, controls, {
    onToggleFullscreen: () => toggleFullscreen(),
    onReplayIntro: () => message.play(performance.now()),
  });

  const reduceMq = window.matchMedia("(prefers-reduced-motion: reduce)");

  const renderStatic = (): void => {
    if (!sim) return;
    stateTex.upload(sim.state);
    renderer.renderFrame(paramsOf(controls.get()), grid);
  };

  const loop = (now: number): void => {
    if (!running) return;
    raf = requestAnimationFrame(loop);
    flushResize();
    const dt = Math.min((now - last) / 1000, 1 / 15);
    last = now;
    sim.update(dt, controls.get());
    stateTex.upload(sim.state);
    renderer.renderFrame(paramsOf(controls.get()), grid);
    message.update(now);
  };

  const start = (): void => {
    if (running) return;
    if (reduceMq.matches) {
      renderStatic();
      return;
    }
    running = true;
    last = performance.now();
    raf = requestAnimationFrame(loop);
  };

  const stop = (): void => {
    running = false;
    cancelAnimationFrame(raf);
  };

  // ---------- Resize ----------
  const ro = new ResizeObserver((entries) => {
    const e = entries[0];
    if (!e) return;
    pending = { w: e.contentRect.width, h: e.contentRect.height };
    if (!running) {
      flushResize();
      renderStatic();
    }
  });
  ro.observe(container);
  const onWindowResize = (): void => {
    pending = { w: container.clientWidth || window.innerWidth, h: container.clientHeight || window.innerHeight };
    if (!running) {
      flushResize();
      renderStatic();
    }
  };
  window.addEventListener("resize", onWindowResize);

  // ---------- Reduced motion ----------
  const onReduceChange = (): void => {
    if (reduceMq.matches) {
      stop();
      renderStatic();
    } else {
      start();
    }
  };
  reduceMq.addEventListener("change", onReduceChange);

  // ---------- Page visibility ----------
  const onVisibility = (): void => {
    if (document.hidden) stop();
    else if (!reduceMq.matches) start();
  };
  document.addEventListener("visibilitychange", onVisibility);

  // ---------- Fullscreen + keys ----------
  const toggleFullscreen = (): void => {
    if (document.fullscreenElement) void document.exitFullscreen();
    else void container.requestFullscreen?.();
  };
  const onKey = (e: KeyboardEvent): void => {
    if (e.key === "f" || e.key === "F") toggleFullscreen();
    else if (e.key === "h" || e.key === "H") panel.toggleVisible();
    else if (e.key === "Escape") message.skip();
  };
  window.addEventListener("keydown", onKey);
  const onPointerDown = (): void => {
    if (message.isPlaying()) message.skip();
  };
  window.addEventListener("pointerdown", onPointerDown);
  const onDblClick = (): void => toggleFullscreen();
  canvas.addEventListener("dblclick", onDblClick);

  // ---------- Context loss / restore ----------
  const onLost = (e: Event): void => {
    e.preventDefault();
    stop();
  };
  const onRestored = async (): Promise<void> => {
    try {
      await buildGpu();
      applySize(cssW, cssH);
      if (reduceMq.matches) renderStatic();
      else start();
    } catch (err) {
      console.error("Context restore failed:", err);
    }
  };
  canvas.addEventListener("webglcontextlost", onLost, false);
  canvas.addEventListener("webglcontextrestored", () => void onRestored(), false);

  // ---------- Rebuild atlas on mirror change ----------
  const unsubscribe = controls.subscribe((_state, changed) => {
    if (changed.has("mirror")) {
      void buildGlyphAtlas(gl, { chars: glyphSet.chars, mirror: controls.get().mirror, cellPx: ATLAS_CELL_PX }).then(
        (a) => {
          atlas = a;
          renderer.setAtlas(a);
          if (!running) renderStatic();
        },
      );
    }
  });

  // ---------- Intro on first visit ----------
  const maybePlayIntro = (): void => {
    if (reduceMq.matches) return;
    let seen = false;
    try {
      seen = localStorage.getItem(INTRO_KEY) === "1";
    } catch {
      /* ignore */
    }
    if (seen) return;
    message.onDone(() => {
      try {
        localStorage.setItem(INTRO_KEY, "1");
      } catch {
        /* ignore */
      }
    });
    message.play(performance.now());
  };

  start();
  maybePlayIntro();
  if (!running) renderStatic(); // reduced-motion: ensure one frame is shown

  return {
    controls,
    destroy: () => {
      stop();
      ro.disconnect();
      window.removeEventListener("resize", onWindowResize);
      reduceMq.removeEventListener("change", onReduceChange);
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("pointerdown", onPointerDown);
      canvas.removeEventListener("dblclick", onDblClick);
      canvas.removeEventListener("webglcontextlost", onLost);
      unsubscribe();
      panel.destroy();
      message.destroy();
      renderer.dispose();
      stateTex.dispose();
      canvas.remove();
    },
  };
}
