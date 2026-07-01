import type { QualityTier } from "../types.ts";
import { clamp } from "../util/math.ts";

// Horizontal-overlap model. The renderer draws one base rain layer plus, when density is turned
// well up, additional independent rain layers offset to fractional column positions and composited
// additively — so raindrops overlap between the integer columns. This module is the single source of
// truth mapping the density control to that set of layers ("lanes"). It is pure (no DOM/GL) so it can
// be unit-tested, and it never touches RainSim, so the simulation's golden determinism is untouched.

/** Density at which every column is continuously full and overlap begins; below this, one drop per column. */
export const OVERLAP_ONSET_DENSITY = 20;
/** Highest density the control reaches (matches the sanitize/slider max). */
export const MAX_DENSITY = 100;
/** Maximum simultaneous lanes across a column's width (power of two so evenly-spaced subsets exist). */
export const MAX_LANES = 8;

/** One raindrop layer to simulate + render. */
export interface Lane {
  /** Pool index: 0 = the base layer (offset 0), 1.. = overlap layers. Also selects the layer's seed. */
  index: number;
  /** Horizontal offset in cells (van der Corput fraction); 0 for the base layer. */
  offset: number;
  /** Density value fed to this layer's sim. */
  density: number;
  /** 0..1 coverage weight scaling this layer's spawnRateScale, so a new lane fades in rather than popping. */
  weight: number;
}

/**
 * Radical inverse in base 2 (van der Corput): 0, .5, .25, .75, .125, .625, .375, .875, …
 * The first 2^k values are exactly the evenly-spaced k-bit fractions, so adding lanes in
 * power-of-two groups keeps every lane evenly spaced while never moving an existing one.
 */
export function vanDerCorput(i: number): number {
  let result = 0;
  let denom = 1;
  let n = Math.floor(i);
  while (n > 0) {
    denom *= 2;
    result += (n % 2) / denom;
    n = Math.floor(n / 2);
  }
  return result;
}

/** Per-quality cap on total simultaneous lanes (power of two so the kept subset stays evenly spaced). */
export function tierCap(quality: QualityTier): number {
  return quality === "low" ? 2 : quality === "med" ? 4 : MAX_LANES;
}

/**
 * Distinct, reproducible seed for each layer. Layer 0 returns `base` unchanged so the base layer's
 * simulation is bit-identical to the single-sim behaviour; other layers get well-separated seeds
 * (golden-ratio multiplier) so they look genuinely different rather than ghosted copies.
 */
export function seedForLayer(base: number, i: number): number {
  return (base ^ Math.imul(i, 0x9e3779b9)) >>> 0;
}

/**
 * Map the density control to the set of raindrop lanes to simulate + render.
 * - Overlap off, or density at/below the onset: a single base lane fed the raw density (today's behaviour).
 * - Above the onset: the base lane pins at the onset density (a continuously-full column) and extra lanes
 *   fade in at evenly-spaced fractional offsets — halves, then quarters, then eighths — up to `cap`.
 */
export function computeLanes(density: number, allowOverlap: boolean, cap: number): Lane[] {
  const base: Lane = { index: 0, offset: 0, density, weight: 1 };
  if (!allowOverlap || density <= OVERLAP_ONSET_DENSITY) return [base];

  // Past the onset the base column is full, so extra density spreads sideways instead of stacking:
  // pin the base at the onset and grow the lane count 1 → 2 → 4 → 8 across [onset, MAX_DENSITY].
  base.density = OVERLAP_ONSET_DENSITY;
  const maxLevel = Math.log2(MAX_LANES); // 3 subdivision doublings
  const level = clamp(
    (maxLevel * (density - OVERLAP_ONSET_DENSITY)) / (MAX_DENSITY - OVERLAP_ONSET_DENSITY),
    0,
    maxLevel,
  );
  const full = 2 ** Math.floor(level); // lanes fully on at this level: 1, 2, 4, 8
  const fade = level - Math.floor(level); // 0..1 fade-in of the next power-of-two group

  const lanes: Lane[] = [base];
  for (let i = 1; i < full; i++) {
    lanes.push({ index: i, offset: vanDerCorput(i), density: OVERLAP_ONSET_DENSITY, weight: 1 });
  }
  // Epsilon guard: at an exact power-of-two boundary floating-point can leave a tiny residual fade,
  // which would add a group of invisible near-zero-weight lanes — skip it so the lane count is clean.
  if (fade > 1e-6 && full < MAX_LANES) {
    for (let i = full; i < full * 2; i++) {
      lanes.push({ index: i, offset: vanDerCorput(i), density: OVERLAP_ONSET_DENSITY, weight: fade });
    }
  }
  return lanes.slice(0, cap);
}
