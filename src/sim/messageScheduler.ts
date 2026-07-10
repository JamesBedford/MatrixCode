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

/** A rectangular part of the simulation grid in which a copy of the message should be centered. */
export interface MessageRegion {
  colStart: number;
  rowStart: number;
  cols: number;
  rows: number;
}

export interface MessageSchedulerDeps {
  glyphSet: GlyphSet;
  /** A seeded PRNG owned by the scheduler — separate from the sim's, so scheduling never perturbs the rain. */
  rng: Rng;
  /** Resolve dynamic tokens ({name}/{greeting}/{uptime}/{fps}/{time}/{countdown}) before layout. Default: identity. */
  resolveText?: (raw: string) => string;
}

/** One renderable glyph of a laid-out message, at an offset from its start cell. */
interface PlacedGlyph {
  offset: number;
  glyph: number;
}

interface ActivePlacement {
  region: MessageRegion;
  row: number;
  col: number;
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
  // `activePlacements` holds the independently-jittered row/column chosen inside each target region.
  private activeRaw: string | null = null;
  private activePlacements: ActivePlacement[] = [];
  private activeDisplay = "";
  private placementKey = "";

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
    this.activePlacements = [];
    this.placementKey = "";
  }

  /**
   * Per-frame heartbeat: expire/clear an active message, or fire a new one when due. When `regions`
   * is supplied, the same message is centered independently in every region; otherwise it is centered
   * once across the whole grid.
   */
  update(nowMs: number, sim: MessageSink, regions?: readonly MessageRegion[]): void {
    const placementRegions = this.normalizeRegions(sim, regions);
    const placementKey = this.keyForRegions(placementRegions);
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
      this.placementKey = placementKey;
      return;
    }

    // RainSim drops message targets when its grid is resized because the cell indices become stale.
    // Re-layout an active message when the grid or placement regions change so fullscreen transitions
    // do not make it disappear and changing vignette mode takes effect without restarting the delay.
    const placementChanged = placementKey !== this.placementKey;
    if (
      (sim.cols !== this.lastCols || sim.rows !== this.lastRows || placementChanged) &&
      this.activeUntil !== null
    ) {
      this.choosePlacements(placementRegions);
      const display = this.activeRaw === null ? this.activeDisplay : this.resolveText(this.activeRaw);
      if (!this.applyMessage(display, sim, false)) {
        // A resized grid may no longer fit the message. End this activation cleanly and try
        // another configured message after the usual gap.
        this.activeRaw = null;
        this.activeStart = null;
        this.activeUntil = null;
        this.nextFireAt = nowMs + this.gap();
        this.activePlacements = [];
      }
    }
    this.lastCols = sim.cols;
    this.lastRows = sim.rows;
    this.placementKey = placementKey;

    if (this.activeUntil !== null) {
      if (nowMs >= this.activeUntil) {
        sim.clearMessageTargets();
        this.activeStart = null;
        this.activeUntil = null;
        this.nextFireAt = nowMs + this.gap();
        this.activePlacements = [];
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

    if (nowMs >= this.nextFireAt) this.fire(nowMs, sim, placementRegions);
  }

  /** Fire a message immediately (used by the editor's Preview); optionally adopt `doc` first. */
  previewOne(
    nowMs: number,
    sim: MessageSink,
    doc?: MessagesDoc,
    regions?: readonly MessageRegion[],
  ): void {
    if (doc) this.configure(doc);
    if (this.cfg === null) return;
    if (this.pendingClear) {
      sim.clearMessageTargets();
      this.pendingClear = false;
    }
    this.lastCols = sim.cols;
    this.lastRows = sim.rows;
    const placementRegions = this.normalizeRegions(sim, regions);
    this.placementKey = this.keyForRegions(placementRegions);
    this.fire(nowMs, sim, placementRegions);
  }

  /** A jittered gap (±25%) before the next message. */
  private gap(): number {
    return this.cfg!.frequencyMs * (JITTER_MIN + JITTER_SPAN * this.rng());
  }

  /** Pick a row/column from the configured axis anchor plus random jitter, clamped on-screen. */
  private pickAxisIndex(size: number): number {
    const maxIndex = size - 1;
    if (maxIndex <= 0) return 0;
    const cfg = this.cfg!;
    const anchor = Math.round(cfg.verticalPosition * maxIndex);
    const halfSpan = Math.round((cfg.verticalJitter * maxIndex) / 2);
    const lo = Math.max(0, anchor - halfSpan);
    const hi = Math.min(maxIndex, anchor + halfSpan);
    return lo + Math.floor(this.rng() * (hi - lo + 1));
  }

  /** Clamp caller-provided regions to the simulation; an absent/empty list means the full grid. */
  private normalizeRegions(sim: MessageSink, regions?: readonly MessageRegion[]): MessageRegion[] {
    if (!regions || regions.length === 0) {
      return [{ colStart: 0, rowStart: 0, cols: sim.cols, rows: sim.rows }];
    }
    const normalized: MessageRegion[] = [];
    for (const region of regions) {
      const colStart = Math.max(0, Math.min(sim.cols, Math.floor(region.colStart)));
      const rowStart = Math.max(0, Math.min(sim.rows, Math.floor(region.rowStart)));
      const colEnd = Math.max(colStart, Math.min(sim.cols, Math.ceil(region.colStart + region.cols)));
      const rowEnd = Math.max(rowStart, Math.min(sim.rows, Math.ceil(region.rowStart + region.rows)));
      if (colEnd > colStart && rowEnd > rowStart) {
        normalized.push({ colStart, rowStart, cols: colEnd - colStart, rows: rowEnd - rowStart });
      }
    }
    return normalized.length > 0
      ? normalized
      : [{ colStart: 0, rowStart: 0, cols: sim.cols, rows: sim.rows }];
  }

  private keyForRegions(regions: readonly MessageRegion[]): string {
    return regions.map((r) => `${r.colStart},${r.rowStart},${r.cols},${r.rows}`).join(";");
  }

  /** Pick placement independently inside every target region. */
  private choosePlacements(regions: readonly MessageRegion[]): void {
    const dropLayout = this.cfg?.messageLayout === "drop";
    this.activePlacements = regions.map((region) => (
      dropLayout
        ? { region, row: region.rowStart, col: region.colStart + this.pickAxisIndex(region.cols) }
        : { region, row: region.rowStart + this.pickAxisIndex(region.rows), col: region.colStart }
    ));
  }

  private computeHasRenderable(cfg: MessagesDoc): boolean {
    return cfg.messages.some((m) => this.layout(this.resolveText(m)).glyphs.length > 0);
  }

  /** Resolve a message to its renderable glyphs (unsupported chars/spaces become gaps) and length. */
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
   * Lay out `display` centered in every active placement and hand its cells to the sim: from-scratch
   * on the initial appearance (`isUpdate === false` → setMessageTargets), or in place on a live tick
   * (`isUpdate === true` → updateMessageTargets, preserving unchanged reveals). Returns false and
   * leaves the sim untouched when nothing is renderable or it cannot fit every requested region.
   */
  private applyMessage(display: string, sim: MessageSink, isUpdate: boolean): boolean {
    const { glyphs, width } = this.layout(display);
    const dropLayout = this.cfg?.messageLayout === "drop";
    if (
      glyphs.length === 0 ||
      this.activePlacements.length === 0 ||
      this.activePlacements.some(({ region }) => width > (dropLayout ? region.rows : region.cols))
    ) return false;

    const targets = new Map<number, number>();
    for (const { region, row, col } of this.activePlacements) {
      if (dropLayout) {
        const startRow = region.rowStart + Math.floor((region.rows - width) / 2);
        const bottomToTop = this.cfg?.messageDirection === "bottomToTop";
        for (const { offset, glyph } of glyphs) {
          const targetRow = bottomToTop ? startRow + width - 1 - offset : startRow + offset;
          targets.set(targetRow * sim.cols + col, glyph);
        }
      } else {
        const startCol = region.colStart + Math.floor((region.cols - width) / 2);
        for (const { offset, glyph } of glyphs) {
          const targetCol = startCol + offset;
          targets.set(row * sim.cols + targetCol, glyph);
        }
      }
    }
    if (targets.size === 0) return false;

    if (isUpdate) sim.updateMessageTargets(targets);
    else sim.setMessageTargets(targets);
    this.activeDisplay = display;
    return true;
  }

  /** Choose a message + placement and hand the target cells to the sim. */
  private fire(nowMs: number, sim: MessageSink, regions: readonly MessageRegion[]): void {
    const cfg = this.cfg!;
    const candidates = cfg.messages.map((m) => m.trim()).filter((m) => m.length > 0);
    if (candidates.length === 0) {
      this.nextFireAt = nowMs + this.gap();
      return;
    }

    const raw = candidates[Math.floor(this.rng() * candidates.length)]!;
    this.choosePlacements(regions); // placements are picked once and reused for live token re-layout
    const display = this.resolveText(raw);
    if (!this.applyMessage(display, sim, false)) {
      this.activePlacements = [];
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
