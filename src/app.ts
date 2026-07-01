import type { ColorPreset, Controls, Grid, RenderParams, MessagesDoc } from "./types.ts";
import { createGlyphSet } from "./sim/glyphSet.ts";
import { RainSim } from "./sim/rainSim.ts";
import { MessageScheduler } from "./sim/messageScheduler.ts";
import { createRng } from "./util/rng.ts";
import { MessageOverlay, resolveUserName } from "./sim/messageOverlay.ts";
import { resolveTokens } from "./sim/tokens.ts";
import { densityRampFactor, loadRampMs, rampEase } from "./sim/introRain.ts";
import { computeLanes, tierCap, seedForLayer, MAX_LANES, type Lane } from "./sim/overlapLanes.ts";
import { DEFAULT_SIM_CONFIG } from "./config/simConfig.ts";
import { getPreset } from "./config/colorPresets.ts";
import { ControlsStore } from "./config/controls.ts";
import { buildGlyphAtlas, type GlyphAtlas } from "./gl/glyphAtlas.ts";
import { StateTexture } from "./gl/stateTexture.ts";
import { Renderer, type ExtraLayer } from "./gl/renderer.ts";
import { AdaptiveResolution } from "./gl/adaptiveResolution.ts";
import { ControlsPanel } from "./ui/controlsPanel.ts";
import { applyFavicon } from "./ui/favicon.ts";
import { IntroStore, sanitizeIntro, toTypeConfig, type IntroScript } from "./config/introStore.ts";
import { IntroEditor } from "./ui/introEditor.ts";
import { MessagesStore } from "./config/messagesStore.ts";
import { MessagesEditor } from "./ui/messagesEditor.ts";
import { CountdownStore } from "./config/countdownStore.ts";
import { CountdownEditor } from "./ui/countdownEditor.ts";
import { startCanvas2dRain } from "./fallback/canvas2dRain.ts";
import { stepsToAdvance, extractSlice } from "./super/superGrid.ts";
import {
  type SuperConfig,
  type SuperSessionResult,
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
// Base rain sim seed; overlap layers derive distinct seeds from it via seedForLayer.
const BASE_SEED = 0x1a2b3c;
// Multiplicative step for the −/= density shortcuts (density spans 0.1–100, so a geometric nudge feels even across the range).
const DENSITY_KEY_STEP = 1.2;
// The message scheduler's own PRNG seed, kept separate from the sim's so scheduling never perturbs the rain.
const MSG_SEED = 0x5eed1e;
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

/** Recolor the UI chrome (controls panel, intro text, notices) to match the active preset. */
function applyChromeAccent(preset: ColorPreset): void {
  const channels = (c: readonly [number, number, number]): string =>
    `${Math.round(c[0] * 255)} ${Math.round(c[1] * 255)} ${Math.round(c[2] * 255)}`;
  const root = document.documentElement.style;
  root.setProperty("--mx-accent-rgb", channels(preset.bright));
  root.setProperty("--mx-dim-rgb", channels(preset.body));
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

/** A tiny diagnostics overlay (smoothed FPS · render scale · backing resolution), shown with ?hud. */
function createHud(parent: HTMLElement): HTMLElement {
  const d = document.createElement("div");
  d.style.cssText =
    "position:fixed;top:8px;left:8px;z-index:9999;font:12px/1.5 ui-monospace,monospace;color:#00ff41;" +
    "background:rgba(0,0,0,.55);padding:4px 8px;border-radius:4px;pointer-events:none;white-space:pre;letter-spacing:.02em;";
  parent.appendChild(d);
  return d;
}

export async function mountMatrixRain(
  container: HTMLElement,
  options?: Partial<Controls>,
): Promise<MatrixRainHandle> {
  const controls = new ControlsStore();
  if (options) controls.set(options);
  applyChromeAccent(getPreset(controls.get().preset));
  applyFavicon(getPreset(controls.get().preset));

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
  // Overlap-layer pool (lane indices 1..MAX_LANES-1): independent rain sims rendered at fractional
  // column offsets and composited additively over the base layer (index 0 = `sim`/`stateTex`) once
  // density is turned well up. Only the lanes active at the current density are stepped each frame.
  let extraSims: RainSim[] = [];
  let extraTexs: StateTexture[] = [];
  const extraActive = new Array<boolean>(MAX_LANES - 1).fill(false);
  let grid: Grid = { cols: 1, rows: 1 };
  let cssW = 1;
  let cssH = 1;
  let deviceW = 1;
  let deviceH = 1;
  // Adaptive resolution: render scale is the fraction of the full device-pixel backing actually
  // drawn. It stays at 1.0 (full, visually identical) while there's frame-rate headroom and only
  // drops under sustained load to keep the rain smooth. Disable with ?adaptive=0.
  let renderScale = 1;
  const adaptiveRes = new AdaptiveResolution();
  const adaptiveEnabled = new URLSearchParams(location.search).get("adaptive") !== "0";
  const hud = new URLSearchParams(location.search).has("hud") ? createHud(container) : null;
  let pending: { w: number; h: number } | null = null;
  let running = false;
  let raf = 0;
  let last = 0;
  let userPaused = false;
  // Intro rain choreography. Default sentinel: rain already running at full (no intro / repeat visit).
  let rainStartAtMs = Number.NEGATIVE_INFINITY;
  let rampUpMs = 0;
  let rainPendingAfterIntro = false;
  let pendingPostIntroDelayMs = 0;
  // Debounce so the live Ramp-up slider replays the build-up once the drag settles, not every step.
  let rampPreviewTimer = 0;

  // Super-fullscreen: this window is a panel iff the URL carries a slice config.
  const panelConfig = parsePanelConfig();
  let superState: SuperState | null = null;
  let exitChan: ReturnType<typeof openExitChannel> | null = null;

  // Size the canvas backing + renderer targets to the full device resolution times the current
  // adaptive render scale. The CSS size stays full-viewport, so a scale < 1 simply renders fewer
  // pixels and lets the browser upscale — the grid (and thus the look) is unchanged.
  const applyBackingSize = (): void => {
    const w = Math.max(1, Math.round(deviceW * renderScale));
    const h = Math.max(1, Math.round(deviceH * renderScale));
    canvas.width = w;
    canvas.height = h;
    renderer?.resize(w, h, controls.get().quality);
  };

  const applySize = (w: number, h: number): void => {
    cssW = w;
    cssH = h;
    const d = computeDims(w, h, controls.get().glyphScale);
    grid = d.grid;
    deviceW = d.devW;
    deviceH = d.devH;
    sim?.resize(grid.cols, grid.rows);
    stateTex?.resize(grid.cols, grid.rows);
    for (const s of extraSims) s.resize(grid.cols, grid.rows);
    for (const t of extraTexs) t.resize(grid.cols, grid.rows);
    applyBackingSize();
  };

  const flushResize = (): void => {
    if (!pending) return;
    const { w, h } = pending;
    pending = null;
    if (w !== cssW || h !== cssH) applySize(w, h);
  };

  // Empty every overlap layer. Used whenever the base sim is reset for the intro/ramp black phase, so
  // the overlap lanes fade back in together with the base instead of snapping in already-full.
  const resetExtras = (): void => {
    for (const s of extraSims) s.reset();
    extraActive.fill(false);
  };

  const buildGpu = async (): Promise<void> => {
    atlas = await buildGlyphAtlas(gl, { chars: glyphSet.chars, mirror: controls.get().mirror, cellPx: ATLAS_CELL_PX, mirrorExcludeFrom: glyphSet.ranges.message.start });
    sim = new RainSim({ cols: grid.cols, rows: grid.rows, config: DEFAULT_SIM_CONFIG, glyphSet, seed: BASE_SEED });
    stateTex = new StateTexture(gl, grid.cols, grid.rows);
    // Pre-allocate the overlap-layer pool (memory is tiny; each is a cols×rows sim + state texture).
    extraSims = [];
    extraTexs = [];
    for (let i = 1; i < MAX_LANES; i++) {
      extraSims.push(new RainSim({ cols: grid.cols, rows: grid.rows, config: DEFAULT_SIM_CONFIG, glyphSet, seed: seedForLayer(BASE_SEED, i) }));
      extraTexs.push(new StateTexture(gl, grid.cols, grid.rows));
    }
    extraActive.fill(false);
    renderer = new Renderer(gl, atlas, stateTex);
    applyBackingSize();
    const c = controls.get();
    sim.warmUp(c, WARMUP_SECONDS);
    // Warm only the overlap lanes active at the initial density so a high-density load isn't briefly empty.
    for (const lane of computeLanes(c.density, c.allowOverlap, tierCap(c.quality))) {
      if (lane.index === 0) continue;
      const s = extraSims[lane.index - 1]!;
      s.spawnRateScale = lane.weight;
      s.warmUp({ ...c, density: lane.density }, WARMUP_SECONDS);
      extraActive[lane.index - 1] = true;
    }
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
  const introStore = panelConfig ? null : new IntroStore();
  const messagesStore = panelConfig ? null : new MessagesStore();
  const countdownStore = panelConfig ? null : new CountdownStore();
  const viewerName = resolveUserName();
  // One pure resolver for every surface (intro + in-rain messages). Reads the clock, the default
  // target, and the named moments live, so {time}/{countdown}/{countup} tick without any reconfigure.
  const resolveMessageText = (raw: string): string => {
    const doc = countdownStore?.get();
    return resolveTokens(raw, {
      name: viewerName,
      nowMs: Date.now(),
      countdownTargetMs: doc?.targetMs ?? null,
      moments: Object.fromEntries((doc?.moments ?? []).map((m) => [m.name, m.targetMs])),
    });
  };
  // Current moment names, for the intro/messages editors' token hover.
  const getMomentNames = (): string[] => (countdownStore?.get().moments ?? []).map((m) => m.name);

  const messageScheduler = panelConfig ? null : new MessageScheduler({ glyphSet, rng: createRng(MSG_SEED), resolveText: resolveMessageText });
  if (messageScheduler && messagesStore) messageScheduler.configure(messagesStore.get());
  const message = panelConfig ? null : new MessageOverlay(container, { resolveText: resolveMessageText });

  // Reflect the stored script onto the live overlay (raw lines; tokens resolve per-frame).
  const seedOverlay = (): void => {
    if (!message || !introStore) return;
    const s = introStore.get();
    message.setScript(s.lines, toTypeConfig(s));
  };
  seedOverlay();

  // Start the rain from an empty grid and linearly ramp it to the configured density over `ms`,
  // via the loop's densityRampFactor → spawnRateScale. Shared by the intro's during-mode ramp
  // and the repeat-visit (no-intro) load ramp.
  const beginRampFromEmpty = (ms: number): void => {
    rampUpMs = ms;
    rainPendingAfterIntro = false;
    sim.reset();
    resetExtras();
    rainStartAtMs = performance.now();
  };

  // Play the intro and choreograph the rain (during/after + post-intro delay + density ramp).
  // Used by first-visit autoplay, Replay, and Preview.
  const startIntroSequence = (script: IntroScript): void => {
    if (!message) return;
    message.setScript(script.lines, toTypeConfig(script));
    // Under reduced motion the loop isn't running; skip choreography so an after-mode
    // trigger can't leave a stuck black frame. Behaves like today (a visual no-op).
    if (!reduceMq.matches) {
      const ramp = controls.get().rampUpMs; // ramp duration lives in the main controls, not the intro
      if (!script.rainDuringIntro) {
        rampUpMs = ramp;
        rainPendingAfterIntro = false;
        sim.reset(); // black until the intro ends
        resetExtras();
        rainStartAtMs = Number.POSITIVE_INFINITY;
        rainPendingAfterIntro = true;
        pendingPostIntroDelayMs = script.postIntroDelayMs;
      } else if (ramp > 0) {
        beginRampFromEmpty(ramp); // build from empty starting now
      } else {
        rainStartAtMs = Number.NEGATIVE_INFINITY; // during + no ramp = today's behaviour
        rampUpMs = 0;
        rainPendingAfterIntro = false;
      }
    }
    message.play(performance.now());
  };

  // Preview/save run through the overlay; markSeenPending gates the first-visit flag.
  let introPreviewActive = false;
  let markSeenPending = false;

  const previewIntro = (draft: IntroScript): void => {
    introPreviewActive = true;
    startIntroSequence(sanitizeIntro(draft));
  };

  const saveIntro = (draft: IntroScript): void => {
    if (!introStore) return;
    introStore.set(draft);
    seedOverlay();
  };

  const saveMessages = (draft: MessagesDoc): void => {
    if (!messagesStore) return;
    messagesStore.set(draft);
    messageScheduler?.configure(messagesStore.get());
  };

  const previewMessages = (draft: MessagesDoc): void => {
    messageScheduler?.previewOne(performance.now(), sim, draft);
  };

  // A single onDone handler serves the after-mode rain start, preview restore, and first-visit flag.
  message?.onDone(() => {
    if (rainPendingAfterIntro) {
      rainPendingAfterIntro = false;
      rainStartAtMs = performance.now() + pendingPostIntroDelayMs;
    }
    if (introPreviewActive) {
      introPreviewActive = false;
      editor?.endPreview();
    }
    if (markSeenPending) {
      markSeenPending = false;
      try {
        localStorage.setItem(INTRO_KEY, "1");
      } catch {
        /* ignore */
      }
    }
  });

  let editor: IntroEditor | null = null;
  if (!panelConfig && introStore && message) {
    editor = new IntroEditor(container, introStore, {
      onPreview: previewIntro,
      onSave: saveIntro,
      onCancel: () => seedOverlay(),
    }, getMomentNames);
  }

  let messagesEditor: MessagesEditor | null = null;
  if (!panelConfig && messagesStore) {
    messagesEditor = new MessagesEditor(container, messagesStore, {
      onPreview: previewMessages,
      onSave: saveMessages,
      onCancel: () => {},
    }, getMomentNames);
  }

  let countdownEditor: CountdownEditor | null = null;
  if (!panelConfig && countdownStore) {
    // No scheduler/overlay reconfigure needed — both surfaces read the store live via resolveMessageText.
    countdownEditor = new CountdownEditor(container, countdownStore, {
      onSave: (d) => countdownStore.set(d),
      onCancel: () => {},
    });
  }

  const panel = panelConfig
    ? null
    : new ControlsPanel(container, controls, {
        onToggleFullscreen: () => toggleFullscreen(),
        onReplayIntro: () => { if (introStore) startIntroSequence(introStore.get()); },
        onEditIntro: () => editor?.open(),
        onEditMessages: () => messagesEditor?.open(),
        onEditCountdown: () => countdownEditor?.open(),
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

  // A per-lane controls snapshot: only the density differs between lanes, so reuse `c` unchanged when
  // the lane density matches (keeps the base layer's inputs — and thus its output — bit-identical).
  const laneControls = (c: Controls, density: number): Controls =>
    density === c.density ? c : { ...c, density };

  // Step, upload, and collect the active overlap layers for this frame. Idle lanes are skipped (zero
  // cost); a lane reactivating after being idle is reset first so it fades in from empty rather than
  // resuming stale rain. Returns the layer list for the renderer's additive pass.
  const updateExtraLayers = (lanes: Lane[], dt: number, c: Controls, intro: number): ExtraLayer[] => {
    const layers: ExtraLayer[] = [];
    const activeNow = new Array<boolean>(extraSims.length).fill(false);
    for (const lane of lanes) {
      if (lane.index === 0) continue; // index 0 is the base sim, handled separately
      const j = lane.index - 1;
      const s = extraSims[j];
      const t = extraTexs[j];
      if (!s || !t) continue;
      if (!extraActive[j]) s.reset();
      s.spawnRateScale = intro * lane.weight;
      s.update(dt, laneControls(c, lane.density));
      t.upload(s.state);
      activeNow[j] = true;
      layers.push({ texture: t.texture, colOffset: lane.offset });
    }
    for (let j = 0; j < extraActive.length; j++) extraActive[j] = activeNow[j]!;
    return layers;
  };

  const loop = (now: number): void => {
    if (!running) return;
    raf = requestAnimationFrame(loop);
    // Snapshot the controls once per frame and reuse for both the sim step and the render
    // params, instead of spreading the store twice.
    const c = controls.get();
    if (superState) {
      // Advance toward the shared wall-clock so every window stays in lockstep.
      const target = superState.config.warmupSeconds + (Date.now() - superState.config.epoch) / 1000;
      const steps = stepsToAdvance(target, superState.simClock, SUPER_FIXED_DT, SUPER_MAX_STEPS);
      for (let i = 0; i < steps; i++) sim.update(SUPER_FIXED_DT, c);
      superState.simClock += steps * SUPER_FIXED_DT;
      paint();
      return;
    }
    flushResize();
    const intervalMs = now - last;
    const dt = Math.min(intervalMs / 1000, 1 / 15);
    last = now;
    // Adaptive resolution: feed the achieved frame interval; reallocate the backing only when the
    // scale actually changes (the controller's cooldown keeps that rare). The controller's EMA is
    // updated either way so the HUD reads a stable FPS even when scaling is disabled.
    const s = adaptiveRes.update(Math.min(intervalMs, 100));
    if (adaptiveEnabled && s !== renderScale) {
      renderScale = s;
      applyBackingSize();
    }
    if (hud) {
      const fps = adaptiveRes.smoothedMs > 0 ? 1000 / adaptiveRes.smoothedMs : 0;
      hud.textContent = `${fps.toFixed(0)} fps · ${Math.round(renderScale * 100)}% res · ${canvas.width}×${canvas.height}`;
    }
    let extraLayers: ExtraLayer[] = [];
    if (now >= rainStartAtMs) {
      // Ramp the rain in uniformly (columns fade in in random order, coverage scales linearly), with an
      // eased-in/eased-out but mostly-linear progress curve so the build-up feels steady, not front-loaded.
      const intro = rampEase(densityRampFactor(now, rainStartAtMs, rampUpMs));
      const lanes = computeLanes(c.density, c.allowOverlap, tierCap(c.quality));
      // Base layer (index 0, weight 1): its density is pinned by computeLanes once overlap kicks in.
      sim.spawnRateScale = intro * lanes[0]!.weight;
      // Set/clear in-rain message targets before stepping so they take effect this frame (base layer only).
      messageScheduler?.update(now, sim);
      sim.update(dt, laneControls(c, lanes[0]!.density));
      // Overlap layers (index >= 1): independent sims at fractional offsets, composited additively.
      extraLayers = updateExtraLayers(lanes, dt, c, intro);
    }
    // Before rainStartAtMs (after-mode, pre-start): don't advance — the empty grid renders black.
    stateTex.upload(sim.state);
    renderer.renderFrame(paramsOf(c), grid, extraLayers);
    message?.update(now);
  };

  const start = (): void => {
    if (running) return;
    if (reduceMq.matches || userPaused) {
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
      // Reduced motion always shows warmed, full-density rain — abandon any in-progress
      // intro choreography (after-mode black phase or density ramp) so it isn't left frozen.
      if (rainStartAtMs !== Number.NEGATIVE_INFINITY) {
        rainPendingAfterIntro = false;
        rainStartAtMs = Number.NEGATIVE_INFINITY;
        rampUpMs = 0;
        sim.spawnRateScale = 1;
        sim.warmUp(controls.get(), WARMUP_SECONDS);
      }
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
      resetExtras(); // overlap is disabled in super mode; start the overlap lanes clean on return
      renderStatic();
    } else {
      try {
        window.close(); // a panel window ends with the show
      } catch {
        /* opener-less window can't self-close — leave it as a static backdrop */
      }
    }
  };

  // A short-lived on-screen message (the show hides the normal overlays, so this
  // is how the user learns why a launch didn't go as expected).
  const flashNotice = (text: string, ms = 6000): void => {
    const n = showNotice(container, text);
    window.setTimeout(() => n.remove(), ms);
  };

  // Controller path: a triple-click fans the rain out onto every monitor.
  const enterSuper = async (): Promise<void> => {
    if (superState || panelConfig) return;
    const cell = DEFAULT_SIM_CONFIG.targetCellPx * controls.get().glyphScale;
    let res: SuperSessionResult;
    try {
      res = await startSuperSession(container, cell, WARMUP_SECONDS);
    } catch {
      res = { kind: "fallback" };
    }
    switch (res.kind) {
      case "fallback":
        toggleFullscreen(); // single monitor / unsupported → ordinary fullscreen
        return;
      case "denied":
        flashNotice("Allow “Window management” for this site (address-bar site settings), then triple-click again.");
        return;
      case "needsRetry":
        flashNotice("Multi-monitor ready — triple-click again to launch.");
        return;
      case "popupsBlocked":
        flashNotice("Pop-ups are blocked — allow pop-ups for this site, then triple-click again.");
        return;
      case "super":
        if (res.openedWindows.length < res.expectedPanels) {
          flashNotice("Some windows were blocked — allow pop-ups for this site to fill every monitor.");
        }
        exitChan = openExitChannel(() => exitSuper(false));
        enterSuperRender(res.selfConfig, true, res.openedWindows);
        return;
    }
  };

  // Nudge density by a geometric step; above 5 it snaps to whole numbers (fine control stays at low density).
  const nudgeDensity = (factor: number): void => {
    const d = controls.get().density * factor;
    controls.set({ density: d > 5 ? Math.round(d) : d });
  };

  // Toggle the "Show messages" setting — the shortcut and the editor toggle share one source of
  // truth. Persists, reconfigures the live scheduler, and reflects into an open editor.
  const toggleMessages = (): void => {
    if (!messagesStore || !messageScheduler) return;
    const doc = messagesStore.get();
    doc.enabled = !doc.enabled;
    messagesStore.set(doc);
    messageScheduler.configure(messagesStore.get());
    messagesEditor?.syncEnabled(doc.enabled);
  };

  const onKey = (e: KeyboardEvent): void => {
    if (superState) {
      if (e.key === "Escape") exitSuper(true);
      return;
    }
    if (e.key === "f" || e.key === "F") toggleFullscreen();
    else if (e.key === "h" || e.key === "H") panel?.toggleVisible();
    else if (e.key === "i" || e.key === "I") editor?.open();
    else if (e.key === "m" || e.key === "M") messagesEditor?.open();
    else if (e.key === "c" || e.key === "C") countdownEditor?.open();
    else if (e.key === "n" || e.key === "N") toggleMessages();
    else if (e.key === "-" || e.key === "_") nudgeDensity(1 / DENSITY_KEY_STEP);
    else if (e.key === "=" || e.key === "+") nudgeDensity(DENSITY_KEY_STEP);
    else if (e.key === "p" || e.key === "P") {
      userPaused = !userPaused;
      if (userPaused) stop();
      else start();
    }
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
      // If context loss happened before the choreographed rain start, the fresh sim is
      // warmed-up; empty it again so the black-then-build effect is preserved.
      if (performance.now() < rainStartAtMs) {
        sim.reset();
        resetExtras();
      }
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
    if (changed.has("preset")) {
      const preset = getPreset(controls.get().preset);
      applyChromeAccent(preset);
      applyFavicon(preset);
    }
    if (changed.has("glyphScale") && !superState) {
      applySize(cssW, cssH); // recomputes the grid and resizes the sim/state/renderer
    }
    if (changed.has("mirror")) {
      void buildGlyphAtlas(gl, { chars: glyphSet.chars, mirror: controls.get().mirror, cellPx: ATLAS_CELL_PX, mirrorExcludeFrom: glyphSet.ranges.message.start }).then(
        (a) => {
          const previous = atlas;
          atlas = a;
          renderer.setAtlas(a);
          gl.deleteTexture(previous.texture); // release the replaced atlas so toggling mirror doesn't leak VRAM
          if (!running) renderStatic();
        },
      );
    }
    // Adjusting Ramp-up replays the build-up from an empty grid so the slider gives immediate
    // feedback instead of only applying on the next load. Debounced so a drag settles first, and
    // only while the loop is animating in normal (non-super) mode.
    if (changed.has("rampUpMs") && !superState) {
      window.clearTimeout(rampPreviewTimer);
      const ms = controls.get().rampUpMs;
      if (ms > 0) rampPreviewTimer = window.setTimeout(() => { if (running && !superState) beginRampFromEmpty(ms); }, 200);
    }
    // While paused (reduced motion / hidden tab) the RAF loop isn't redrawing,
    // so reflect any control change — color, glow, quality, etc. — in a fresh frame.
    if (!running) renderStatic();
  });

  // ---------- Intro on first visit ----------
  const maybePlayIntro = (): void => {
    if (!message || !introStore || reduceMq.matches) return;
    let seen = false;
    try {
      seen = localStorage.getItem(INTRO_KEY) === "1";
    } catch {
      /* ignore */
    }
    if (seen) {
      // Repeat visit (no intro): start the rain from empty and ramp to density using the main
      // controls' Ramp-up. loadRampMs returns 0 (keep the warmed full start) unless a ramp is set.
      const ms = loadRampMs(true, controls.get().rampUpMs, reduceMq.matches);
      if (ms > 0) beginRampFromEmpty(ms);
      return;
    }
    markSeenPending = true;
    startIntroSequence(introStore.get());
  };

  if (panelConfig) {
    // This window was opened as a panel: render its slice and go fullscreen.
    enterSuperRender(panelConfig, false, []);
    exitChan = openExitChannel(() => exitSuper(false));
    void enterPanelFullscreen(container).then(() => {
      // Without the AutomaticFullscreen policy a panel can't self-fullscreen; hint
      // that a click will do it (a click carries the activation requestFullscreen needs).
      window.setTimeout(() => {
        if (!document.fullscreenElement) flashNotice("Click anywhere for fullscreen.");
      }, 600);
    });
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
      window.clearTimeout(rampPreviewTimer);
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
      editor?.destroy();
      messagesEditor?.destroy();
      countdownEditor?.destroy();
      panel?.destroy();
      message?.destroy();
      renderer.dispose();
      stateTex.dispose();
      for (const t of extraTexs) t.dispose();
      canvas.remove();
    },
  };
}
