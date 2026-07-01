// The "Wake up, Neo…" intro — readable typed terminal text rendered over the
// rain. The TYPING TIMELINE is a pure function (unit-tested); the DOM renderer
// is a thin wrapper that drives a <pre> element from it.

import { DEFAULT_USER_NAME, NAME_TOKEN } from "./tokens.ts";

// Re-exported so existing importers of the name constants keep a single import site.
export { DEFAULT_USER_NAME, NAME_TOKEN };

export interface MessageLine {
  text: string;
  /** Milliseconds to hold the fully-typed line before clearing. */
  holdMs: number;
  /** Blank gap (cursor only) before the next line types; ignored on the last line. */
  pauseMs: number;
}

export interface TypeConfig {
  /** Milliseconds per typed character. */
  charMs: number;
  /** Blank lead-in before the first line. */
  startDelayMs: number;
  /** Fade-out duration after the final line's hold. */
  fadeOutMs: number;
  /** Cursor blink period. */
  blinkMs: number;
}

export interface TimelineState {
  /** Index of the line currently shown; equals lines.length when finished. */
  lineIndex: number;
  /** The currently-visible (possibly partial) text. */
  visibleText: string;
  /** Overall opacity 0..1. */
  opacity: number;
  /** Whether the whole sequence has completed. */
  done: boolean;
}

/** Default per-line timings. pauseMs is 0 so the default intro's lines run back-to-back. */
export const DEFAULT_HOLD_MS = 2800;
export const DEFAULT_PAUSE_MS = 0;

/** Default intro lines, carrying {name} tokens for runtime substitution. */
export const DEFAULT_LINES: MessageLine[] = [
  { text: `Wake up, ${NAME_TOKEN}...`, holdMs: DEFAULT_HOLD_MS, pauseMs: DEFAULT_PAUSE_MS },
  { text: "The Matrix has you...", holdMs: DEFAULT_HOLD_MS, pauseMs: DEFAULT_PAUSE_MS },
  { text: "Follow the white rabbit.", holdMs: DEFAULT_HOLD_MS, pauseMs: DEFAULT_PAUSE_MS },
  { text: `Knock, knock, ${NAME_TOKEN}.`, holdMs: DEFAULT_HOLD_MS, pauseMs: DEFAULT_PAUSE_MS },
];

/**
 * Resolve the viewer's name from the runtime environment, falling back to
 * DEFAULT_USER_NAME ("Neo") when it can't be determined. Sources, in order:
 *   1. `?name=` URL query parameter
 *   2. `mx-user-name` in localStorage
 */
export function resolveUserName(): string {
  try {
    const fromQuery = new URLSearchParams(window.location.search).get("name");
    if (fromQuery && fromQuery.trim()) return fromQuery.trim();

    const fromStore = window.localStorage.getItem("mx-user-name");
    if (fromStore && fromStore.trim()) return fromStore.trim();
  } catch {
    // Non-browser environment or storage blocked — fall through to default.
  }
  return DEFAULT_USER_NAME;
}

// Raw default script (tokens intact); tokens are resolved per-frame by the overlay's resolveText.
export const DEFAULT_SCRIPT: MessageLine[] = DEFAULT_LINES;

export const DEFAULT_TYPE_CONFIG: TypeConfig = {
  charMs: 95,
  startDelayMs: 600,
  fadeOutMs: 900,
  blinkMs: 450,
};

/** Pure: given elapsed ms since start, compute what to show. */
export function computeTimeline(lines: MessageLine[], cfg: TypeConfig, elapsedMs: number): TimelineState {
  if (lines.length === 0) return { lineIndex: 0, visibleText: "", opacity: 0, done: true };

  let t = elapsedMs - cfg.startDelayMs;
  if (t < 0) return { lineIndex: 0, visibleText: "", opacity: 1, done: false };

  const lastIdx = lines.length - 1;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    const typeDur = line.text.length * cfg.charMs;
    if (t < typeDur) {
      const chars = Math.floor(t / cfg.charMs);
      return { lineIndex: i, visibleText: line.text.slice(0, chars), opacity: 1, done: false };
    }
    t -= typeDur;
    if (t < line.holdMs) {
      return { lineIndex: i, visibleText: line.text, opacity: 1, done: false };
    }
    t -= line.holdMs;
    // Blank pause before the next line (none after the last line).
    if (i < lastIdx) {
      if (t < line.pauseMs) {
        return { lineIndex: i, visibleText: "", opacity: 1, done: false };
      }
      t -= line.pauseMs;
    }
  }

  const lastText = lines[lastIdx]!.text;
  if (t < cfg.fadeOutMs) {
    return { lineIndex: lastIdx, visibleText: lastText, opacity: 1 - t / cfg.fadeOutMs, done: false };
  }
  return { lineIndex: lines.length, visibleText: "", opacity: 0, done: true };
}

