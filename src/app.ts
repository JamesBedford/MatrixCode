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
import { stepsToAdvance, extractSlice } from "./super/superGrid.ts";
import {
  type SuperConfig,
  startSuperSession,
  parsePanelConfig,
  enterPanelFullscreen,
  openExitChannel,
  prefetchScreens,
} from "./super/superFullscreen.ts";

export interface MatrixRainHandle {
  destroy: () => void;
  controls: ControlsStore;
}

const ATLAS_CELL_PX = 64;
const INTRO_KEY = "mx-intro-seen";
const WARMUP_SECONDS = 2.5;
// Super-fullscreen lockstep: advance the shared sim in fixed steps toward the
// shared wall-clock, capping per-frame catch-up so a stalled window recovers
// gradually instead of freezing.
const SUPER_FIXED_DT = 1 / 60;
const SUPER_MAX_STEPS = 6;
// Window within which consecutive background clicks count as one gesture.
const MULTI_CLICK_MS = 350;

/** Active super-fullscreen state for this window (controller or a panel). */
interface SuperState {
  config: SuperConfig;
  isController: boolean;
  openedWindows: Window[];
  localState: Uint8Array;
  /** Sim time already simulated, in seconds (starts at warmupSeconds). */
  simClock: number;
}

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

function computeDims(cssW: number, cssH: number, glyphScale: number): { grid: Grid; devW: number; devH: number } {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const cell = DEFAULT_SIM_CONFIG.targetCellPx * glyphScale;
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
    const fb = startCanvas2dRain(canvas, controls.get().preset, controls.get().glyphScale);
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

  // Super-fullscreen: this window is a panel iff the URL carries a slice config.
  const panelConfig = parsePanelConfig();
  let superState: SuperState | null = null;
  let exitChan: ReturnType<typeof openExitChannel> | null = null;

  const applySize = (w: number, h: number): void => {
    cssW = w;
    cssH = h;
    const d = computeDims(w, h, controls.get().glyphScale);
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
    sim.warmUp(controls.get(), WARMUP_SECONDS);
  };

  // Initial size before building GPU resources (sim needs grid dimensions).
  {
    const r = container.getBoundingClientRect();
    cssW = r.width || window.innerWidth;
    cssH = r.height || window.innerHeight;
    const d = computeDims(cssW, cssH, controls.get().glyphScale);
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
    const fb = startCanvas2dRain(canvas, controls.get().preset, controls.get().glyphScale);
    showNotice(container, "Compatibility mode");
    return { controls, destroy: () => fb.stop() };
  }

  // ---------- Overlays ----------
  // Panels are a pure backdrop — no intro, no controls UI.
  const message = panelConfig ? null : new MessageOverlay(container, { lines: buildScript(resolveUserName()) });
  const panel = panelConfig
    ? null
    : new ControlsPanel(container, controls, {
        onToggleFullscreen: () => toggleFullscreen(),
        onReplayIntro: () => message?.play(performance.now()),
      });

  const reduceMq = window.matchMedia("(prefers-reduced-motion: reduce)");

  // Draw one frame from the current sim state. In super mode it paints this
  // window's slice of the shared grid; otherwise the whole grid.
  const paint = (): void => {
    if (!sim) return;
    if (superState) {
      const { vCols, vRows, slice } = superState.config;
      extractSlice(sim.state, vCols, vRows, slice, superState.localState);
      stateTex.upload(superState.localState);
    } else {
      stateTex.upload(sim.state);
    }
    renderer.renderFrame(paramsOf(controls.get()), grid);
  };
  const renderStatic = paint;

  const loop = (now: number): void => {
    if (!running) return;
    raf = requestAnimationFrame(loop);
    if (superState) {
      // Advance toward the shared wall-clock so every window stays in lockstep.
      const target = superState.config.warmupSeconds + (Date.now() - superState.config.epoch) / 1000;
      const steps = stepsToAdvance(target, superState.simClock, SUPER_FIXED_DT, SUPER_MAX_STEPS);
      for (let i = 0; i < steps; i++) sim.update(SUPER_FIXED_DT, controls.get());
      superState.simClock += steps * SUPER_FIXED_DT;
      paint();
      return;
    }
    flushResize();
    const dt = Math.min((now - last) / 1000, 1 / 15);
    last = now;
    sim.update(dt, controls.get());
    stateTex.upload(sim.state);
    renderer.renderFrame(paramsOf(controls.get()), grid);
    message?.update(now);
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

  // In super mode the grid is fixed by the shared geometry, so a resize (e.g. the
  // fullscreen transition) only updates the device-pixel canvas size, never the grid.
  const applySuperDeviceSize = (): void => {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    cssW = window.innerWidth;
    cssH = window.innerHeight;
    deviceW = Math.max(1, Math.round(cssW * dpr));
    deviceH = Math.max(1, Math.round(cssH * dpr));
    canvas.width = deviceW;
    canvas.height = deviceH;
    renderer.resize(deviceW, deviceH, controls.get().quality);
  };

  // ---------- Resize ----------
  const handleResize = (w: number, h: number): void => {
    if (superState) {
      applySuperDeviceSize();
      if (!running) renderStatic();
      return;
    }
    pending = { w, h };
    if (!running) {
      flushResize();
      renderStatic();
    }
  };
  const ro = new ResizeObserver((entries) => {
    const e = entries[0];
    if (!e) return;
    handleResize(e.contentRect.width, e.contentRect.height);
  });
  ro.observe(container);
  const onWindowResize = (): void => {
    handleResize(container.clientWidth || window.innerWidth, container.clientHeight || window.innerHeight);
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

  // ---------- Super fullscreen (all monitors) ----------
  // Switch this window's rain into a slice of the shared virtual grid.
  const enterSuperRender = (config: SuperConfig, isController: boolean, openedWindows: Window[]): void => {
    container.classList.add("mx-super"); // hides the controls/intro overlays via CSS
    sim = new RainSim({ cols: config.vCols, rows: config.vRows, config: DEFAULT_SIM_CONFIG, glyphSet, seed: config.seed });
    sim.warmUp(controls.get(), config.warmupSeconds);
    const lc = config.slice.cols;
    const lr = config.slice.rows;
    stateTex.resize(lc, lr);
    grid = { cols: lc, rows: lr };
    superState = { config, isController, openedWindows, localState: new Uint8Array(lc * lr * 4), simClock: config.warmupSeconds };
    pending = null; // discard any normal-mode resize queued before the switch
    applySuperDeviceSize();
    start();
    renderStatic();
  };

  const exitSuper = (broadcast: boolean): void => {
    if (!superState) return;
    const { isController, openedWindows } = superState;
    if (broadcast) exitChan?.broadcastExit();
    exitChan?.close();
    exitChan = null;
    superState = null;
    container.classList.remove("mx-super");
    if (document.fullscreenElement) void document.exitFullscreen();
    if (isController) {
      for (const w of openedWindows) {
        try {
          w.close();
        } catch {
          /* already closed */
        }
      }
      pending = null; // a stale fullscreen-sized resize must not survive the switch back
      applySize(cssW, cssH); // rebuild sim/state/renderer back to this window's own grid
      renderStatic();
    } else {
      try {
        window.close(); // a panel window ends with the show
      } catch {
        /* opener-less window can't self-close — leave it as a static backdrop */
      }
    }
  };

  // Controller path: a triple-click fans the rain out onto every monitor.
  const enterSuper = async (): Promise<void> => {
    if (superState || panelConfig) return;
    const cell = DEFAULT_SIM_CONFIG.targetCellPx * controls.get().glyphScale;
    let res;
    try {
      res = await startSuperSession(container, cell, WARMUP_SECONDS);
    } catch {
      res = { kind: "fallback" as const };
    }
    if (res.kind === "fallback") {
      toggleFullscreen(); // single monitor / unsupported / denied → ordinary fullscreen
      return;
    }
    exitChan = openExitChannel(() => exitSuper(false));
    enterSuperRender(res.selfConfig, true, res.openedWindows);
  };

  const onKey = (e: KeyboardEvent): void => {
    if (superState) {
      if (e.key === "Escape") exitSuper(true);
      return;
    }
    if (e.key === "f" || e.key === "F") toggleFullscreen();
    else if (e.key === "h" || e.key === "H") panel?.toggleVisible();
    else if (e.key === "Escape") message?.skip();
  };
  window.addEventListener("keydown", onKey);

  const onPointerDown = (): void => {
    if (message?.isPlaying()) message.skip();
  };
  window.addEventListener("pointerdown", onPointerDown);

  // Multi-click on the backdrop: double → ordinary fullscreen, triple → super.
  // The triple acts on the 3rd click immediately so it keeps the transient
  // activation that getScreenDetails / window.open / requestFullscreen require.
  let clickCount = 0;
  let clickTimer = 0;
  const onCanvasClick = (): void => {
    if (superState) return;
    clickCount += 1;
    if (clickCount >= 3) {
      window.clearTimeout(clickTimer);
      clickCount = 0;
      void enterSuper();
      return;
    }
    window.clearTimeout(clickTimer);
    clickTimer = window.setTimeout(() => {
      if (clickCount === 2) toggleFullscreen();
      clickCount = 0;
    }, MULTI_CLICK_MS);
  };
  // In a panel, a click is just a way to enter fullscreen if the policy didn't.
  const onPanelClick = (): void => {
    if (!document.fullscreenElement) void enterPanelFullscreen(container);
  };
  canvas.addEventListener("click", panelConfig ? onPanelClick : onCanvasClick);

  // Esc inside fullscreen is intercepted by the browser (no keydown reaches us),
  // so the authoritative "show ended" signal is leaving fullscreen.
  const onFullscreenChange = (): void => {
    if (superState && !document.fullscreenElement) exitSuper(true);
  };
  document.addEventListener("fullscreenchange", onFullscreenChange);
  // Closing any window ends the whole show.
  const onBeforeUnload = (): void => {
    if (superState) exitChan?.broadcastExit();
  };
  window.addEventListener("beforeunload", onBeforeUnload);

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

  // ---------- React to control changes ----------
  const unsubscribe = controls.subscribe((_state, changed) => {
    if (changed.has("glyphScale") && !superState) {
      applySize(cssW, cssH); // recomputes the grid and resizes the sim/state/renderer
    }
    if (changed.has("mirror")) {
      void buildGlyphAtlas(gl, { chars: glyphSet.chars, mirror: controls.get().mirror, cellPx: ATLAS_CELL_PX }).then(
        (a) => {
          atlas = a;
          renderer.setAtlas(a);
          if (!running) renderStatic();
        },
      );
    }
    // While paused (reduced motion / hidden tab) the RAF loop isn't redrawing,
    // so reflect any control change — color, glow, quality, etc. — in a fresh frame.
    if (!running) renderStatic();
  });

  // ---------- Intro on first visit ----------
  const maybePlayIntro = (): void => {
    if (!message || reduceMq.matches) return;
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

  if (panelConfig) {
    // This window was opened as a panel: render its slice and go fullscreen.
    enterSuperRender(panelConfig, false, []);
    exitChan = openExitChannel(() => exitSuper(false));
    void enterPanelFullscreen(container);
  } else {
    start();
    maybePlayIntro();
    if (!running) renderStatic(); // reduced-motion: ensure one frame is shown
    void prefetchScreens(); // warm screen details so the triple-click keeps its gesture
  }

  return {
    controls,
    destroy: () => {
      if (superState) exitSuper(false);
      stop();
      ro.disconnect();
      window.removeEventListener("resize", onWindowResize);
      reduceMq.removeEventListener("change", onReduceChange);
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("pointerdown", onPointerDown);
      canvas.removeEventListener("click", panelConfig ? onPanelClick : onCanvasClick);
      document.removeEventListener("fullscreenchange", onFullscreenChange);
      window.removeEventListener("beforeunload", onBeforeUnload);
      canvas.removeEventListener("webglcontextlost", onLost);
      unsubscribe();
      panel?.destroy();
      message?.destroy();
      renderer.dispose();
      stateTex.dispose();
      canvas.remove();
    },
  };
}
