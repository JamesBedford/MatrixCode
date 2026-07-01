import type { MessagesDoc } from "../types.ts";
import type { GlyphSet } from "./glyphSet.ts";
import type { Rng } from "../util/rng.ts";

// Jitter applied to the configured frequency: a gap is frequencyMs * (0.75 .. 1.25).
const JITTER_MIN = 0.75;
const JITTER_SPAN = 0.5;

/** The minimal surface the scheduler needs from a RainSim (RainSim satisfies this structurally). */
export interface MessageSink {
  readonly cols: number;
  readonly rows: number;
  setMessageTargets(targets: Map<number, number>): void;
  /** Live-update an active message's targets, preserving the reveal of unchanged cells (for ticking text). */
  updateMessageTargets(targets: Map<number, number>): void;
  clearMessageTargets(): void;
  setMessageIntensity(intensity: number): void;
  setMessageScramble(p: number): void;
}

export interface MessageSchedulerDeps {
  glyphSet: GlyphSet;
  /** A seeded PRNG owned by the scheduler — separate from the sim's, so scheduling never perturbs the rain. */
  rng: Rng;
  /** Resolve dynamic tokens ({name}/{time}/{countdown}) in a message before layout. Default: identity. */
  resolveText?: (raw: string) => string;
}

/** One renderable glyph of a laid-out message, at a column offset from the message's start column. */
interface PlacedGlyph {
  offset: number;
  glyph: number;
}

/**
 * Decides WHEN a message appears, WHICH one, and WHERE on the grid, then hands the target cells to a
 * RainSim. Pure and deterministic: time is injected via `update(nowMs, …)` and randomness via a seeded
 * Rng, so it is fully unit-testable and holds no reference to the sim between calls.
 */
export class MessageScheduler {
  private glyph: GlyphSet;
  private rng: Rng;
  private resolveText: (raw: string) => string;
  private cfg: MessagesDoc | null = null;
  // Whether the current config has at least one message that lays out to renderable glyphs.
  // Computed once when the config changes (in configure()) so the per-frame update() doesn't
  // re-lay-out every message every frame.
  private hasRenderable = false;
  private nextFireAt: number | null = null;
  private activeStart: number | null = null;
  private activeUntil: number | null = null;
  private pendingClear = false;
  private lastCols = -1;
  private lastRows = -1;
  // The active message, tracked so a ticking placeholder ({time}/{countdown}) can re-lay-out live:
  // `activeRaw` is the unresolved template, `activeDisplay` its last resolved+rendered value, and
  // `activeRow` the row picked once at fire (reused on re-layout so the message never jumps).
  private activeRaw: string | null = null;
  private activeRow = 0;
  private activeDisplay = "";

  constructor(deps: MessageSchedulerDeps) {
    this.glyph = deps.glyphSet;
    this.rng = deps.rng;
    this.resolveText = deps.resolveText ?? ((raw) => raw);
  }

  /** Adopt a new config. Cancels any in-flight message and re-arms relative to the next update's clock. */
  configure(doc: MessagesDoc): void {
    this.cfg = doc;
    this.hasRenderable = this.computeHasRenderable(doc);
    if (this.activeUntil !== null) this.pendingClear = true;
    this.activeStart = null;
    this.activeUntil = null;
    this.nextFireAt = null;
  }

  /** Per-frame heartbeat: expire/clear an active message, or fire a new one when due. */
  update(nowMs: number, sim: MessageSink): void {
    if (this.pendingClear) {
      sim.clearMessageTargets();
      this.pendingClear = false;
    }

    const cfg = this.cfg;
    if (cfg === null || !cfg.enabled || !this.hasRenderable) {
      if (this.activeUntil !== null) {
        sim.clearMessageTargets();
        this.activeStart = null;
        this.activeUntil = null;
      }
      this.nextFireAt = null;
      this.lastCols = sim.cols;
      this.lastRows = sim.rows;
      return;
    }

    // A resize cancels an active message (its cell indices are now stale; the sim already dropped them).
    if ((sim.cols !== this.lastCols || sim.rows !== this.lastRows) && this.activeUntil !== null) {
      this.activeStart = null;
      this.activeUntil = null;
      this.nextFireAt = null;
    }
    this.lastCols = sim.cols;
    this.lastRows = sim.rows;

    if (this.activeUntil !== null) {
      if (nowMs >= this.activeUntil) {
        sim.clearMessageTargets();
        this.activeStart = null;
        this.activeUntil = null;
        this.nextFireAt = nowMs + this.gap();
      } else {
        // Re-resolve the active template; if a placeholder ticked (e.g. a countdown second), re-lay it
        // out in place so only the changed glyphs re-reveal — the rest of the message stays steady.
        if (this.activeRaw !== null) {
          const display = this.resolveText(this.activeRaw);
          if (display !== this.activeDisplay) this.applyMessage(display, sim, true);
        }
        sim.setMessageIntensity(this.cfg!.brightnessFade ? this.envelope(nowMs) : 1); // transparency fade in/out
        sim.setMessageScramble(this.cfg!.flickerOut ? this.scramble(nowMs) : 0); // flicker dissolve in/out
      }
      return; // one message at a time
    }

    if (this.nextFireAt === null) {
      this.nextFireAt = nowMs + this.gap();
      return;
    }

    if (nowMs >= this.nextFireAt) this.fire(nowMs, sim);
  }

  /** Fire a message immediately (used by the editor's Preview); optionally adopt `doc` first. */
  previewOne(nowMs: number, sim: MessageSink, doc?: MessagesDoc): void {
    if (doc) this.configure(doc);
    if (this.cfg === null) return;
    if (this.pendingClear) {
      sim.clearMessageTargets();
      this.pendingClear = false;
    }
    this.lastCols = sim.cols;
    this.lastRows = sim.rows;
    this.fire(nowMs, sim);
  }

