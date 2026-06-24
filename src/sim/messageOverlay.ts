// The "Wake up, Neo…" intro — readable typed terminal text rendered over the
// rain. The TYPING TIMELINE is a pure function (unit-tested); the DOM renderer
// is a thin wrapper that drives a <pre> element from it.

export interface MessageLine {
  text: string;
}

export interface TypeConfig {
  /** Milliseconds per typed character. */
  charMs: number;
  /** Milliseconds to hold a fully-typed line before clearing. */
  holdMs: number;
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

/** Name used when the user's own name can't be determined. */
export const DEFAULT_USER_NAME = "Neo";

/** Build the typed intro script, addressing the viewer by name. */
export function buildScript(name: string = DEFAULT_USER_NAME): MessageLine[] {
  const who = name.trim() || DEFAULT_USER_NAME;
  return [
    { text: `Wake up, ${who}...` },
    { text: "The Matrix has you..." },
    { text: "Follow the white rabbit." },
    { text: `Knock, knock, ${who}.` },
  ];
}

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

export const DEFAULT_SCRIPT: MessageLine[] = buildScript();

export const DEFAULT_TYPE_CONFIG: TypeConfig = {
  charMs: 95,
  holdMs: 2800,
  startDelayMs: 600,
  fadeOutMs: 900,
  blinkMs: 450,
};

/** Pure: given elapsed ms since start, compute what to show. */
export function computeTimeline(lines: MessageLine[], cfg: TypeConfig, elapsedMs: number): TimelineState {
  if (lines.length === 0) return { lineIndex: 0, visibleText: "", opacity: 0, done: true };

  let t = elapsedMs - cfg.startDelayMs;
  if (t < 0) return { lineIndex: 0, visibleText: "", opacity: 1, done: false };

  for (let i = 0; i < lines.length; i++) {
    const text = lines[i]!.text;
    const typeDur = text.length * cfg.charMs;
    if (t < typeDur) {
      const chars = Math.floor(t / cfg.charMs);
      return { lineIndex: i, visibleText: text.slice(0, chars), opacity: 1, done: false };
    }
    t -= typeDur;
    if (t < cfg.holdMs) {
      return { lineIndex: i, visibleText: text, opacity: 1, done: false };
    }
    t -= cfg.holdMs;
  }

  const lastIdx = lines.length - 1;
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
  for (const l of lines) total += l.text.length * cfg.charMs + cfg.holdMs;
  return total;
}

export interface MessageOverlayOptions {
  lines?: MessageLine[];
  config?: TypeConfig;
}

/** DOM renderer for the typed intro. Driven by the app loop via update(nowMs). */
export class MessageOverlay {
  readonly el: HTMLDivElement;
  private textEl: HTMLSpanElement;
  private cursorEl: HTMLSpanElement;
  private lines: MessageLine[];
  private cfg: TypeConfig;
  private startMs = 0;
  private playing = false;
  private onDoneCb: (() => void) | null = null;

  constructor(parent: HTMLElement, opts: MessageOverlayOptions = {}) {
    this.lines = opts.lines ?? DEFAULT_SCRIPT;
    this.cfg = opts.config ?? DEFAULT_TYPE_CONFIG;

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
    const state = computeTimeline(this.lines, this.cfg, elapsed);
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
