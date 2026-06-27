// Orchestration for "super fullscreen": from one gesture, fan the rain out onto
// every connected monitor. Uses the Chromium Window Management API
// (getScreenDetails + requestFullscreen({ screen })). Each monitor gets its own
// browser window rendering a slice of one shared virtual grid (see superGrid.ts);
// the slices are kept in lockstep by a shared seed + wall-clock epoch, so no
// per-frame data crosses windows. Cross-window messaging is limited to a single
// BroadcastChannel used to exit the whole show at once.
//
// Degrades gracefully: on a single monitor, an unsupported browser, or a denied
// permission, the caller falls back to ordinary fullscreen on the current screen.

import { computeVirtualGrid, type GridSlice, type ScreenRect } from "./superGrid.ts";

/** Everything a window needs to render its slice of the shared rain in lockstep. */
export interface SuperConfig {
  seed: number;
  /** Shared Date.now() baseline; all windows advance the sim relative to this. */
  epoch: number;
  warmupSeconds: number;
  /** Cell size in CSS px — uniform across windows so seams line up. */
  cell: number;
  vCols: number;
  vRows: number;
  slice: GridSlice;
}

export type SuperSessionResult =
  | { kind: "super"; selfConfig: SuperConfig; openedWindows: Window[] }
  | { kind: "fallback" };

const CHANNEL_NAME = "mx-superfs";
const HASH_KEY = "superfs";

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
// so the triple-click gesture isn't spent awaiting a permission prompt (which
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

function buildPanelUrl(config: SuperConfig): string {
  const base = location.origin + location.pathname + location.search;
  return `${base}#${HASH_KEY}=${encodeURIComponent(JSON.stringify(config))}`;
}

/** Read this window's panel config from the URL hash, or null if not a panel. */
export function parsePanelConfig(): SuperConfig | null {
  const m = new RegExp(`[#&]${HASH_KEY}=([^&]+)`).exec(location.hash);
  if (!m) return null;
  try {
    const cfg = JSON.parse(decodeURIComponent(m[1]!)) as SuperConfig;
    if (typeof cfg.vCols === "number" && typeof cfg.vRows === "number" && cfg.slice) return cfg;
  } catch {
    /* malformed — treat as a normal window */
  }
  return null;
}

/**
 * Controller path: enumerate screens, open one window per other screen (each
 * carrying its slice in the URL hash), fullscreen the current screen, and return
 * this window's own slice config. Returns `fallback` when the multi-monitor path
 * isn't available so the caller can do ordinary fullscreen instead.
 */
export async function startSuperSession(
  rootEl: HTMLElement,
  cell: number,
  warmupSeconds: number,
): Promise<SuperSessionResult> {
  if (!isSupported()) return { kind: "fallback" };

  let details: ScreenDetails;
  try {
    details = cachedDetails ?? (await getScreenDetails());
    cachedDetails = details;
  } catch {
    return { kind: "fallback" }; // permission denied
  }
  if (!details.screens || details.screens.length <= 1) return { kind: "fallback" };

  const rects = toRects(details.screens);
  const grid = computeVirtualGrid(rects, cell);
  const seed = Math.floor(Math.random() * 0xffffffff) >>> 0;
  const epoch = Date.now();
  const curIdx = indexOfCurrent(details);

  const configFor = (i: number): SuperConfig => ({
    seed,
    epoch,
    warmupSeconds,
    cell,
    vCols: grid.vCols,
    vRows: grid.vRows,
    slice: grid.slices[rects[i]!.id]!,
  });

  const openedWindows: Window[] = [];
  for (let i = 0; i < details.screens.length; i++) {
    if (i === curIdx) continue;
    const s = details.screens[i]!;
    const features = `popup,left=${Math.round(s.availLeft)},top=${Math.round(s.availTop)},width=${Math.round(
      s.availWidth,
    )},height=${Math.round(s.availHeight)}`;
    const w = window.open(buildPanelUrl(configFor(i)), `mx-panel-${i}`, features);
    if (w) openedWindows.push(w);
  }

  await requestScreenFullscreen(rootEl, details.currentScreen);

  return { kind: "super", selfConfig: configFor(curIdx), openedWindows };
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
