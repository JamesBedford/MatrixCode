import type { ColorPreset, Controls, Grid, RenderParams, MessagesDoc } from "./types.ts";
import { createGlyphSet } from "./sim/glyphSet.ts";
import { RainSim } from "./sim/rainSim.ts";
import { MessageScheduler } from "./sim/messageScheduler.ts";
import { createRng } from "./util/rng.ts";
import { MessageOverlay, resolveUserName } from "./sim/messageOverlay.ts";
import { resolveTokens } from "./sim/tokens.ts";
import { densityRampFactor, loadRampMs, rampEase } from "./sim/introRain.ts";
import { MAX_FRAME_CATCHUP_SECONDS, simulationStepPlan } from "./sim/frameSteps.ts";
import { advanceMultiClick, settledMultiClickAction } from "./sim/multiClick.ts";
import { computeLanes, tierCap, seedForLayer, MAX_LANES, type Lane } from "./sim/overlapLanes.ts";
import { DEFAULT_SIM_CONFIG } from "./config/simConfig.ts";
import { getPreset } from "./config/colorPresets.ts";
import { ControlsStore } from "./config/controls.ts";
import { glyphAtlasFontFamily } from "./config/glyphFonts.ts";
import { buildGlyphAtlas, type GlyphAtlas } from "./gl/glyphAtlas.ts";
import { StateTexture } from "./gl/stateTexture.ts";
import { Renderer, type ExtraLayer } from "./gl/renderer.ts";
import { AdaptiveResolution } from "./gl/adaptiveResolution.ts";
import { ControlsPanel } from "./ui/controlsPanel.ts";
import { CharacterSettingsEditor } from "./ui/characterSettingsEditor.ts";
import { applyFavicon } from "./ui/favicon.ts";
import { IntroStore, sanitizeIntro, toTypeConfig, type IntroScript } from "./config/introStore.ts";
import { IntroEditor } from "./ui/introEditor.ts";
import { MessagesStore } from "./config/messagesStore.ts";
import { MessagesEditor } from "./ui/messagesEditor.ts";
import { CountdownStore } from "./config/countdownStore.ts";
import { CountdownEditor } from "./ui/countdownEditor.ts";
import {
  loadFpsOverlayVisible,
  loadUiState,
  setActiveSettingsSurface,
  setFpsOverlayVisible,
  type ActiveSettingsSurface,
} from "./config/uiState.ts";
import { MODAL_OPEN_CHANGE_EVENT } from "./ui/modalKit.ts";
import { startCanvas2dRain } from "./fallback/canvas2dRain.ts";
import { computeVirtualGrid, stepsToAdvance, extractSlice } from "./multimonitor/multiMonitorGrid.ts";
import {
  type MultiMonitorConfig,
  type MultiMonitorSessionResult,
  startMultiMonitorSession,
  parsePanelConfig,
  enterPanelFullscreen,
  openExitChannel,
  openControlsChannel,
  prefetchScreens,
} from "./multimonitor/multiMonitorFullscreen.ts";
import {
  isNativeHosted,
  nativeMultiMonitorConfig,
  nativeStorageDidChange,
} from "./platform/nativeHost.ts";

