import type { Controls, GlyphMode, QualityTier } from "../types.ts";
import { clamp } from "../util/math.ts";
import { PRESET_NAMES } from "./colorPresets.ts";
import { GLYPH_FONTS } from "./glyphFonts.ts";
import { nativeStorageDidChange } from "../platform/nativeHost.ts";

export const DEFAULT_CONTROLS: Controls = {
  speed: 1,
  trailLength: 0.255,
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

const STORAGE_KEY = "mx-controls";
const QUALITIES: QualityTier[] = ["low", "med", "high"];
const GLYPH_MODES: GlyphMode[] = ["matrix", "katakana", "binary", "digits", "latin", "symbols"];

/** Maps each control to its URL query-param name — single source of truth for reading and writing. */
const URL_PARAMS = {
  speed: "speed",
  trailLength: "trail",
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
  if (finiteNum(v)) return clamp(v, 0, 1);
  if (typeof v === "boolean") return v ? 0.42 : 0;
  return undefined;
}

function sanitize(input: Partial<Controls>): Partial<Controls> {
  const out: Partial<Controls> = {};
  if (finiteNum(input.speed)) out.speed = clamp(input.speed, 0.1, 3);
  if (finiteNum(input.trailLength)) out.trailLength = clamp(input.trailLength, 0.01, 0.5);
  if (finiteNum(input.density)) out.density = clamp(input.density, 0.1, 100);
  if (finiteNum(input.rampUpMs)) out.rampUpMs = clamp(input.rampUpMs, 0, 60000);
  if (finiteNum(input.glyphRate)) out.glyphRate = clamp(input.glyphRate, 0, 5);
  if (finiteNum(input.glyphScale)) out.glyphScale = clamp(input.glyphScale, 0.5, 10);
  if (input.glyphMode && GLYPH_MODES.includes(input.glyphMode)) out.glyphMode = input.glyphMode;
  if (input.glyphFont && GLYPH_FONTS.includes(input.glyphFont)) out.glyphFont = input.glyphFont;
  if (finiteNum(input.glow)) out.glow = clamp(input.glow, 0, 2.5);
  if (finiteNum(input.leadBrightness)) out.leadBrightness = clamp(input.leadBrightness, 0, 3);
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
      raw[key] = key === "vignette" && (v === "true" || v === "false") ? (v === "true" ? 0.42 : 0) : Number(v);
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
      const value = JSON.stringify(this.state);
      localStorage.setItem(STORAGE_KEY, value);
      nativeStorageDidChange(STORAGE_KEY, value);
    } catch {
      /* storage may be unavailable (private mode) — ignore */
    }
  }
}
