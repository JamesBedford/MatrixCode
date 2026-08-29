// Orchestration for multi-monitor mode: from one gesture, fan the rain out onto
// every connected monitor. Uses the Chromium Window Management API
// (getScreenDetails + requestFullscreen({ screen })). Each monitor gets its own
// browser window rendering a slice of one shared virtual grid (see multiMonitorGrid.ts);
// the slices are kept in lockstep by a shared seed + wall-clock epoch, so no
// per-frame data crosses windows. Cross-window messaging is limited to
// BroadcastChannels for exiting the show and mirroring control changes.
//
// Degrades gracefully: on a single monitor, an unsupported browser, or a denied
// permission, the caller falls back to ordinary fullscreen on the current screen.

import { centermostScreenId, computeVirtualGrid, type GridSlice, type ScreenRect } from "./multiMonitorGrid.ts";
import type { Controls } from "../types.ts";

/** Everything a window needs to render its slice of the shared rain in lockstep. */
export interface MultiMonitorConfig {
  seed: number;
  /** Shared Date.now() baseline; all windows advance the sim relative to this. */
  epoch: number;
  warmupSeconds: number;
  /** Cell size in CSS px — uniform across windows so seams line up. */
  cell: number;
  vCols: number;
  vRows: number;
  /** Session-wide placement rule captured from the controller's vignette setting. */
  perDisplayMessages?: boolean;
  /** Physical screen this config renders; used for rebuilding geometry when glyph size changes. */
  screenId?: string;
  /** Full session screen layout; omitted only in legacy hashes. */
  screens?: ScreenRect[];
  /** Whether this window should keep the controls UI available in multi-monitor mode. */
  showControls?: boolean;
  slice: GridSlice;
}

export type MultiMonitorSessionResult =
  // Launched: this window's slice + the panel windows opened for the others.
  | { kind: "multiMonitor"; selfConfig: MultiMonitorConfig; openedWindows: Window[]; expectedPanels: number }
  // Single monitor / unsupported browser — caller should do ordinary fullscreen.
  | { kind: "fallback" }
  // The window-management permission is blocked/denied for this site.
  | { kind: "denied" }
  // Permission was just resolved (its prompt consumed this gesture) — the next
  // multi-monitor request will launch cleanly using the cached screen details.
  | { kind: "needsRetry" }
  // Pop-ups are blocked, so no panel windows could open.
  | { kind: "popupsBlocked" };

const CHANNEL_NAME = "mx-multimonitor-fullscreen";
const CONTROLS_CHANNEL_NAME = "mx-multimonitor-controls";
const HASH_KEY = "multimonitor";
const LEGACY_HASH_KEY = "superfs";
const MAX_PANEL_GRID_AXIS = 32_768;
const MAX_PANEL_GRID_CELLS = 4_194_304;
const MAX_PANEL_WARMUP_SECONDS = 60;
const MAX_PANEL_SCREENS = 64;

// Minimal structural types for the Window Management API (absent from lib.dom).
interface ScreenDetailed extends ScreenRect {
  availLeft: number;
  availTop: number;
  availWidth: number;
  availHeight: number;
}
interface ScreenDetails {
  screens: ScreenDetailed[];
  currentScreen: ScreenDetailed;
}

export function isSupported(): boolean {
  return typeof window !== "undefined" && "getScreenDetails" in window;
}

function getScreenDetails(): Promise<ScreenDetails> {
  return (window as unknown as { getScreenDetails(): Promise<ScreenDetails> }).getScreenDetails();
}

// When permission is already granted we fetch screen details ahead of the click,
// so the launch gesture isn't spent awaiting a permission prompt (which
// would consume the transient activation needed to open windows + go fullscreen).
let cachedDetails: ScreenDetails | null = null;