export interface MatrixRainHandle {
  destroy: () => void;
  setActive: (active: boolean) => void;
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
// Multi-monitor mode lockstep: advance the shared sim in fixed steps toward the
// shared wall-clock, capping per-frame catch-up so a stalled window recovers
// gradually instead of freezing.
const MULTI_MONITOR_FIXED_DT = 1 / 60;
// Match normal mode's bounded catch-up window. The previous six-step budget accumulated simulation
// debt below 10 FPS, then visibly fast-forwarded when adaptive resolution recovered.
const MULTI_MONITOR_MAX_STEPS = Math.ceil(MAX_FRAME_CATCHUP_SECONDS / MULTI_MONITOR_FIXED_DT);
// Window within which consecutive background clicks count as one gesture.
const MULTI_CLICK_MS = 350;

/** Active multi-monitor mode state for this window (controller or a panel). */
interface MultiMonitorState {
  config: MultiMonitorConfig;
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

function createToast(parent: HTMLElement): HTMLElement {
  const toast = document.createElement("div");
  toast.className = "mx-toast";
  toast.setAttribute("role", "status");
  toast.setAttribute("aria-live", "polite");
  parent.appendChild(toast);
  return toast;
}

/** A tiny diagnostics overlay (smoothed FPS · render scale · backing resolution). */
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
      setActive: (active: boolean) => {
        if (active) fb.start();
        else fb.stop();
      },
      destroy: () => {
        fb.stop();
        ro.disconnect();
        canvas.remove();
      },
    };
  }

  // ---------- GPU path ----------
  const glyphSet = createGlyphSet(controls.get().glyphMode);
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
  const urlParams = new URLSearchParams(location.search);
  const adaptiveEnabled = urlParams.get("adaptive") !== "0";
  const hudRequested = urlParams.has("hud");
  if (hudRequested) setFpsOverlayVisible(true);
  let hud = hudRequested || loadFpsOverlayVisible() ? createHud(container) : null;
  let pending: { w: number; h: number } | null = null;
  let running = false;
  let hostActive = true;
  let raf = 0;
  let last = 0;
  // Token-facing FPS is tracked independently so it remains available in multi-monitor mode, whose
  // fixed-step branch intentionally bypasses the adaptive-resolution controller and its FPS EMA.
  let fpsLast = 0;
  let fpsEmaMs = 0;
  let currentFps = 0;
  let userPaused = false;
  // Intro rain choreography. Default sentinel: rain already running at full (no intro / repeat visit).
  let rainStartAtMs = Number.NEGATIVE_INFINITY;
  let rampUpMs = 0;
  let rainPendingAfterIntro = false;
  let pendingPostIntroDelayMs = 0;
  // Debounce so the live Ramp-up slider replays the build-up once the drag settles, not every step.
  let rampPreviewTimer = 0;

  // Multi-monitor mode: this window is a panel iff the URL carries a slice config.
  const nativeHosted = isNativeHosted();
  const panelConfig = nativeMultiMonitorConfig(controls.get()) ?? parsePanelConfig();
  const panelShowsControls = panelConfig?.showControls === true;
  const hasSettingsUi = !panelConfig || panelShowsControls;
  const hasIntroUi = !panelConfig;
  let multiMonitorState: MultiMonitorState | null = null;
  let exitChan: ReturnType<typeof openExitChannel> | null = null;
  let controlsChan: ReturnType<typeof openControlsChannel> | null = null;
  let applyingRemoteControls = false;

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

  const atlasOptions = (): Parameters<typeof buildGlyphAtlas>[1] => {
    const currentControls = controls.get();
    const digitMode =
      currentControls.glyphMode === "binary" || currentControls.glyphMode === "digits"
        ? currentControls.glyphMode
        : undefined;
    return {
      chars: glyphSet.chars,
      mirror: currentControls.mirror,
      fontFamily: glyphAtlasFontFamily(currentControls.glyphFont, currentControls.glyphMode),
      cellPx: ATLAS_CELL_PX,
      mirrorExcludeFrom: glyphSet.ranges.message.start,
      readableDigits: digitMode !== undefined,
      digitMode,
      digitStart: glyphSet.ranges.digits.start,
    };
  };

  const buildGpu = async (): Promise<void> => {
    atlas = await buildGlyphAtlas(gl, atlasOptions());
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
    return {
      controls,
      setActive: (active: boolean) => {
        if (active) fb.start();
        else fb.stop();
      },
      destroy: () => fb.stop(),
    };
  }

  // ---------- Overlays ----------
  // Multi-monitor panels never play the intro, but the centremost panel can expose settings.
  const introStore = hasIntroUi ? new IntroStore() : null;
  // Multi-monitor mode panels have no editor UI, but they still need the same persisted message and
  // countdown documents as the controller so every window can schedule an identical virtual-grid message.
  const messagesStore = new MessagesStore();
  const countdownStore = new CountdownStore();
  const viewerName = resolveUserName();
  // When this run began — drives {uptime} and bare {countup} (see resolveTokens / countTarget).
  const runStartMs = Date.now();
  // Super mode temporarily supplies its shared fixed-step wall clock so ticking tokens resolve
  // identically in every window instead of depending on each panel's slightly different Date.now().
  let tokenClockMs: number | null = null;
  // One pure resolver for every surface (intro + in-rain messages). Reads the clock, the default
  // target, and the named moments live, so {time}/{countdown}/{countup} tick without any reconfigure.
  const resolveMessageText = (raw: string): string => {
    const doc = countdownStore?.get();
    return resolveTokens(raw, {
      name: viewerName,
      nowMs: tokenClockMs ?? Date.now(),
      countdownTargetMs: doc?.targetMs ?? null,
      moments: Object.fromEntries((doc?.moments ?? []).map((m) => [m.name, m.targetMs])),
      runStartMs: multiMonitorState?.config.epoch ?? runStartMs,
      fps: currentFps,
    });
  };
  // Current moment names, for the intro/messages editors' token hover.
  const getMomentNames = (): string[] => (countdownStore?.get().moments ?? []).map((m) => m.name);

  const createMessageScheduler = (doc: MessagesDoc = messagesStore.get()): MessageScheduler => {
    const scheduler = new MessageScheduler({ glyphSet, rng: createRng(MSG_SEED), resolveText: resolveMessageText });
    scheduler.configure(doc);
    return scheduler;
  };
  let messageScheduler = createMessageScheduler();
  const message = hasIntroUi ? new MessageOverlay(container, { resolveText: resolveMessageText }) : null;

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
        nativeStorageDidChange(INTRO_KEY, "1");
      } catch {
        /* ignore */
      }
    }
  });

  let editor: IntroEditor | null = null;
  if (hasIntroUi && introStore && message) {
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

  let characterEditor: CharacterSettingsEditor | null = null;
  if (hasSettingsUi) {
    characterEditor = new CharacterSettingsEditor(container, controls);
  }

  const bindSettingsSurface = (modal: { el: HTMLElement } | null, surface: ActiveSettingsSurface): void => {
    modal?.el.addEventListener(MODAL_OPEN_CHANGE_EVENT, (event) => {
      const open = (event as CustomEvent<{ open: boolean }>).detail.open;
      if (open) {
        setActiveSettingsSurface(surface);
      } else if (loadUiState().activeSettingsSurface === surface) {
        setActiveSettingsSurface(null);
      }
    });
  };
  bindSettingsSurface(characterEditor, "characters");
  bindSettingsSurface(editor, "intro");
  bindSettingsSurface(messagesEditor, "messages");
  bindSettingsSurface(countdownEditor, "countdown");

  const openSettingsSurface = (surface: ActiveSettingsSurface): void => {
    if (surface === "characters" && characterEditor) characterEditor.open();
    else if (surface === "intro" && editor) editor.open();
    else if (surface === "messages" && messagesEditor) messagesEditor.open();
    else if (surface === "countdown" && countdownEditor) countdownEditor.open();
    else setActiveSettingsSurface(null);
  };

  const panel = hasSettingsUi
    ? new ControlsPanel(container, controls, {
        onToggleFullscreen: () => toggleFullscreen(),
        onEnterMultiMonitor: () => { void enterMultiMonitor(); },
        onExitMultiMonitor: () => exitMultiMonitor(true),
        onReplayIntro: () => { if (introStore) startIntroSequence(introStore.get()); },
        onEditCharacters: () => openSettingsSurface("characters"),
        onEditIntro: () => openSettingsSurface("intro"),
        onEditMessages: () => openSettingsSurface("messages"),
        onEditCountdown: () => openSettingsSurface("countdown"),
      }, { multiMonitor: panelConfig !== null, introControls: hasIntroUi, documentEditors: !panelConfig })
    : null;

  const reduceMq = window.matchMedia("(prefers-reduced-motion: reduce)");

  const activeExtraLayers = (): ExtraLayer[] => {
    const layers: ExtraLayer[] = [];
    const c = controls.get();
    for (const lane of computeLanes(c.density, c.allowOverlap, tierCap(c.quality))) {
      if (lane.index === 0) continue;
      const j = lane.index - 1;
      const s = extraSims[j];
      const t = extraTexs[j];
      if (!s || !t || !extraActive[j]) continue;
      t.upload(s.state);
      layers.push({ texture: t.texture, colOffset: lane.offset });
    }
    return layers;
  };

  // Draw one frame from the current sim state. In multi-monitor mode it paints this
  // window's slice of the shared grid; otherwise the whole grid.
  const paint = (): void => {
    if (!sim) return;
    if (multiMonitorState) {
      const { vCols, vRows, slice } = multiMonitorState.config;
      extractSlice(sim.state, vCols, vRows, slice, multiMonitorState.localState);
      stateTex.upload(multiMonitorState.localState);
    } else {
      stateTex.upload(sim.state);
    }
    const slice = multiMonitorState?.config.slice;
    const viewport = multiMonitorState && slice
      ? {
          cell: multiMonitorState.config.cell,
          originX: slice.originX ?? 0,
          originY: slice.originY ?? 0,
          width: cssW,
          height: cssH,
        }
      : undefined;
    renderer.renderFrame(
      paramsOf(controls.get()),
      grid,
      multiMonitorState ? undefined : activeExtraLayers(),
      viewport,
    );
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
    const fpsIntervalMs = Math.min(Math.max(now - fpsLast, 0), 100);
    fpsLast = now;
    fpsEmaMs = fpsEmaMs === 0 ? fpsIntervalMs : fpsEmaMs + 0.15 * (fpsIntervalMs - fpsEmaMs);
    currentFps = fpsEmaMs > 0 ? 1000 / fpsEmaMs : 0;
    // Snapshot the controls once per frame and reuse for both the sim step and the render
    // params, instead of spreading the store twice.
    const c = controls.get();
    if (multiMonitorState) {
      // Advance toward the shared wall-clock so every window stays in lockstep.
      const target = multiMonitorState.config.warmupSeconds + (Date.now() - multiMonitorState.config.epoch) / 1000;
      const steps = stepsToAdvance(target, multiMonitorState.simClock, MULTI_MONITOR_FIXED_DT, MULTI_MONITOR_MAX_STEPS);
      for (let i = 0; i < steps; i++) {
        // Drive scheduling from the shared fixed-step clock, not this window's RAF/performance clock.
        // Recreated schedulers + identical clocks keep message choice, placement, and timing in sync.
        tokenClockMs =
          multiMonitorState.config.epoch +
          (multiMonitorState.simClock + i * MULTI_MONITOR_FIXED_DT - multiMonitorState.config.warmupSeconds) * 1000;
        messageScheduler.update(
          (multiMonitorState.simClock + i * MULTI_MONITOR_FIXED_DT) * 1000,
          sim,
          (multiMonitorState.config.perDisplayMessages ?? c.vignette > 0)
            ? [multiMonitorState.config.slice]
            : undefined,
        );
        sim.update(MULTI_MONITOR_FIXED_DT, c);
      }
      tokenClockMs = null;
      multiMonitorState.simClock += steps * MULTI_MONITOR_FIXED_DT;
      paint();
      return;
    }
    flushResize();
    const intervalMs = now - last;
    const stepPlan = simulationStepPlan(intervalMs / 1000);
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
      hud.textContent = `${currentFps.toFixed(0)} fps · ${Math.round(renderScale * 100)}% res · ${canvas.width}×${canvas.height}`;
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
      for (let i = 0; i < stepPlan.steps; i++) {
        sim.update(stepPlan.dt, laneControls(c, lanes[0]!.density));
        // Overlap layers (index >= 1): independent sims at fractional offsets, composited additively.
        // On a slow render frame, bounded substeps preserve wall-clock speed instead of dropping time.
        extraLayers = updateExtraLayers(lanes, stepPlan.dt, c, intro);
      }
    }
    // Before rainStartAtMs (after-mode, pre-start): don't advance — the empty grid renders black.
    stateTex.upload(sim.state);
    renderer.renderFrame(paramsOf(c), grid, extraLayers);
    message?.update(now);
  };

  const start = (): void => {
    if (running) return;
    if (!hostActive || reduceMq.matches || userPaused) {
      renderStatic();
      return;
    }
    running = true;
    last = performance.now();
    fpsLast = last;
    raf = requestAnimationFrame(loop);
  };

  const stop = (): void => {
    running = false;
    cancelAnimationFrame(raf);
  };

  // In multi-monitor mode the grid is fixed by the shared geometry, so a resize (e.g. the
  // fullscreen transition) only updates the device-pixel canvas size, never the grid.
  const applyMultiMonitorDeviceSize = (): void => {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    cssW = window.innerWidth;
    cssH = window.innerHeight;
    deviceW = Math.max(1, Math.round(cssW * dpr));
    deviceH = Math.max(1, Math.round(cssH * dpr));
    canvas.width = deviceW;
    canvas.height = deviceH;
    renderer.resize(deviceW, deviceH, controls.get().quality);
  };

  const rebuildMultiMonitorGeometry = (): void => {
    const state = multiMonitorState;
    if (!state?.config.screens || !state.config.screenId) return;
    const cell = DEFAULT_SIM_CONFIG.targetCellPx * controls.get().glyphScale;
    const virtual = computeVirtualGrid(state.config.screens, cell);
    const slice = virtual.slices[state.config.screenId];
    if (!slice) return;
    enterMultiMonitorRender(
      {
        ...state.config,
        cell,
        vCols: virtual.vCols,
        vRows: virtual.vRows,
        slice,
      },
      state.isController,
      state.openedWindows,
    );
  };

  // ---------- Resize ----------
  const handleResize = (w: number, h: number): void => {
    if (multiMonitorState) {
      applyMultiMonitorDeviceSize();
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
    if (nativeHosted) return;
    if (document.fullscreenElement) void document.exitFullscreen();
    else void container.requestFullscreen?.();
  };

  // ---------- Multi-monitor mode (all monitors) ----------
  // Switch this window's rain into a slice of the shared virtual grid.
  const enterMultiMonitorRender = (config: MultiMonitorConfig, isController: boolean, openedWindows: Window[]): void => {
    container.classList.add("mx-multimonitor");
    container.classList.toggle("mx-multimonitor-controls", config.showControls === true);
    sim = new RainSim({ cols: config.vCols, rows: config.vRows, config: DEFAULT_SIM_CONFIG, glyphSet, seed: config.seed });
    sim.warmUpDistributed(controls.get(), config.warmupSeconds);
    // The controller's normal-mode scheduler has already consumed random values while panel schedulers
    // are fresh. Reload persisted settings and restart all schedulers here so the original window
    // cannot retain a stale document while newly opened panel windows use the latest one.
    messageScheduler = createMessageScheduler(new MessagesStore().get());
    const lc = config.slice.cols;
    const lr = config.slice.rows;
    stateTex.resize(lc, lr);
    grid = { cols: lc, rows: lr };
    multiMonitorState = {
      config,
      isController,
      openedWindows,
      localState: new Uint8Array(lc * lr * 4),
      simClock: config.warmupSeconds,
    };
    controlsChan ??= openControlsChannel((remoteControls) => {
      applyingRemoteControls = true;
      try {
        controls.set(remoteControls);
      } finally {
        applyingRemoteControls = false;
      }
    });
    pending = null; // discard any normal-mode resize queued before the switch
    applyMultiMonitorDeviceSize();
    start();
    renderStatic();
  };

  const exitMultiMonitor = (broadcast: boolean): void => {
    if (!multiMonitorState) return;
    const { isController, openedWindows } = multiMonitorState;
    if (broadcast) exitChan?.broadcastExit();
    exitChan?.close();
    exitChan = null;
    controlsChan?.close();
    controlsChan = null;
    multiMonitorState = null;
    container.classList.remove("mx-multimonitor");
    container.classList.remove("mx-multimonitor-controls");
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
      messageScheduler = createMessageScheduler();
      resetExtras(); // overlap is disabled in multi-monitor mode; start the overlap lanes clean on return
      renderStatic();
    } else if (!nativeHosted) {
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

  let shortcutToast: HTMLElement | null = null;
  let shortcutToastTimer = 0;
  const showShortcutToast = (label: string, enabled: boolean): void => {
    shortcutToast ??= createToast(container);
    shortcutToast.textContent = `${label} ${enabled ? "enabled" : "disabled"}`;
    shortcutToast.classList.remove("is-visible");
    // Restart the transition when the user toggles repeatedly.
    void shortcutToast.offsetWidth;
    shortcutToast.classList.add("is-visible");
    window.clearTimeout(shortcutToastTimer);
    shortcutToastTimer = window.setTimeout(() => {
      shortcutToast?.classList.remove("is-visible");
    }, 1700);
  };

  // Controller path: start multi-monitor mode across every available monitor.
  const enterMultiMonitor = async (): Promise<void> => {
    if (nativeHosted || multiMonitorState || panelConfig) return;
    const cell = DEFAULT_SIM_CONFIG.targetCellPx * controls.get().glyphScale;
    let res: MultiMonitorSessionResult;
    try {
      res = await startMultiMonitorSession(container, cell, WARMUP_SECONDS, controls.get().vignette > 0);
    } catch {
      res = { kind: "fallback" };
    }
    switch (res.kind) {
      case "fallback":
        // Single monitor / unsupported browser: use ordinary fullscreen instead.
        if (!document.fullscreenElement) toggleFullscreen();
        return;
      case "denied":
        flashNotice("Allow “Window management” for this site (address-bar site settings), then choose Multi-monitor again.");
        return;
      case "needsRetry":
        flashNotice("Multi-monitor mode is ready — choose Multi-monitor again to launch.");
        return;
      case "popupsBlocked":
        flashNotice("Pop-ups are blocked — allow pop-ups for this site, then choose Multi-monitor again.");
        return;
      case "multiMonitor":
        if (res.openedWindows.length < res.expectedPanels) {
          flashNotice("Some windows were blocked — allow pop-ups for this site to fill every monitor.");
        }
        exitChan = openExitChannel(() => exitMultiMonitor(false));
        enterMultiMonitorRender(res.selfConfig, true, res.openedWindows);
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
  const toggleMessages = (announce = false): void => {
    if (!messageScheduler) return;
    const doc = messagesStore.get();
    doc.enabled = !doc.enabled;
    messagesStore.set(doc);
    messageScheduler.configure(messagesStore.get());
    messagesEditor?.syncEnabled(doc.enabled);
    if (announce) showShortcutToast("Messages", doc.enabled);
  };

  const setHudVisible = (visible: boolean): void => {
    if (visible === Boolean(hud)) return;
    if (visible) {
      hud = createHud(container);
    } else {
      hud?.remove();
      hud = null;
    }
    setFpsOverlayVisible(visible);
  };

  const toggleHud = (): void => {
    setHudVisible(!hud);
  };

  const isTextInputEvent = (e: KeyboardEvent): boolean => {
    const target = e.target;
    if (!(target instanceof HTMLElement)) return false;
    if (target.isContentEditable) return true;
    return target instanceof HTMLInputElement ||
      target instanceof HTMLTextAreaElement ||
      target instanceof HTMLSelectElement;
  };

  const onKey = (e: KeyboardEvent): void => {
    let handled = false;
    if (multiMonitorState && multiMonitorState.config.showControls !== true) {
      if (e.key === "Escape") {
        exitMultiMonitor(true);
        handled = true;
      }
      if (handled) {
        e.preventDefault();
        e.stopPropagation();
      }
      return;
    }
    if (e.key === "Escape" && panel?.dismiss()) handled = true;
    else if (multiMonitorState && e.key === "Escape") {
      exitMultiMonitor(true);
      handled = true;
    }
    if (!handled && isTextInputEvent(e)) return;
    if (!handled && multiMonitorState) {
      if (!e.repeat && e.altKey && !e.metaKey && !e.ctrlKey && e.code === "KeyF") { toggleHud(); handled = true; }
      else if (e.key === "h" || e.key === "H") { panel?.toggleVisible(); handled = true; }
      else if (e.key === "-" || e.key === "_") { nudgeDensity(1 / DENSITY_KEY_STEP); handled = true; }
      else if (e.key === "=" || e.key === "+") { nudgeDensity(DENSITY_KEY_STEP); handled = true; }
    } else if (!handled) {
      if (!e.repeat && e.altKey && !e.metaKey && !e.ctrlKey && e.code === "KeyF") { toggleHud(); handled = true; }
      else if (e.key === "f" || e.key === "F") { toggleFullscreen(); handled = true; }
      else if (e.key === "h" || e.key === "H") { panel?.toggleVisible(); handled = true; }
      else if (e.key === "i" || e.key === "I") { openSettingsSurface("intro"); handled = true; }
      else if (!e.repeat && e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey && e.code === "KeyM") { toggleMessages(true); handled = true; }
      else if (e.key === "m" || e.key === "M") { openSettingsSurface("messages"); handled = true; }
      else if (e.key === "c" || e.key === "C") { openSettingsSurface("countdown"); handled = true; }
      else if (e.key === "n" || e.key === "N") { toggleMessages(true); handled = true; }
      else if (e.key === "-" || e.key === "_") { nudgeDensity(1 / DENSITY_KEY_STEP); handled = true; }
      else if (e.key === "=" || e.key === "+") { nudgeDensity(DENSITY_KEY_STEP); handled = true; }
      else if (e.key === "p" || e.key === "P") {
        handled = true;
        if (!e.repeat) {
          userPaused = !userPaused;
          if (userPaused) {
            stop();
            renderStatic();
          } else {
            start();
          }
        }
      }
      else if (e.key === "Escape") { message?.skip(); handled = true; }
    }
    if (handled) {
      e.preventDefault();
      e.stopPropagation();
    }
  };
  window.addEventListener("keydown", onKey);

  const onPointerDown = (): void => {
    if (message?.isPlaying()) message.skip();
  };
  window.addEventListener("pointerdown", onPointerDown);

  // Backdrop shortcut: double-click enters ordinary fullscreen; triple-click enters multi-monitor mode.
  // Wait out the triple-click window before ordinary fullscreen; transitioning on click two can
  // swallow click three. Multi-monitor mode still launches immediately on the third click's activation.
  let clickCount = 0;
  let clickTimer = 0;
  const onCanvasClick = (): void => {
    if (multiMonitorState) return;
    const next = advanceMultiClick(clickCount);
    clickCount = next.count;
    if (next.action === "multiMonitor") {
      window.clearTimeout(clickTimer);
      void enterMultiMonitor();
      return;
    }
    window.clearTimeout(clickTimer);
    clickTimer = window.setTimeout(() => {
      if (settledMultiClickAction(clickCount) === "fullscreen") toggleFullscreen();
      clickCount = 0;
    }, MULTI_CLICK_MS);
  };
  // In a panel, a click is just a way to enter fullscreen if the policy didn't.
  const onPanelClick = (): void => {
    if (nativeHosted) return;
    if (!document.fullscreenElement) void enterPanelFullscreen(container);
  };
  canvas.addEventListener("click", panelConfig ? onPanelClick : onCanvasClick);

  // Esc inside fullscreen is intercepted by the browser (no keydown reaches us),
  // so the authoritative "show ended" signal is leaving fullscreen.
  const onFullscreenChange = (): void => {
    if (nativeHosted) return;
    if (multiMonitorState && !document.fullscreenElement) exitMultiMonitor(true);
  };
  document.addEventListener("fullscreenchange", onFullscreenChange);
  // Closing any window ends the whole show.
  const onBeforeUnload = (): void => {
    if (multiMonitorState) exitChan?.broadcastExit();
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
  const unsubscribe = controls.subscribe((state, changed) => {
    if (multiMonitorState && controlsChan && !applyingRemoteControls) {
      controlsChan.broadcastControls(state);
    }
    if (changed.has("preset")) {
      const preset = getPreset(controls.get().preset);
      applyChromeAccent(preset);
      applyFavicon(preset);
    }
    if (changed.has("glyphScale")) {
      if (multiMonitorState) rebuildMultiMonitorGeometry();
      else applySize(cssW, cssH); // recomputes the grid and resizes the sim/state/renderer
    }
    if (changed.has("glyphMode")) {
      glyphSet.setGlyphMode(controls.get().glyphMode);
    }
    if (changed.has("mirror") || changed.has("glyphFont") || changed.has("glyphMode")) {
      void buildGlyphAtlas(gl, atlasOptions()).then(
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
    // only while the loop is animating in normal (non-multi-monitor) mode.
    if (changed.has("rampUpMs") && !multiMonitorState) {
      window.clearTimeout(rampPreviewTimer);
      const ms = controls.get().rampUpMs;
      if (ms > 0) rampPreviewTimer = window.setTimeout(() => { if (running && !multiMonitorState) beginRampFromEmpty(ms); }, 200);
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
    // Browser panels request fullscreen themselves. Native screen saver views are
    // already fullscreen and receive their slice from the host launch payload.
    enterMultiMonitorRender(panelConfig, false, []);
    if (!nativeHosted) {
      exitChan = openExitChannel(() => exitMultiMonitor(false));
      void enterPanelFullscreen(container).then(() => {
        // Without the AutomaticFullscreen policy a panel can't self-fullscreen; hint
        // that a click will do it (a click carries the activation requestFullscreen needs).
        window.setTimeout(() => {
          if (!document.fullscreenElement) flashNotice("Click anywhere for fullscreen.");
        }, 600);
      });
    }
  } else {
    start();
    maybePlayIntro();
    if (!running) renderStatic(); // reduced-motion: ensure one frame is shown
    const restoredSurface = loadUiState().activeSettingsSurface;
    if (restoredSurface) openSettingsSurface(restoredSurface);
    if (!nativeHosted) void prefetchScreens(); // warm screen details before multi-monitor mode is requested
  }

  return {
    controls,
    setActive: (active: boolean) => {
      hostActive = active;
      if (active) start();
      else stop();
    },
    destroy: () => {
      if (multiMonitorState) exitMultiMonitor(false);
      controlsChan?.close();
      stop();
      window.clearTimeout(shortcutToastTimer);
      window.clearTimeout(rampPreviewTimer);
      ro.disconnect();
      window.removeEventListener("resize", onWindowResize);
      reduceMq.removeEventListener("change", onReduceChange);
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("pointerdown", onPointerDown);
      canvas.removeEventListener("click", panelConfig ? onPanelClick : onCanvasClick);
      hud?.remove();
      document.removeEventListener("fullscreenchange", onFullscreenChange);
      window.removeEventListener("beforeunload", onBeforeUnload);
      canvas.removeEventListener("webglcontextlost", onLost);
      unsubscribe();
      editor?.destroy();
      messagesEditor?.destroy();
      countdownEditor?.destroy();
      characterEditor?.destroy();
      panel?.destroy();
      message?.destroy();
      shortcutToast?.remove();
      renderer.dispose();
      stateTex.dispose();
      for (const t of extraTexs) t.dispose();
      canvas.remove();
    },
  };
}
