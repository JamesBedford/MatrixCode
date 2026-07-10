import type { Controls } from "../types.ts";
import { DEFAULT_SIM_CONFIG } from "../config/simConfig.ts";
import { centermostScreenId, computeVirtualGrid, type ScreenRect } from "../multimonitor/multiMonitorGrid.ts";
import type { MultiMonitorConfig } from "../multimonitor/multiMonitorFullscreen.ts";

export const NATIVE_STORAGE_KEYS = [
  "mx-controls",
  "mx-intro",
  "mx-messages",
  "mx-countdown",
  "mx-ui-state",
  "mx-user-name",
  "mx-intro-seen",
] as const;

export type NativeStorageKey = (typeof NATIVE_STORAGE_KEYS)[number];
export type NativeHostMode = "screensaver" | "configuration";

export interface NativeScreen extends ScreenRect {}

export interface NativeSession {
  seed: number;
  epoch: number;
  warmupSeconds: number;
  screens: NativeScreen[];
  currentScreenId: string;
  controlsScreenId?: string;
}

export interface NativeHostPayload {
  mode: NativeHostMode;
  bootstrapId: string;
  storage: Partial<Record<NativeStorageKey, string>>;
  session?: NativeSession;
}

interface NativeMessageHandler {
  postMessage(message: { key: NativeStorageKey; value: string | null }): void;
}

declare global {
  interface Window {
    __MATRIXCODE_NATIVE__?: NativeHostPayload;
    __matrixCodeSetActive?: (active: boolean) => void;
    webkit?: {
      messageHandlers?: {
        matrixCodeStorage?: NativeMessageHandler;
      };
    };
  }
}

const BOOTSTRAP_KEY = "mx-native-bootstrap";
let pendingActive: boolean | null = null;

function isStorageKey(key: string): key is NativeStorageKey {
  return (NATIVE_STORAGE_KEYS as readonly string[]).includes(key);
}

function browserPreviewPayload(storage: Storage): NativeHostPayload | null {
  try {
    const mode = new URLSearchParams(window.location.search).get("native");
    if (mode !== "screensaver" && mode !== "configuration") return null;
    const values: Partial<Record<NativeStorageKey, string>> = {};
    for (const key of NATIVE_STORAGE_KEYS) {
      const value = storage.getItem(key);
      if (value !== null) values[key] = value;
    }
    return {
      mode,
      bootstrapId: `browser-preview-${mode}`,
      storage: values,
    };
  } catch {
    return null;
  }
}

export function sanitizeNativePayload(raw: unknown): NativeHostPayload | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  if (r.mode !== "screensaver" && r.mode !== "configuration") return null;
  if (typeof r.bootstrapId !== "string" || !r.bootstrapId) return null;

  const storage: Partial<Record<NativeStorageKey, string>> = {};
  if (typeof r.storage === "object" && r.storage !== null) {
    for (const [key, value] of Object.entries(r.storage)) {
      if (isStorageKey(key) && typeof value === "string") storage[key] = value;
    }
  }

  let session: NativeSession | undefined;
  if (typeof r.session === "object" && r.session !== null) {
    const s = r.session as Record<string, unknown>;
    const screens = Array.isArray(s.screens)
      ? s.screens.filter((screen): screen is NativeScreen => {
          if (typeof screen !== "object" || screen === null) return false;
          const candidate = screen as Record<string, unknown>;
          return (
            typeof candidate.id === "string" &&
            ["left", "top", "width", "height"].every(
              (key) => typeof candidate[key] === "number" && Number.isFinite(candidate[key]),
            )
          );
        })
      : [];
    if (
      typeof s.seed === "number" &&
      Number.isFinite(s.seed) &&
      typeof s.epoch === "number" &&
      Number.isFinite(s.epoch) &&
      typeof s.warmupSeconds === "number" &&
      Number.isFinite(s.warmupSeconds) &&
      typeof s.currentScreenId === "string" &&
      screens.some((screen) => screen.id === s.currentScreenId)
    ) {
      const controlsScreenId = typeof s.controlsScreenId === "string" &&
        screens.some((screen) => screen.id === s.controlsScreenId)
        ? s.controlsScreenId
        : undefined;
      session = {
        seed: s.seed >>> 0,
        epoch: s.epoch,
        warmupSeconds: Math.max(0, s.warmupSeconds),
        screens,
        currentScreenId: s.currentScreenId,
        ...(controlsScreenId ? { controlsScreenId } : {}),
      };
    }
  }

  return {
    mode: r.mode,
    bootstrapId: r.bootstrapId,
    storage,
    ...(session ? { session } : {}),
  };
}

export function bootstrapNativeHost(storage: Storage = window.localStorage): NativeHostPayload | null {
  const payload = sanitizeNativePayload(window.__MATRIXCODE_NATIVE__) ?? browserPreviewPayload(storage);
  if (!payload) return null;
  window.__MATRIXCODE_NATIVE__ = payload;

  try {
    if (storage.getItem(BOOTSTRAP_KEY) !== payload.bootstrapId) {
      for (const key of NATIVE_STORAGE_KEYS) {
        const value = payload.storage[key];
        if (value === undefined) storage.removeItem(key);
        else storage.setItem(key, value);
      }
      storage.setItem(BOOTSTRAP_KEY, payload.bootstrapId);
    }
  } catch {
    // The app's stores already tolerate unavailable storage.
  }

  document.documentElement.classList.add(
    payload.mode === "configuration" ? "mx-native-config" : "mx-native-saver",
  );
  window.__matrixCodeSetActive = (active: boolean): void => {
    pendingActive = active;
  };
  return payload;
}

export function nativePayload(): NativeHostPayload | null {
  return sanitizeNativePayload(window.__MATRIXCODE_NATIVE__);
}

export function isNativeHosted(): boolean {
  return nativePayload() !== null;
}

export function isNativeConfiguration(): boolean {
  return nativePayload()?.mode === "configuration";
}

export function nativeStorageDidChange(key: NativeStorageKey, value: string | null): void {
  try {
    window.webkit?.messageHandlers?.matrixCodeStorage?.postMessage({ key, value });
  } catch {
    // Native persistence must never interfere with rendering or editing.
  }
}

export function nativeMultiMonitorConfig(controls: Controls): MultiMonitorConfig | null {
  const payload = nativePayload();
  const session = payload?.mode === "screensaver" ? payload.session : undefined;
  if (!session || session.screens.length <= 1) return null;

  const cell = DEFAULT_SIM_CONFIG.targetCellPx * controls.glyphScale;
  const virtual = computeVirtualGrid(session.screens, cell);
  const slice = virtual.slices[session.currentScreenId];
  if (!slice) return null;
  return {
    seed: session.seed,
    epoch: session.epoch,
    warmupSeconds: session.warmupSeconds,
    cell,
    vCols: virtual.vCols,
    vRows: virtual.vRows,
    perDisplayMessages: controls.vignette > 0,
    screenId: session.currentScreenId,
    screens: session.screens,
    showControls: session.currentScreenId === (session.controlsScreenId ?? centermostScreenId(session.screens)),
    slice,
  };
}

export function installNativeLifecycle(setActive: (active: boolean) => void): void {
  if (!isNativeHosted()) return;
  window.__matrixCodeSetActive = setActive;
  if (pendingActive !== null) {
    setActive(pendingActive);
    pendingActive = null;
  }
}
