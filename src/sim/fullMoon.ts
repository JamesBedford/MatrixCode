import { nextFullMoonMs } from "./holidays.ts";

/** Cache only the current civil day so render frames do not repeat lunar calculations. */
export class FullMoonDayCache {
  private startMs = Number.NaN;
  private endMs = Number.NaN;
  private fullMoonDay = false;
  private readonly nextPhase: (nowMs: number) => number;

  constructor(nextPhase: (nowMs: number) => number = nextFullMoonMs) {
    this.nextPhase = nextPhase;
  }

  containsFullMoon(startMs: number, endMs: number): boolean {
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs) return false;
    if (startMs === this.startMs && endMs === this.endMs) return this.fullMoonDay;
    // The countdown lookup is strictly after its input; include a phase at midnight.
    const phaseMs = this.nextPhase(startMs - 1);
    this.startMs = startMs;
    this.endMs = endMs;
    this.fullMoonDay = phaseMs >= startMs && phaseMs < endMs;
    return this.fullMoonDay;
  }
}

const localDayCache = new FullMoonDayCache();

/** The whole local Gregorian date containing the full moon, not the following lunar cycle. */
export function isFullMoonLocalDate(localDate: Date, cache = localDayCache): boolean {
  const start = new Date(localDate.getTime());
  start.setHours(0, 0, 0, 0);
  const end = new Date(start.getTime());
  // Calendar arithmetic keeps DST-shortened/lengthened days and timezone changes correct.
  end.setDate(end.getDate() + 1);
  // Some zones skip midnight; their first valid hour must not carry into tomorrow.
  end.setHours(0, 0, 0, 0);
  return cache.containsFullMoon(start.getTime(), end.getTime());
}
