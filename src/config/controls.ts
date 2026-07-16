import type { Controls, GlyphMode, QualityTier } from "../types.ts";
import { clamp } from "../util/math.ts";
import { PRESET_NAMES } from "./colorPresets.ts";
import { GLYPH_FONTS } from "./glyphFonts.ts";
import { nativeStorageDidChange } from "../platform/nativeHost.ts";

export const DEFAULT_CONTROLS: Controls = {
  speed: 1,
  trailLength: 0.255,
  trailVariation: 1,
  density: 2,
  rampUpMs: 8000,
  glyphRate: 1,
  glyphScale: 1,
  glyphMode: "matrix",
  glyphFont: "matrix",
  glow: 0.9,
  leadBrightness: 1.6,
  preset: "classic",
  mirror: true,
  scanlines: false,
  vignette: 0,
  allowOverlap: true,
  quality: "high",
};

/** Shared bounds and slider increments for every numeric control. */
export const CONTROL_RANGES = {
  speed: { min: 0.1, max: 3, step: 0.05 },
  trailLength: { min: 0.01, max: 0.5, step: 0.01 },
  trailVariation: { min: 0, max: 1, step: 0.01 },
  density: { min: 0.1, max: 100, step: 0.05 },
  rampUpMs: { min: 0, max: 60000, step: 500 },
  glyphRate: { min: 0, max: 5, step: 0.05 },
  glyphScale: { min: 0.5, max: 10, step: 0.1 },
  glow: { min: 0, max: 2.5, step: 0.05 },
  leadBrightness: { min: 0, max: 3, step: 0.05 },
  vignette: { min: 0, max: 1, step: 0.01 },
} as const;

const STORAGE_KEY = "mx-controls";
const QUALITIES: QualityTier[] = ["low", "med", "high"];
const GLYPH_MODES: GlyphMode[] = ["matrix", "katakana", "binary", "digits", "latin", "symbols"];

/** Maps each control to its URL query-param name — single source of truth for reading and writing. */
const URL_PARAMS = {
  speed: "speed",
  trailLength: "trail",
  trailVariation: "trailvar",
  density: "density",
  rampUpMs: "ramp",
  glyphRate: "glyphrate",
  glyphScale: "size",
  glyphMode: "glyphs",
  glyphFont: "font",
  glow: "glow",
  leadBrightness: "lead",
  preset: "preset",
  mirror: "mirror",
  scanlines: "scanlines",
  vignette: "vignette",
  allowOverlap: "overlap",
  quality: "quality",
} as const satisfies Record<keyof Controls, string>;

export type ChangedKeys = ReadonlySet<keyof Controls>;
type Listener = (state: Controls, changed: ChangedKeys) => void;

// A real number (rejects NaN/Infinity, which a malformed URL param like
// `?speed=foo` would otherwise smuggle in — clamp() passes NaN straight through).
function finiteNum(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}

function legacyVignette(v: unknown): number | undefined {
  if (finiteNum(v)) return clamp(v, CONTROL_RANGES.vignette.min, CONTROL_RANGES.vignette.max);
  if (typeof v === "boolean") return v ? 0.42 : 0;
  return undefined;
}

export function sanitizeControls(raw: unknown): Partial<Controls> {
  const input = (typeof raw === "object" && raw !== null ? raw : {}) as Partial<Controls>;
  const out: Partial<Controls> = {};
  if (finiteNum(input.speed)) out.speed = clamp(input.speed, CONTROL_RANGES.speed.min, CONTROL_RANGES.speed.max);
  if (finiteNum(input.trailLength)) out.trailLength = clamp(input.trailLength, CONTROL_RANGES.trailLength.min, CONTROL_RANGES.trailLength.max);
  if (finiteNum(input.trailVariation)) out.trailVariation = clamp(input.trailVariation, CONTROL_RANGES.trailVariation.min, CONTROL_RANGES.trailVariation.max);
  if (finiteNum(input.density)) out.density = clamp(input.density, CONTROL_RANGES.density.min, CONTROL_RANGES.density.max);
  if (finiteNum(input.rampUpMs)) out.rampUpMs = clamp(input.rampUpMs, CONTROL_RANGES.rampUpMs.min, CONTROL_RANGES.rampUpMs.max);
  if (finiteNum(input.glyphRate)) out.glyphRate = clamp(input.glyphRate, CONTROL_RANGES.glyphRate.min, CONTROL_RANGES.glyphRate.max);
  if (finiteNum(input.glyphScale)) out.glyphScale = clamp(input.glyphScale, CONTROL_RANGES.glyphScale.min, CONTROL_RANGES.glyphScale.max);
  if (input.glyphMode && GLYPH_MODES.includes(input.glyphMode)) out.glyphMode = input.glyphMode;
  if (input.glyphFont && GLYPH_FONTS.includes(input.glyphFont)) out.glyphFont = input.glyphFont;
  if (finiteNum(input.glow)) out.glow = clamp(input.glow, CONTROL_RANGES.glow.min, CONTROL_RANGES.glow.max);
  if (finiteNum(input.leadBrightness)) out.leadBrightness = clamp(input.leadBrightness, CONTROL_RANGES.leadBrightness.min, CONTROL_RANGES.leadBrightness.max);
  if (input.preset && PRESET_NAMES.includes(input.preset)) out.preset = input.preset;
  if (typeof input.mirror === "boolean") out.mirror = input.mirror;
  if (typeof input.scanlines === "boolean") out.scanlines = input.scanlines;
  const vignette = legacyVignette(input.vignette);
  if (vignette !== undefined) out.vignette = vignette;
  if (typeof input.allowOverlap === "boolean") out.allowOverlap = input.allowOverlap;
  if (input.quality && QUALITIES.includes(input.quality)) out.quality = input.quality;
  return out;
}

function loadStored(): Partial<Controls> {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    return sanitizeControls(JSON.parse(raw) as unknown);
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
      raw[key] = key === "vignette" && (v === "true" || v === "false") ? (v === "true" ? 0.42 : 0) : Number(v);
    } else if (typeof def === "boolean") {
      const b = parseBool(v);
      if (b !== undefined) raw[key] = b;
    } else {
      raw[key] = v;
    }
  }
  return sanitizeControls(raw);
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
        p.set(param, String(value));
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
    const clean = sanitizeControls(partial);
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
      const value = JSON.stringify(this.state);
      localStorage.setItem(STORAGE_KEY, value);
      nativeStorageDidChange(STORAGE_KEY, value);
    } catch {
      /* storage may be unavailable (private mode) — ignore */
    }
  }
}