  /** A jittered gap (±25%) before the next message. */
  private gap(): number {
    return this.cfg!.frequencyMs * (JITTER_MIN + JITTER_SPAN * this.rng());
  }

  /**
   * Pick the message's row from the configured vertical anchor plus random jitter. The jitter band is
   * clamped to the grid so the (single-row) message always lands on screen, whatever the anchor/jitter.
   */
  private pickRow(rows: number): number {
    const maxRow = rows - 1;
    if (maxRow <= 0) return 0;
    const cfg = this.cfg!;
    const anchor = Math.round(cfg.verticalPosition * maxRow);
    const halfSpan = Math.round((cfg.verticalJitter * maxRow) / 2);
    const lo = Math.max(0, anchor - halfSpan);
    const hi = Math.min(maxRow, anchor + halfSpan);
    return lo + Math.floor(this.rng() * (hi - lo + 1));
  }

  private computeHasRenderable(cfg: MessagesDoc): boolean {
    return cfg.messages.some((m) => this.layout(this.resolveText(m)).glyphs.length > 0);
  }

  /** Resolve a message to its renderable glyphs (unsupported chars/spaces become gaps) and its width. */
  private layout(message: string): { glyphs: PlacedGlyph[]; width: number } {
    const chars = [...message.trim()];
    const glyphs: PlacedGlyph[] = [];
    for (let i = 0; i < chars.length; i++) {
      const g = this.glyph.charToGlyphIndex(chars[i]!);
      if (g !== null) glyphs.push({ offset: i, glyph: g });
    }
    return { glyphs, width: chars.length };
  }

  /**
   * Lay out `display` centered on `this.activeRow` and hand its cells to the sim: from-scratch on the
   * initial appearance (`isUpdate === false` → setMessageTargets), or in place on a live tick
   * (`isUpdate === true` → updateMessageTargets, preserving unchanged reveals). Returns false and leaves
   * the sim untouched when nothing is renderable (keeps the previous targets on a bad re-resolve).
   */
  private applyMessage(display: string, sim: MessageSink, isUpdate: boolean): boolean {
    const { glyphs, width } = this.layout(display);
    if (glyphs.length === 0 || width > sim.cols) return false;

    const startCol = Math.max(0, Math.floor((sim.cols - width) / 2));
    const targets = new Map<number, number>();
    for (const { offset, glyph } of glyphs) {
      const col = startCol + offset;
      if (col < sim.cols) targets.set(this.activeRow * sim.cols + col, glyph);
    }
    if (targets.size === 0) return false;

    if (isUpdate) sim.updateMessageTargets(targets);
    else sim.setMessageTargets(targets);
    this.activeDisplay = display;
    return true;
  }

  /** Choose a message + placement and hand the target cells to the sim. */
  private fire(nowMs: number, sim: MessageSink): void {
    const cfg = this.cfg!;
    const candidates = cfg.messages.map((m) => m.trim()).filter((m) => m.length > 0);
    if (candidates.length === 0) {
      this.nextFireAt = nowMs + this.gap();
      return;
    }

    const raw = candidates[Math.floor(this.rng() * candidates.length)]!;
    this.activeRow = this.pickRow(sim.rows); // pick once; reused on live re-layout so the message never jumps
    const display = this.resolveText(raw);
    if (!this.applyMessage(display, sim, false)) {
      this.nextFireAt = nowMs + this.gap(); // unrenderable or too wide → skip, try again later
      return;
    }

    this.activeRaw = raw;
    this.activeStart = nowMs;
    // Total on-screen time = fade in + hold + fade out. The fades extend the animation; they never
    // clip or scale the hold.
    const appear = Math.max(0, cfg.appearMs);
    const disappear = Math.max(0, cfg.disappearMs);
    this.activeUntil = nowMs + appear + cfg.persistenceMs + disappear;
    sim.setMessageIntensity(cfg.brightnessFade ? this.envelope(nowMs) : 1);
    sim.setMessageScramble(cfg.flickerOut ? this.scramble(nowMs) : 0);
  }

  /**
   * The fade envelope at `nowMs`: ramps 0→1 over `appearMs`, holds at 1 for `persistenceMs`, then
   * ramps 1→0 over `disappearMs`. No scaling — the phases run their full length back to back.
   */
  private envelope(nowMs: number): number {
    const appear = Math.max(0, this.cfg!.appearMs);
    const disappear = Math.max(0, this.cfg!.disappearMs);
    const t = nowMs - this.activeStart!;
    if (appear > 0 && t < appear) return t / appear; // fade in
    const fadeOutStart = this.activeUntil! - this.activeStart! - disappear; // = appear + hold
    if (disappear > 0 && t > fadeOutStart) return Math.max(0, (this.activeUntil! - nowMs) / disappear); // fade out
    return 1; // hold
  }

  /**
   * The flicker scramble probability at `nowMs`: ramps 1→0 across the fade-in (the message resolves
   * out of random glyphs), 0 during the hold, then 0→1 across the fade-out (it dissolves back to random).
   */
  private scramble(nowMs: number): number {
    const appear = Math.max(0, this.cfg!.appearMs);
    const disappear = Math.max(0, this.cfg!.disappearMs);
    const t = nowMs - this.activeStart!;
    if (appear > 0 && t < appear) return 1 - t / appear; // flicker in
    if (disappear > 0) {
      const fadeOutStart = this.activeUntil! - this.activeStart! - disappear;
      if (t > fadeOutStart) return Math.min(1, (t - fadeOutStart) / disappear); // flicker out
    }
    return 0; // hold
  }
}
