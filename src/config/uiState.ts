import { nativeStorageDidChange } from "../platform/nativeHost.ts";

export type ActiveSettingsSurface = "characters" | "intro" | "messages" | "countdown";

export interface UiState {
  activeSettingsSurface: ActiveSettingsSurface | null;
  fpsOverlayVisible: boolean;
}

const STORAGE_KEY = "mx-ui-state";
const SURFACES: ActiveSettingsSurface[] = ["characters", "intro", "messages", "countdown"];
const DEFAULT_UI_STATE: UiState = { activeSettingsSurface: null, fpsOverlayVisible: false };

function storage(): Storage | null {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

function persistentStorage(): Storage | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

export function sanitizeUiState(input: unknown): UiState {
  if (typeof input !== "object" || input === null) return { ...DEFAULT_UI_STATE };
  const surface = (input as Record<string, unknown>).activeSettingsSurface;
  const fpsOverlayVisible = (input as Record<string, unknown>).fpsOverlayVisible;
  return {
    activeSettingsSurface: typeof surface === "string" && SURFACES.includes(surface as ActiveSettingsSurface)
      ? surface as ActiveSettingsSurface
      : null,
    fpsOverlayVisible: typeof fpsOverlayVisible === "boolean" ? fpsOverlayVisible : false,
  };
}

export function loadUiState(store: Storage | null = storage()): UiState {
  if (!store) return { ...DEFAULT_UI_STATE };
  try {
    const raw = store.getItem(STORAGE_KEY);
    return raw ? sanitizeUiState(JSON.parse(raw)) : { ...DEFAULT_UI_STATE };
  } catch {
    return { ...DEFAULT_UI_STATE };
  }
}

export function saveUiState(state: UiState, store: Storage | null = storage()): void {
  if (!store) return;
  try {
    const clean = sanitizeUiState(state);
    if (clean.activeSettingsSurface === null && !clean.fpsOverlayVisible) {
      store.removeItem(STORAGE_KEY);
    } else {
      store.setItem(STORAGE_KEY, JSON.stringify(clean));
    }
  } catch {
    /* storage may be unavailable */
  }
}

export function setActiveSettingsSurface(
  surface: ActiveSettingsSurface | null,
  store: Storage | null = storage(),
): void {
  saveUiState({ ...loadUiState(store), activeSettingsSurface: surface }, store);
}

export function loadFpsOverlayVisible(store: Storage | null = persistentStorage()): boolean {
  return loadUiState(store).fpsOverlayVisible;
}

export function setFpsOverlayVisible(
  visible: boolean,
  store: Storage | null = persistentStorage(),
): void {
  if (!store) return;
  saveUiState({ ...loadUiState(store), fpsOverlayVisible: visible }, store);
  try {
    nativeStorageDidChange(STORAGE_KEY, store.getItem(STORAGE_KEY));
  } catch {
    /* native bridge may be unavailable */
  }
}