export async function prefetchScreens(): Promise<void> {
  if (!isSupported()) return;
  try {
    const status = await navigator.permissions?.query({
      name: "window-management",
    } as unknown as PermissionDescriptor);
    if (status && status.state === "granted") cachedDetails = await getScreenDetails();
  } catch {
    /* permission API or name unsupported — fall back to fetching on demand */
  }
}

async function cacheScreenDetails(): Promise<ScreenDetails | null> {
  try {
    cachedDetails = await getScreenDetails();
    return cachedDetails;
  } catch {
    return null;
  }
}

function screenIsExtended(): boolean {
  const screen = window.screen as Screen & { isExtended?: boolean };
  return screen.isExtended === true;
}

function cachedDetailsMayBeStale(details: ScreenDetails): boolean {
  return (details.screens?.length ?? 0) <= 1 && screenIsExtended();
}

/** A screen's rectangle is the *full* screen (fullscreen ignores menu bar/dock). */
function toRects(screens: ScreenDetailed[]): ScreenRect[] {
  return screens.map((s, i) => ({ id: `s${i}`, left: s.left, top: s.top, width: s.width, height: s.height }));
}

function indexOfCurrent(details: ScreenDetails): number {
  const cur = details.currentScreen;
  let idx = details.screens.indexOf(cur);
  if (idx >= 0) return idx;
  idx = details.screens.findIndex((s) => s.left === cur.left && s.top === cur.top);
  return idx >= 0 ? idx : 0;
}

function buildPanelUrl(config: MultiMonitorConfig): string {
  const base = location.origin + location.pathname + location.search;
  return `${base}#${HASH_KEY}=${encodeURIComponent(JSON.stringify(config))}`;
}

function finiteInteger(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= min && value <= max;
}

/** URL hashes are shareable/untrusted; reject values that could create invalid or enormous buffers. */
function isPanelConfig(value: unknown): value is MultiMonitorConfig {
  if (typeof value !== "object" || value === null) return false;
  const config = value as Record<string, unknown>;
  if (!finiteInteger(config.seed, 0, 0xffffffff)) return false;
  if (typeof config.epoch !== "number" || !Number.isFinite(config.epoch)) return false;
  if (
    typeof config.warmupSeconds !== "number" ||
    !Number.isFinite(config.warmupSeconds) ||
    config.warmupSeconds < 0 ||
    config.warmupSeconds > MAX_PANEL_WARMUP_SECONDS
  ) return false;
  if (typeof config.cell !== "number" || !Number.isFinite(config.cell) || config.cell <= 0) return false;
  if (!finiteInteger(config.vCols, 1, MAX_PANEL_GRID_AXIS)) return false;
  if (!finiteInteger(config.vRows, 1, MAX_PANEL_GRID_AXIS)) return false;
  if (config.vCols * config.vRows > MAX_PANEL_GRID_CELLS) return false;

  if (typeof config.slice !== "object" || config.slice === null) return false;
  const slice = config.slice as Record<string, unknown>;
  if (!finiteInteger(slice.colStart, 0, config.vCols - 1)) return false;
  if (!finiteInteger(slice.rowStart, 0, config.vRows - 1)) return false;
  if (!finiteInteger(slice.cols, 1, config.vCols - slice.colStart)) return false;
  if (!finiteInteger(slice.rows, 1, config.vRows - slice.rowStart)) return false;
  for (const origin of [slice.originX, slice.originY]) {
    if (origin !== undefined && (typeof origin !== "number" || !Number.isFinite(origin))) return false;
  }

  for (const flag of [config.perDisplayMessages, config.showControls]) {
    if (flag !== undefined && typeof flag !== "boolean") return false;
  }
  if (config.screenId !== undefined && typeof config.screenId !== "string") return false;
  if (config.screens !== undefined) {
    if (!Array.isArray(config.screens) || config.screens.length === 0 || config.screens.length > MAX_PANEL_SCREENS) {
      return false;
    }
    const ids = new Set<string>();
    for (const value of config.screens) {
      if (typeof value !== "object" || value === null) return false;
      const screen = value as Record<string, unknown>;
      if (typeof screen.id !== "string" || !screen.id || ids.has(screen.id)) return false;
      ids.add(screen.id);
      for (const coordinate of [screen.left, screen.top, screen.width, screen.height]) {
        if (typeof coordinate !== "number" || !Number.isFinite(coordinate)) return false;
      }
      if ((screen.width as number) <= 0 || (screen.height as number) <= 0) return false;
    }
    if (typeof config.screenId !== "string" || !ids.has(config.screenId)) return false;
    const geometry = computeVirtualGrid(config.screens as ScreenRect[], config.cell);
    const expectedSlice = geometry.slices[config.screenId];
    if (
      geometry.vCols !== config.vCols ||
      geometry.vRows !== config.vRows ||
      !expectedSlice ||
      expectedSlice.colStart !== slice.colStart ||
      expectedSlice.rowStart !== slice.rowStart ||
      expectedSlice.cols !== slice.cols ||
      expectedSlice.rows !== slice.rows
    ) return false;
  }
  return true;
}

