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
