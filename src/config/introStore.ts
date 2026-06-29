import type { MessageLine, TypeConfig } from "../sim/messageOverlay.ts";
import {
  DEFAULT_LINES,
  DEFAULT_TYPE_CONFIG,
  DEFAULT_HOLD_MS,
  DEFAULT_PAUSE_MS,
} from "../sim/messageOverlay.ts";
import { clamp } from "../util/math.ts";

/** User-editable intro: the lines, the global timing settings, and the rain-start choreography. */
export interface IntroScript {
  lines: MessageLine[];
  charMs: number;
  startDelayMs: number;
  fadeOutMs: number;
  rainDuringIntro: boolean; // true = rain falls during the intro; false = waits until after
  postIntroDelayMs: number; // after-mode only: gap between intro end and rain start
  rampUpMs: number;         // linear density ramp 0→full once the rain starts (0 = instant)
}

const STORAGE_KEY = "mx-intro";
const MAX_LINES = 12;
const MAX_TEXT_LEN = 120;

export const DEFAULT_INTRO: IntroScript = {
  lines: DEFAULT_LINES.map((l) => ({ ...l })),
  charMs: DEFAULT_TYPE_CONFIG.charMs,
  startDelayMs: DEFAULT_TYPE_CONFIG.startDelayMs,
  fadeOutMs: DEFAULT_TYPE_CONFIG.fadeOutMs,
  rainDuringIntro: true,
  postIntroDelayMs: 0,
  rampUpMs: 0,
};

/** Deep copy so callers can mutate a working draft without touching shared state. */
export function cloneIntro(s: IntroScript): IntroScript {
  return { ...s, lines: s.lines.map((l) => ({ ...l })) };
}

function num(v: unknown, min: number, max: number, fallback: number): number {
  return typeof v === "number" && Number.isFinite(v) ? clamp(v, min, max) : fallback;
}

function sanitizeLine(raw: unknown): MessageLine | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.text !== "string") return null;
  return {
    text: r.text.slice(0, MAX_TEXT_LEN),
    holdMs: num(r.holdMs, 0, 20000, DEFAULT_HOLD_MS),
    pauseMs: num(r.pauseMs, 0, 20000, DEFAULT_PAUSE_MS),
  };
}

/** Coerce arbitrary parsed JSON into a valid IntroScript, falling back to defaults. */
export function sanitizeIntro(raw: unknown): IntroScript {
  const r = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  const rawLines = Array.isArray(r.lines) ? r.lines : [];
  const lines = rawLines
    .slice(0, MAX_LINES)
    .map(sanitizeLine)
    .filter((l): l is MessageLine => l !== null);
  return {
    lines: lines.length > 0 ? lines : DEFAULT_INTRO.lines.map((l) => ({ ...l })),
    charMs: num(r.charMs, 10, 500, DEFAULT_INTRO.charMs),
    startDelayMs: num(r.startDelayMs, 0, 10000, DEFAULT_INTRO.startDelayMs),
    fadeOutMs: num(r.fadeOutMs, 0, 10000, DEFAULT_INTRO.fadeOutMs),
    rainDuringIntro: typeof r.rainDuringIntro === "boolean" ? r.rainDuringIntro : DEFAULT_INTRO.rainDuringIntro,
    postIntroDelayMs: num(r.postIntroDelayMs, 0, 10000, DEFAULT_INTRO.postIntroDelayMs),
    rampUpMs: num(r.rampUpMs, 0, 60000, DEFAULT_INTRO.rampUpMs),
  };
}

/** Build the overlay's TypeConfig from a stored script (blink period is not user-facing). */
export function toTypeConfig(s: IntroScript): TypeConfig {
  return {
    charMs: s.charMs,
    startDelayMs: s.startDelayMs,
    fadeOutMs: s.fadeOutMs,
    blinkMs: DEFAULT_TYPE_CONFIG.blinkMs,
  };
}

/** localStorage-backed store for the user's custom intro script. */
export class IntroStore {
  private script: IntroScript;

  constructor() {
    this.script = this.load();
  }

  private load(): IntroScript {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return cloneIntro(DEFAULT_INTRO);
      return sanitizeIntro(JSON.parse(raw) as unknown);
    } catch {
      return cloneIntro(DEFAULT_INTRO);
    }
  }

  get(): IntroScript {
    return cloneIntro(this.script);
  }

  set(script: IntroScript): void {
    this.script = sanitizeIntro(script);
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(this.script));
    } catch {
      /* storage may be unavailable (private mode) — ignore */
    }
  }

  reset(): IntroScript {
    this.script = cloneIntro(DEFAULT_INTRO);
    try {
      localStorage.removeItem(STORAGE_KEY);
    } catch {
      /* ignore */
    }
    return this.get();
  }
}
