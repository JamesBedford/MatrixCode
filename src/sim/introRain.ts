import { clamp } from "../util/math.ts";

/**
 * Density multiplier (0..1) for the rain at `nowMs`, given when it starts
 * (`rainStartAtMs`) and how long it linearly ramps up (`rampUpMs`).
 * Returns 0 before the start, 1 once the ramp completes (or immediately when
 * `rampUpMs <= 0`). A `rainStartAtMs` of -Infinity means "already running".
 */
export function densityRampFactor(nowMs: number, rainStartAtMs: number, rampUpMs: number): number {
  if (nowMs < rainStartAtMs) return 0;
  if (rampUpMs <= 0) return 1;
  return clamp((nowMs - rainStartAtMs) / rampUpMs, 0, 1);
}

/**
 * Ramp duration (ms) to apply when the rain starts on a normal page load, or 0 to keep the
 * pre-warmed full-density start. A first visit (intro not yet seen) returns 0 — the intro path
 * owns its ramp; reduced motion returns 0 — the static frame doesn't animate.
 */
export function loadRampMs(introSeen: boolean, rampUpMs: number, reducedMotion: boolean): number {
  if (!introSeen || reducedMotion || rampUpMs <= 0) return 0;
  return rampUpMs;
}

/**
 * Shape a 0..1 ramp progress with soft ends but a linear middle: the rate eases up over the first
 * `edge` fraction, holds constant through the middle, then eases down over the last `edge` (a
 * trapezoidal velocity profile — continuous in value and slope). `edge` 0 → linear, 0.5 → pure
 * ease-in-out with no linear stretch. Symmetric: rampEase(p) + rampEase(1 - p) === 1.
 */
export function rampEase(p: number, edge = 0.2): number {
  if (p <= 0) return 0;
  if (p >= 1) return 1;
  const e = clamp(edge, 0, 0.5);
  if (e <= 0) return p;
  const v = 1 / (1 - e); // peak rate chosen so the area (total rise) is exactly 1
  if (p < e) return (v * p * p) / (2 * e);
  if (p > 1 - e) return 1 - (v * (1 - p) * (1 - p)) / (2 * e);
  return (v * e) / 2 + v * (p - e);
}