/** Parse a panel config from a URL hash. Exported separately for compatibility tests. */
export function parsePanelHash(hash: string): MultiMonitorConfig | null {
  // Keep accepting the old key so panel URLs produced before the feature rename still load.
  const m = new RegExp(`[#&](?:${HASH_KEY}|${LEGACY_HASH_KEY})=([^&]+)`).exec(hash);
  if (!m) return null;
  try {
    const config = JSON.parse(decodeURIComponent(m[1]!)) as unknown;
    if (isPanelConfig(config)) return config;
  } catch {
    /* malformed — treat as a normal window */
  }
  return null;
}

/** Read this window's panel config from the URL hash, or null if not a panel. */
export function parsePanelConfig(): MultiMonitorConfig | null {
  return parsePanelHash(location.hash);
}

/**
 * Controller path: enumerate screens, open one window per other screen (each
 * carrying its slice in the URL hash), fullscreen the current screen, and return
 * this window's own slice config.
 *
 * The result is a discriminated union so the caller can give the user feedback
 * instead of silently half-launching: `fallback` (single monitor / unsupported
 * → ordinary fullscreen), `denied`, `needsRetry` (permission just resolved — its
 * prompt spent this gesture), or `popupsBlocked`.
 */
export async function startMultiMonitorSession(
  rootEl: HTMLElement,
  cell: number,
  warmupSeconds: number,
  perDisplayMessages: boolean,
): Promise<MultiMonitorSessionResult> {
  if (!isSupported()) return { kind: "fallback" };

  if (cachedDetails && cachedDetailsMayBeStale(cachedDetails)) {
    cachedDetails = null;
  }

  // An uncached getScreenDetails() can prompt, or otherwise spend enough of the
  // click's activation budget that window.open/requestFullscreen may be blocked
  // by the browser. Cache the details first, then launch from the next gesture.
  if (!cachedDetails) {
    const details = await cacheScreenDetails();
    if (!details) return { kind: "denied" };
    return (details.screens?.length ?? 0) > 1 ? { kind: "needsRetry" } : { kind: "fallback" };
  }

  const details = cachedDetails;
  if (!details.screens || details.screens.length <= 1) return { kind: "fallback" };

  const rects = toRects(details.screens);
  const grid = computeVirtualGrid(rects, cell);
  const controlsScreenId = centermostScreenId(rects);
  const seed = Math.floor(Math.random() * 0xffffffff) >>> 0;
  const epoch = Date.now();
  const curIdx = indexOfCurrent(details);

  const configFor = (i: number): MultiMonitorConfig => ({
    seed,
    epoch,
    warmupSeconds,
    cell,
    vCols: grid.vCols,
    vRows: grid.vRows,
    perDisplayMessages,
    screenId: rects[i]!.id,
    screens: rects,
    showControls: rects[i]!.id === controlsScreenId,
    slice: grid.slices[rects[i]!.id]!,
  });

  const openedWindows: Window[] = [];
  for (let i = 0; i < details.screens.length; i++) {
    if (i === curIdx) continue;
    const s = details.screens[i]!;
    const features = `popup,left=${Math.round(s.availLeft)},top=${Math.round(s.availTop)},width=${Math.round(
      s.availWidth,
    )},height=${Math.round(s.availHeight)}`;
    const w = window.open(buildPanelUrl(configFor(i)), `mx-monitor-${i}`, features);
    if (w) openedWindows.push(w);
  }

  const expectedPanels = details.screens.length - 1;
  // Nothing opened on a multi-screen setup → pop-ups are blocked. Don't fullscreen
  // the controller alone (that just looks like an ordinary double-click); report it.
  if (openedWindows.length === 0) return { kind: "popupsBlocked" };

  await requestScreenFullscreen(rootEl, details.currentScreen);

  return { kind: "multiMonitor", selfConfig: configFor(curIdx), openedWindows, expectedPanels };
}

