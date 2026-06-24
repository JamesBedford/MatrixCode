import type { Controls, PresetName, QualityTier } from "../types.ts";
import { clamp } from "../util/math.ts";

export const DEFAULT_CONTROLS: Controls = {
  speed: 1,
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
const PRESETS: PresetName[] = ["classic", "amber", "blue"];
const QUALITIES: QualityTier[] = ["low", "med", "high"];

export type ChangedKeys = ReadonlySet<keyof Controls>;
type Listener = (state: Controls, changed: ChangedKeys) => void;

function sanitize(input: Partial<Controls>): Partial<Controls> {
  const out: Partial<Controls> = {};
  if (typeof input.speed === "number") out.speed = clamp(input.speed, 0.1, 3);
  if (typeof input.density === "number") out.density = clamp(input.density, 0.1, 2);
  if (typeof input.glyphScale === "number") out.glyphScale = clamp(input.glyphScale, 0.5, 5);
  if (typeof input.glow === "number") out.glow = clamp(input.glow, 0, 2.5);
  if (typeof input.leadBrightness === "number") out.leadBrightness = clamp(input.leadBrightness, 0, 3);
  if (input.preset && PRESETS.includes(input.preset)) out.preset = input.preset;
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
  const raw: Partial<Controls> = {};
  const num = (k: string): number | undefined => {
    const v = p.get(k);
    return v === null ? undefined : Number(v);
  };
  if (num("speed") !== undefined) raw.speed = num("speed");
  if (num("density") !== undefined) raw.density = num("density");
  if (num("size") !== undefined) raw.glyphScale = num("size");
  if (num("glow") !== undefined) raw.glow = num("glow");
  if (num("lead") !== undefined) raw.leadBrightness = num("lead");
  const preset = p.get("preset");
  if (preset) raw.preset = preset as PresetName;
  const quality = p.get("quality");
  if (quality) raw.quality = quality as QualityTier;
  for (const key of ["mirror", "scanlines", "vignette"] as const) {
    const v = p.get(key);
    if (v !== null) {
      const b = parseBool(v);
      if (b !== undefined) raw[key] = b;
    }
  }
  return sanitize(raw);
}

/** Live tunables store: merges defaults + localStorage + URL, persists, notifies. */
export class ControlsStore {
  private state: Controls;
  private listeners = new Set<Listener>();

  constructor() {
    this.state = { ...DEFAULT_CONTROLS, ...loadStored(), ...loadUrl() };
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
