import type { MessagesDoc } from "../types.ts";
import { num, text, bool, capArray } from "./sanitize.ts";
import { nativeStorageDidChange } from "../platform/nativeHost.ts";

const STORAGE_KEY = "mx-messages";
const MAX_MESSAGES = 12;
const MAX_TEXT_LEN = 120;
const MIN_MS = 500;
const MAX_MS = 600000;

export const DEFAULT_MESSAGES: MessagesDoc = {
  messages: ["WAKE UP", "THE MATRIX HAS YOU", "FOLLOW THE WHITE RABBIT", "{countup}"],
  enabled: false,
  frequencyMs: 8000,
  persistenceMs: 10000,
  appearMs: 4000,
  disappearMs: 4000,
  flickerOut: true,
  brightnessFade: false,
  verticalPosition: 0.475,
  verticalJitter: 0.25,
};

/** Deep copy so callers can mutate a working draft without touching shared state. */
export function cloneMessages(d: MessagesDoc): MessagesDoc {
  return { ...d, messages: [...d.messages] };
}

/** Coerce arbitrary parsed JSON into a valid MessagesDoc. An empty list is allowed (user cleared it). */
export function sanitizeMessages(raw: unknown): MessagesDoc {
  const r = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  const messages = capArray(r.messages, MAX_MESSAGES)
    .map((m) => text(m, MAX_TEXT_LEN))
    .filter((s) => s.trim().length > 0);
  return {
    messages,
    enabled: bool(r.enabled, DEFAULT_MESSAGES.enabled),
    frequencyMs: num(r.frequencyMs, MIN_MS, MAX_MS, DEFAULT_MESSAGES.frequencyMs),
    persistenceMs: num(r.persistenceMs, MIN_MS, MAX_MS, DEFAULT_MESSAGES.persistenceMs),
    appearMs: num(r.appearMs, 0, MAX_MS, DEFAULT_MESSAGES.appearMs),
    disappearMs: num(r.disappearMs, 0, MAX_MS, DEFAULT_MESSAGES.disappearMs),
    flickerOut: bool(r.flickerOut, DEFAULT_MESSAGES.flickerOut),
    brightnessFade: bool(r.brightnessFade, DEFAULT_MESSAGES.brightnessFade),
    verticalPosition: num(r.verticalPosition, 0, 1, DEFAULT_MESSAGES.verticalPosition),
    verticalJitter: num(r.verticalJitter, 0, 1, DEFAULT_MESSAGES.verticalJitter),
  };
}

/** localStorage-backed store for the user's in-rain messages and their scheduling. */
export class MessagesStore {
  private doc: MessagesDoc;

  constructor() {
    this.doc = this.load();
  }

  private load(): MessagesDoc {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return cloneMessages(DEFAULT_MESSAGES);
      return sanitizeMessages(JSON.parse(raw) as unknown);
    } catch {
      return cloneMessages(DEFAULT_MESSAGES);
    }
  }

  get(): MessagesDoc {
    return cloneMessages(this.doc);
  }

  set(doc: MessagesDoc): void {
    this.doc = sanitizeMessages(doc);
    try {
      const value = JSON.stringify(this.doc);
      localStorage.setItem(STORAGE_KEY, value);
      nativeStorageDidChange(STORAGE_KEY, value);
    } catch {
      /* storage may be unavailable (private mode) — ignore */
    }
  }

  reset(): MessagesDoc {
    this.doc = cloneMessages(DEFAULT_MESSAGES);
    try {
      localStorage.removeItem(STORAGE_KEY);
      nativeStorageDidChange(STORAGE_KEY, null);
    } catch {
      /* ignore */
    }
    return this.get();
  }
}