/** Pure: cursor visible at this elapsed time (blink). */
export function cursorVisible(cfg: TypeConfig, elapsedMs: number): boolean {
  return Math.floor(elapsedMs / cfg.blinkMs) % 2 === 0;
}

/** Total runtime of the sequence in ms (useful for tests / scheduling). */
export function totalDuration(lines: MessageLine[], cfg: TypeConfig): number {
  let total = cfg.startDelayMs + cfg.fadeOutMs;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    total += line.text.length * cfg.charMs + line.holdMs;
    if (i < lines.length - 1) total += line.pauseMs;
  }
  return total;
}

export interface MessageOverlayOptions {
  lines?: MessageLine[];
  config?: TypeConfig;
  /** Resolve dynamic tokens ({name}/{time}/{countdown}) in each line, called per frame. */
  resolveText?: (text: string) => string;
}

/** DOM renderer for the typed intro. Driven by the app loop via update(nowMs). */
export class MessageOverlay {
  readonly el: HTMLDivElement;
  private textEl: HTMLSpanElement;
  private cursorEl: HTMLSpanElement;
  private lines: MessageLine[];
  private cfg: TypeConfig;
  private resolveText: (text: string) => string;
  private startMs = 0;
  private playing = false;
  private onDoneCb: (() => void) | null = null;

  constructor(parent: HTMLElement, opts: MessageOverlayOptions = {}) {
    this.lines = opts.lines ?? DEFAULT_SCRIPT;
    this.cfg = opts.config ?? DEFAULT_TYPE_CONFIG;
    this.resolveText = opts.resolveText ?? ((t) => t);

    this.el = document.createElement("div");
    this.el.className = "mx-message";
    this.el.setAttribute("aria-hidden", "true");
    this.el.style.display = "none";

    const pre = document.createElement("pre");
    this.textEl = document.createElement("span");
    this.cursorEl = document.createElement("span");
    this.cursorEl.className = "mx-cursor";
    this.cursorEl.textContent = "█"; // full block
    pre.appendChild(this.textEl);
    pre.appendChild(this.cursorEl);
    this.el.appendChild(pre);
    parent.appendChild(this.el);
  }

  isPlaying(): boolean {
    return this.playing;
  }

  onDone(cb: () => void): void {
    this.onDoneCb = cb;
  }

  /** Replace the script and timing config (used by the live intro editor). */
  setScript(lines: MessageLine[], cfg: TypeConfig): void {
    this.lines = lines;
    this.cfg = cfg;
  }

  play(nowMs: number): void {
    this.startMs = nowMs;
    this.playing = true;
    this.el.style.display = "grid";
  }

  skip(): void {
    if (!this.playing) return;
    this.finish();
  }

  update(nowMs: number): void {
    if (!this.playing) return;
    const elapsed = nowMs - this.startMs;
    // Resolve dynamic tokens just-in-time so {time}/{countdown} tick as the line types and holds.
    // computeTimeline derives type-duration from the resolved length, so the typewriter types the
    // resolved value and re-slices live as it changes.
    const lines = this.lines.map((l) => ({ ...l, text: this.resolveText(l.text) }));
    const state = computeTimeline(lines, this.cfg, elapsed);
    if (state.done) {
      this.finish();
      return;
    }
    this.textEl.textContent = state.visibleText;
    this.el.style.opacity = String(state.opacity);
    this.cursorEl.style.visibility = cursorVisible(this.cfg, elapsed) ? "visible" : "hidden";
  }

  private finish(): void {
    this.playing = false;
    this.el.style.display = "none";
    this.onDoneCb?.();
  }

  destroy(): void {
    this.el.remove();
  }
}
