import type { CountdownDoc, CountdownMoment } from "../types.ts";
import { text, capArray } from "./sanitize.ts";
import { clamp } from "../util/math.ts";

const STORAGE_KEY = "mx-countdown";
// Largest instant a JS Date can represent (±8.64e15 ms); guards against absurd stored values.
const MAX_TIME_MS = 8.64e15;
const MAX_MOMENTS = 12;
const MAX_NAME_LEN = 40;

export const DEFAULT_COUNTDOWN: CountdownDoc = { targetMs: null, moments: [] };

/** Deep copy so callers can mutate a working draft without touching shared state. */
export function cloneCountdown(d: CountdownDoc): CountdownDoc {
  return { targetMs: d.targetMs, moments: d.moments.map((m) => ({ ...m })) };
}

/** A finite epoch-ms clamped to a representable Date, or null for anything else. */
function sanitizeTarget(raw: unknown): number | null {
  return typeof raw === "number" && Number.isFinite(raw) ? clamp(raw, 0, MAX_TIME_MS) : null;
}

/** Trim a name and strip the characters that would break token parsing. */
function sanitizeName(raw: unknown): string {
  return text(raw, MAX_NAME_LEN).replace(/[:{}]/g, "").trim();
}

/** Coerce a moments array: drop empty names, de-dupe (first wins), clamp targets, cap length. */
function sanitizeMoments(raw: unknown): CountdownMoment[] {
  const seen = new Set<string>();
  const out: CountdownMoment[] = [];
  for (const item of capArray(raw, MAX_MOMENTS)) {
    const r = (typeof item === "object" && item !== null ? item : {}) as Record<string, unknown>;
    const name = sanitizeName(r.name);
    if (!name || seen.has(name)) continue;
    seen.add(name);
    out.push({ name, targetMs: sanitizeTarget(r.targetMs) });
  }
  return out;
}

/** Coerce arbitrary parsed JSON into a valid CountdownDoc. */
export function sanitizeCountdown(raw: unknown): CountdownDoc {
  const r = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  return { targetMs: sanitizeTarget(r.targetMs), moments: sanitizeMoments(r.moments) };
}

/** localStorage-backed store for the user's {countdown}/{countup} targets. */
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
