import type { Controls, QualityTier } from "../types.ts";
import { clamp } from "../util/math.ts";
import { PRESET_NAMES } from "./colorPresets.ts";

export const DEFAULT_CONTROLS: Controls = {
  speed: 1,
  trailLength: 0.08,
  density: 1,
  glyphScale: 1,
  glow: 0.9,
  leadBrightness: 1.6,
  preset: "classic",
  mirror: true,
  scanlines: false,
  vignette: false,
  quality: "high",
};

const STORAGE_KEY = "mx-controls";
const QUALITIES: QualityTier[] = ["low", "med", "high"];

/** Maps each control to its URL query-param name — single source of truth for reading and writing. */
const URL_PARAMS = {
  speed: "speed",
  trailLength: "trail",
  density: "density",
  glyphScale: "size",
  glow: "glow",
  leadBrightness: "lead",
  preset: "preset",
  mirror: "mirror",
  scanlines: "scanlines",
  vignette: "vignette",
  quality: "quality",
} as const satisfies Record<keyof Controls, string>;

export type ChangedKeys = ReadonlySet<keyof Controls>;
type Listener = (state: Controls, changed: ChangedKeys) => void;

// A real number (rejects NaN/Infinity, which a malformed URL param like
// `?speed=foo` would otherwise smuggle in — clamp() passes NaN straight through).
function finiteNum(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}

function sanitize(input: Partial<Controls>): Partial<Controls> {
  const out: Partial<Controls> = {};
  if (finiteNum(input.speed)) out.speed = clamp(input.speed, 0.1, 3);
  if (finiteNum(input.trailLength)) out.trailLength = clamp(input.trailLength, 0.01, 0.5);
  if (finiteNum(input.density)) out.density = clamp(input.density, 0.1, 100);
  if (finiteNum(input.glyphScale)) out.glyphScale = clamp(input.glyphScale, 0.5, 10);
  if (finiteNum(input.glow)) out.glow = clamp(input.glow, 0, 2.5);
  if (finiteNum(input.leadBrightness)) out.leadBrightness = clamp(input.leadBrightness, 0, 3);
  if (input.preset && PRESET_NAMES.includes(input.preset)) out.preset = input.preset;
  if (typeof input.mirror === "boolean") out.mirror = input.mirror;
  if (typeof input.scanlines === "boolean") out.scanlines = input.scanlines;
  if (typeof input.vignette === "boolean") out.vignette = input.vignette;
  if (input.quality && QUALITIES.includes(input.quality)) out.quality = input.quality;
  return out;
}

function loadStored(): Partial<Controls> {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    return sanitize(JSON.parse(raw) as Partial<Controls>);
  } catch {
    return {};
  }
}

function parseBool(v: string): boolean | undefined {
  if (v === "1" || v === "true") return true;
  if (v === "0" || v === "false") return false;
  return undefined;
}

function loadUrl(): Partial<Controls> {
  const p = new URLSearchParams(location.search);
  const raw: Record<string, unknown> = {};
  for (const key of Object.keys(URL_PARAMS) as (keyof Controls)[]) {
    const v = p.get(URL_PARAMS[key]);
    if (v === null) continue;
    const def = DEFAULT_CONTROLS[key];
    if (typeof def === "number") {
      raw[key] = Number(v);
    } else if (typeof def === "boolean") {
      const b = parseBool(v);
      if (b !== undefined) raw[key] = b;
    } else {
      raw[key] = v;
    }
  }
  return sanitize(raw as Partial<Controls>);
}

/** Write the current settings into the URL so a reload restores them. Defaults are omitted to keep it tidy. */
function syncUrl(state: Controls): void {
  try {
    const p = new URLSearchParams(location.search);
    for (const key of Object.keys(URL_PARAMS) as (keyof Controls)[]) {
      const param = URL_PARAMS[key];
      const value = state[key];
      if (value === DEFAULT_CONTROLS[key]) {
        p.delete(param);
      } else {
        p.set(param, typeof value === "boolean" ? (value ? "1" : "0") : String(value));
      }
    }
    const query = p.toString();
    history.replaceState(history.state, "", `${location.pathname}${query ? `?${query}` : ""}${location.hash}`);
  } catch {
    /* history/URL API unavailable — ignore */
  }
}

/** Live tunables store: merges defaults + localStorage + URL, persists, notifies. */
export class ControlsStore {
  private state: Controls;
  private listeners = new Set<Listener>();

  constructor() {
    this.state = { ...DEFAULT_CONTROLS, ...loadStored(), ...loadUrl() };
    syncUrl(this.state);
  }

  get(): Controls {
    return { ...this.state };
  }

  set(partial: Partial<Controls>): void {
    const clean = sanitize(partial);
    const changed = new Set<keyof Controls>();
    for (const key of Object.keys(clean) as (keyof Controls)[]) {
      if (this.state[key] !== clean[key]) {
        (this.state as unknown as Record<string, unknown>)[key] = clean[key];
        changed.add(key);
      }
    }
    if (changed.size === 0) return;
    this.persist();
    syncUrl(this.state);
    const snapshot = this.get();
    for (const cb of this.listeners) cb(snapshot, changed);
  }

  subscribe(cb: Listener): () => void {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  private persist(): void {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(this.state));
    } catch {
      /* storage may be unavailable (private mode) — ignore */
    }
  }
}
