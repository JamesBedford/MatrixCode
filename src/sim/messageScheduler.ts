import type { MessagesDoc } from "../types.ts";
import type { GlyphSet } from "./glyphSet.ts";
import type { Rng } from "../util/rng.ts";

// Where a message is laid out: rows 35%–60% down the screen, so trails have room above the letters.
const BAND_TOP = 0.35;
const BAND_BOTTOM = 0.6;
// Jitter applied to the configured frequency: a gap is frequencyMs * (0.75 .. 1.25).
const JITTER_MIN = 0.75;
const JITTER_SPAN = 0.5;

/** The minimal surface the scheduler needs from a RainSim (RainSim satisfies this structurally). */
export interface MessageSink {
  readonly cols: number;
  readonly rows: number;
  setMessageTargets(targets: Map<number, number>): void;
  clearMessageTargets(): void;
  setMessageIntensity(intensity: number): void;
}

export interface MessageSchedulerDeps {
  glyphSet: GlyphSet;
  /** A seeded PRNG owned by the scheduler — separate from the sim's, so scheduling never perturbs the rain. */
  rng: Rng;
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
  private cfg: MessagesDoc | null = null;
  private nextFireAt: number | null = null;
  private activeStart: number | null = null;
  private activeUntil: number | null = null;
  private pendingClear = false;
  private lastCols = -1;
  private lastRows = -1;

  constructor(deps: MessageSchedulerDeps) {
    this.glyph = deps.glyphSet;
    this.rng = deps.rng;
  }

  /** Adopt a new config. Cancels any in-flight message and re-arms relative to the next update's clock. */
  configure(doc: MessagesDoc): void {
    this.cfg = doc;
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
    if (cfg === null || !cfg.enabled || !this.hasRenderableMessage(cfg)) {
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
        sim.setMessageIntensity(this.envelope(nowMs)); // fade in/out across the active window
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

  private hasRenderableMessage(cfg: MessagesDoc): boolean {
    return cfg.messages.some((m) => this.layout(m).glyphs.length > 0);
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

  /** Choose a message + placement and hand the target cells to the sim. */
  private fire(nowMs: number, sim: MessageSink): void {
    const cfg = this.cfg!;
    const candidates = cfg.messages.map((m) => m.trim()).filter((m) => m.length > 0);
    if (candidates.length === 0) {
      this.nextFireAt = nowMs + this.gap();
      return;
    }

    const message = candidates[Math.floor(this.rng() * candidates.length)]!;
    const { glyphs, width } = this.layout(message);
    if (glyphs.length === 0 || width > sim.cols) {
      this.nextFireAt = nowMs + this.gap(); // unrenderable or too wide → skip, try again later
      return;
    }

    const startCol = Math.max(0, Math.floor((sim.cols - width) / 2));
    const bandTop = Math.floor(sim.rows * BAND_TOP);
    const bandBottom = Math.floor(sim.rows * BAND_BOTTOM);
    const row = bandTop + Math.floor(this.rng() * (bandBottom - bandTop + 1));

    const targets = new Map<number, number>();
    for (const { offset, glyph } of glyphs) {
      const col = startCol + offset;
      if (col < sim.cols) targets.set(row * sim.cols + col, glyph);
    }
    if (targets.size === 0) {
      this.nextFireAt = nowMs + this.gap();
      return;
    }

    sim.setMessageTargets(targets);
    this.activeStart = nowMs;
    this.activeUntil = nowMs + cfg.persistenceMs;
    sim.setMessageIntensity(this.envelope(nowMs));
  }

  /**
   * The fade envelope at `nowMs`: ramps 0→1 over `appearMs`, holds at 1, then ramps 1→0 over
   * `disappearMs`, all within the persistence window. If appear+disappear exceed the window they are
   * scaled down to fit, so the message always fully fades in and out.
   */
  private envelope(nowMs: number): number {
    const total = this.activeUntil! - this.activeStart!; // persistenceMs
    let appear = Math.max(0, this.cfg!.appearMs);
    let disappear = Math.max(0, this.cfg!.disappearMs);
    if (appear + disappear > total && appear + disappear > 0) {
      const scale = total / (appear + disappear);
      appear *= scale;
      disappear *= scale;
    }
    const t = nowMs - this.activeStart!;
    if (appear > 0 && t < appear) return t / appear; // fade in
    if (disappear > 0 && t > total - disappear) return Math.max(0, (this.activeUntil! - nowMs) / disappear); // fade out
    return 1; // hold
  }
}
