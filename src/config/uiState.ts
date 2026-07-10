export type ActiveSettingsSurface = "characters" | "intro" | "messages" | "countdown";

export interface UiState {
  activeSettingsSurface: ActiveSettingsSurface | null;
}

const STORAGE_KEY = "mx-ui-state";
const SURFACES: ActiveSettingsSurface[] = ["characters", "intro", "messages", "countdown"];
const DEFAULT_UI_STATE: UiState = { activeSettingsSurface: null };

function storage(): Storage | null {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

export function sanitizeUiState(input: unknown): UiState {
  if (typeof input !== "object" || input === null) return { ...DEFAULT_UI_STATE };
  const surface = (input as Record<string, unknown>).activeSettingsSurface;
  return {
    activeSettingsSurface: typeof surface === "string" && SURFACES.includes(surface as ActiveSettingsSurface)
      ? surface as ActiveSettingsSurface
      : null,
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
    if (clean.activeSettingsSurface === null) {
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
  saveUiState({ activeSettingsSurface: surface }, store);
}