/** Fullscreen `rootEl` on a specific screen, falling back to the current screen. */
async function requestScreenFullscreen(rootEl: HTMLElement, screen: ScreenDetailed): Promise<void> {
  try {
    await rootEl.requestFullscreen({ screen } as unknown as FullscreenOptions);
  } catch {
    try {
      await rootEl.requestFullscreen();
    } catch {
      /* no activation / not allowed — window stays full-bleed, user can click */
    }
  }
}

/**
 * Panel path: put this freshly-opened window fullscreen on the screen it landed
 * on. With the AutomaticFullscreen policy this needs no gesture; otherwise it
 * fails quietly and the window stays full-bleed until the user clicks.
 */
export async function enterPanelFullscreen(rootEl: HTMLElement): Promise<void> {
  if (isSupported()) {
    try {
      const details = await getScreenDetails();
      await requestScreenFullscreen(rootEl, details.currentScreen);
      return;
    } catch {
      /* fall through to plain fullscreen */
    }
  }
  try {
    await rootEl.requestFullscreen();
  } catch {
    /* user can click to fullscreen */
  }
}

/**
 * Open the shared exit channel. `onExit` fires when another window asks to end
 * the show; `broadcastExit()` asks every other window to end it.
 */
export function openExitChannel(onExit: () => void): { broadcastExit: () => void; close: () => void } {
  let ch: BroadcastChannel | null = null;
  try {
    ch = new BroadcastChannel(CHANNEL_NAME);
    ch.onmessage = (e: MessageEvent): void => {
      if (e.data && (e.data as { type?: string }).type === "exit") onExit();
    };
  } catch {
    ch = null; // BroadcastChannel unavailable — exit stays per-window
  }
  return {
    broadcastExit: () => {
      try {
        ch?.postMessage({ type: "exit" });
      } catch {
        /* ignore */
      }
    },
    close: () => {
      try {
        ch?.close();
      } catch {
        /* ignore */
      }
      ch = null;
    },
  };
}

export function openControlsChannel(
  onControls: (controls: Partial<Controls>) => void,
): { broadcastControls: (controls: Controls) => void; close: () => void } {
  let ch: BroadcastChannel | null = null;
  try {
    ch = new BroadcastChannel(CONTROLS_CHANNEL_NAME);
    ch.onmessage = (e: MessageEvent): void => {
      const data = e.data as { type?: string; controls?: Partial<Controls> } | undefined;
      if (data?.type === "controls" && data.controls && typeof data.controls === "object") {
        onControls(data.controls);
      }
    };
  } catch {
    ch = null;
  }
  return {
    broadcastControls: (controls: Controls) => {
      try {
        ch?.postMessage({ type: "controls", controls });
      } catch {
        /* ignore */
      }
    },
    close: () => {
      try {
        ch?.close();
      } catch {
        /* ignore */
      }
      ch = null;
    },
  };
}
