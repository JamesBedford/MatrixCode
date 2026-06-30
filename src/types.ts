// Shared types and the LOCKED state-texture channel layout.
//
// The CPU simulation packs each grid cell into 4 bytes (RGBA8):
//   R = newGlyphIndex   (0..MAX_GLYPHS)
//   G = brightness      (0..255  -> 0..1 base trail brightness; HDR head boost is applied in the shader)
//   B = flags + crossfadePhase:  bit7 = isHead, bit6 = whiteHead, bits0..5 = phase (0..63 -> 0..1)
//   A = oldGlyphIndex   (0..MAX_GLYPHS)  — the glyph being crossfaded FROM during a mutation
//
// The glyph shader samples the atlas twice (old + new) and mixes by phase for the authentic
// two-glyph crossfade. Glyph count is capped at 255 so an index fits in one byte.

export const MAX_GLYPHS = 255;
export const FLAG_IS_HEAD = 0x80; // bit 7
export const FLAG_WHITE_HEAD = 0x40; // bit 6
export const PHASE_MASK = 0x3f; // bits 0..5 (0..63)

export type PresetName =
  | "classic"
  | "amber"
  | "gold"
  | "red"
  | "pink"
  | "purple"
  | "blue"
  | "white";
export type QualityTier = "low" | "med" | "high";

/** Live, user-facing tunables bound to the controls panel + localStorage. */
export interface Controls {
  /** Global fall-speed multiplier. */
  speed: number;
  /** Brightness decay per second — lower = longer trail (0.01 long … 0.5 short). */
  trailLength: number;
  /** Stream spawn density multiplier. */
  density: number;
  /** Glyph size multiplier — scales the grid cell size (bigger = larger glyphs, fewer columns). */
  glyphScale: number;
  /** Bloom strength. */
  glow: number;
  /** Extra HDR push for white-hot leading glyphs (how hard they bloom). */
  leadBrightness: number;
  /** Color theme. */
  preset: PresetName;
  /** Bake horizontal mirror into the glyph atlas (the authentic look). */
  mirror: boolean;
  /** Faint CRT scanlines overlay. */
  scanlines: boolean;
  /** Subtle edge vignette. */
  vignette: boolean;
  /** Render quality tier (bloom levels / DPR budget). */
  quality: QualityTier;
}

/** User-editable in-rain messages and their scheduling, persisted to localStorage. */
export interface MessagesDoc {
  /** Pool of short messages; one is shown at a time, chosen at random. */
  messages: string[];
  /** Master on/off for in-rain messages. */
  enabled: boolean;
  /** Average gap between messages in ms (jittered ±25%). */
  frequencyMs: number;
  /** How long the message holds at full brightness, in ms (the fades are added on top of this). */
  persistenceMs: number;
  /** How long the message fades in, in ms (0 = instant); added before the hold. */
  appearMs: number;
  /** How long the message fades out, in ms (0 = instant); added after the hold. */
  disappearMs: number;
  /** Flicker the letters between random and the message over the appear/disappear times (resolve in, dissolve out). */
  flickerOut: boolean;
  /** Fade the message in/out via brightness (transparency) over the appear/disappear times. */
  brightnessFade: boolean;
}

/** Empirical tuning constants for the rain simulation (not user-facing). */
export interface SimConfig {
  /** Desired glyph cell size in CSS px — drives grid resolution. */
  targetCellPx: number;
  /** Minimum per-column fall speed in rows/second (before the speed control). */
  minSpeed: number;
  /** Random additional fall speed in rows/second. */
  speedRange: number;
  /** Brightness multiplier applied per second (exponential trail decay). */
  decayPerSecond: number;
  /** Multiplier on trail length at any given trail-length control setting (>1 = longer trails). */
  trailLengthScale: number;
  /** Per-second probability that a lit trail cell mutates its glyph. */
  mutationRate: number;
  /** Seconds for an old->new glyph crossfade. */
  crossfadeDuration: number;
  /** Fraction of streams whose head is white-hot (~1 in 5). */
  whiteHeadFraction: number;
  /** Per-second base probability an idle column respawns a stream. */
  respawnChance: number;
  /** Minimum idle delay before a column may respawn (seconds). */
  respawnDelayMin: number;
  /** Extra random idle delay (seconds). */
  respawnDelayJitter: number;
  /** Max rows above the top edge a new head can start (creates entry gaps). */
  startRowsAbove: number;
  /** Extra rows below the bottom edge before a stream is retired. */
  tailMargin: number;
  /** 0..1 amount of global synchronization applied to mutation timing. */
  globalSyncAmount: number;
  /** Frequency (Hz) of the global mutation-sync oscillator. */
  globalSyncHz: number;
  /** 0..1 minimum display brightness a revealed in-rain message cell holds while its message is active. */
  messageBrightFloor: number;
}

/** A color theme: RGB triplets in 0..1 (sRGB-ish, tone-mapped at composite). */
export interface ColorPreset {
  name: PresetName;
  background: readonly [number, number, number];
  tail: readonly [number, number, number];
  body: readonly [number, number, number];
  bright: readonly [number, number, number];
  head: readonly [number, number, number];
}

/** Grid dimensions in cells. */
export interface Grid {
  cols: number;
  rows: number;
}

/** What the renderer needs to draw a frame, derived from live controls + preset. */
export interface RenderParams {
  glow: number;
  leadBrightness: number;
  scanlines: boolean;
  vignette: boolean;
  quality: QualityTier;
  preset: ColorPreset;
}
