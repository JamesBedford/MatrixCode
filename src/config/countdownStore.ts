import type { CountdownDoc } from "../types.ts";
import { clamp } from "../util/math.ts";

const STORAGE_KEY = "mx-countdown";
// Largest instant a JS Date can represent (±8.64e15 ms); guards against absurd stored values.
const MAX_TIME_MS = 8.64e15;

export const DEFAULT_COUNTDOWN: CountdownDoc = { targetMs: null };

/** Deep copy so callers can mutate a working draft without touching shared state. */
export function cloneCountdown(d: CountdownDoc): CountdownDoc {
  return { targetMs: d.targetMs };
}

/** Coerce arbitrary parsed JSON into a valid CountdownDoc; anything but a finite number ⇒ null. */
export function sanitizeCountdown(raw: unknown): CountdownDoc {
  const r = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  const t = r.targetMs;
  const targetMs = typeof t === "number" && Number.isFinite(t) ? clamp(t, 0, MAX_TIME_MS) : null;
  return { targetMs };
}

/** localStorage-backed store for the user's `{countdown}` target. */
export class CountdownStore {
  private doc: CountdownDoc;

  constructor() {
    this.doc = this.load();
  }

  private load(): CountdownDoc {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return cloneCountdown(DEFAULT_COUNTDOWN);
      return sanitizeCountdown(JSON.parse(raw) as unknown);
    } catch {
      return cloneCountdown(DEFAULT_COUNTDOWN);
    }
  }

  get(): CountdownDoc {
    return cloneCountdown(this.doc);
  }

  set(doc: CountdownDoc): void {
    this.doc = sanitizeCountdown(doc);
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(this.doc));
    } catch {
      /* storage may be unavailable (private mode) — ignore */
    }
  }

  reset(): CountdownDoc {
    this.doc = cloneCountdown(DEFAULT_COUNTDOWN);
    try {
      localStorage.removeItem(STORAGE_KEY);
    } catch {
      /* ignore */
    }
    return this.get();
  }
}
