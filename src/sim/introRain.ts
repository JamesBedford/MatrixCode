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
