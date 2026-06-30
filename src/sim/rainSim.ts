import type { Controls, SimConfig } from "../types.ts";
import { FLAG_IS_HEAD, FLAG_WHITE_HEAD, PHASE_MASK } from "../types.ts";
import type { GlyphSet } from "./glyphSet.ts";
import { createRng, type Rng } from "../util/rng.ts";
import { clamp } from "../util/math.ts";

const TWO_PI = Math.PI * 2;
const MIN_BRIGHT = 0.004; // below this a cell is considered dark

/** One falling head within a column: its row position, fall speed, and white-lead flag. */
interface Stream {
  y: number;
  speed: number;
  white: 0 | 1;
}

export interface RainSimOptions {
  cols: number;
  rows: number;
  config: SimConfig;
  glyphSet: GlyphSet;
  seed?: number;
}

/**
 * Headless, deterministic CPU simulation of the Matrix rain over a cols x rows
 * grid. The film-accurate model: glyphs sit on a STATIONARY grid and a wave of
 * illumination sweeps down each column (the head), leaving an exponentially
 * decaying trail. Output is packed into `state` (RGBA8) for upload as a texture.
 */
export class RainSim {
  cols: number;
  rows: number;
  /** cols*rows*4 packed bytes — see types.ts for the channel layout. */
  state: Uint8Array;
  /** Max columns allowed to rain at once (Infinity = no cap). Ramped to fade rain in gradually. */
  activeColumnLimit = Number.POSITIVE_INFINITY;

  private cfg: SimConfig;
  private glyph: GlyphSet;
  private rng: Rng;
  private time = 0;

  // Per-column state. A column holds zero or more concurrently-falling streams
  // (heads); the count it sustains scales with the density control.
  private streams!: Stream[][];
  private respawnTimer!: Float32Array;

  // Per-cell state.
  private bright!: Float32Array;
  private glyphNew!: Uint8Array;
  private glyphOld!: Uint8Array;
  private phase!: Float32Array;

  // Scratch: per-row head markers, reused each column during the cell pass.
  private headMark!: Uint8Array;

  constructor(opts: RainSimOptions) {
    this.cols = opts.cols;
    this.rows = opts.rows;
    this.cfg = opts.config;
    this.glyph = opts.glyphSet;
    this.rng = createRng(opts.seed ?? 0x9e3779b9);
    this.state = new Uint8Array(opts.cols * opts.rows * 4);
    this.allocate(opts.cols, opts.rows);
    this.seedColumns(0, opts.cols);
  }

  private allocate(cols: number, rows: number): void {
    this.streams = Array.from({ length: cols }, () => []);
    this.respawnTimer = new Float32Array(cols);
    this.headMark = new Uint8Array(rows);
    this.bright = new Float32Array(cols * rows);
    this.glyphNew = new Uint8Array(cols * rows);
    this.glyphOld = new Uint8Array(cols * rows);
    this.phase = new Float32Array(cols * rows);
  }

  /** Initialize columns [from, to) as idle with staggered respawn timers. */
  private seedColumns(from: number, to: number): void {
    for (let c = from; c < to; c++) {
      this.streams[c]!.length = 0;
      this.respawnTimer[c] = this.rng() * this.cfg.respawnDelayJitter;
    }
  }

  /** Launch a new falling stream at the top of `col`. */
  private spawnStream(col: number): void {
    // The global speed control is applied live during advance, not stored here.
    this.streams[col]!.push({
      y: -this.rng() * this.cfg.startRowsAbove,
      speed: this.cfg.minSpeed + this.rng() * this.cfg.speedRange,
      white: this.rng() < this.cfg.whiteHeadFraction ? 1 : 0,
    });
  }

  /** Illuminate a cell as the head arrives: full brightness, fresh glyph, no crossfade. */
  private lightHeadCell(col: number, row: number): void {
    const idx = row * this.cols + col;
    this.bright[idx] = 1;
    this.glyphOld[idx] = this.glyphNew[idx]!;
    this.glyphNew[idx] = this.glyph.randomGlyphIndex(this.rng);
    this.phase[idx] = 1;
  }

  /** Resize the grid, preserving per-column head state where columns still exist. */
  resize(cols: number, rows: number): void {
    if (cols === this.cols && rows === this.rows) return;
    const oldStreams = this.streams;
    const oldTimer = this.respawnTimer;
    const oldCols = this.cols;

    this.allocate(cols, rows);
    this.state = new Uint8Array(cols * rows * 4);

    const keep = Math.min(oldCols, cols);
    for (let c = 0; c < keep; c++) {
      this.streams[c] = oldStreams[c]!;
      this.respawnTimer[c] = oldTimer[c]!;
    }
    if (cols > oldCols) this.seedColumns(oldCols, cols);

    this.cols = cols;
    this.rows = rows;
  }

  /** Pre-fill the screen so it doesn't start empty. */
  warmUp(controls: Controls, seconds = 2, step = 1 / 60): void {
    const steps = Math.floor(seconds / step);
    for (let i = 0; i < steps; i++) this.update(step, controls);
  }

  /** Return the sim to its empty initial state (as just after construction, before any update). */
  reset(): void {
    this.bright.fill(0);
    this.glyphNew.fill(0);
    this.glyphOld.fill(0);
    this.phase.fill(0);
    this.state.fill(0);
    this.time = 0;
    this.seedColumns(0, this.cols); // deactivate every column + restagger respawn timers
  }

  /** Advance the simulation by `dt` seconds and pack the result into `state`. */
  update(dt: number, controls: Controls): void {
    dt = clamp(dt, 0, 1 / 15);
    this.time += dt;
    const { cols, rows, cfg } = this;

    const decayMul = Math.pow(controls.trailLength, dt / cfg.trailLengthScale);
    const crossfadeStep = dt / cfg.crossfadeDuration;
    // Global mutation-sync: swaps cluster loosely in time (a film tell).
    const sync = Math.max(0, 1 + cfg.globalSyncAmount * Math.sin(this.time * cfg.globalSyncHz * TWO_PI));
    const mutChance = 1 - Math.exp(-cfg.mutationRate * sync * dt);
    const respawnProb = 1 - Math.exp(-cfg.respawnChance * controls.density * dt);
    const speedMul = controls.speed;
    // Density controls how many streams a column sustains at once, and how
    // quickly it refills toward that count (the inter-stream gap shrinks).
    const maxStreams = Math.max(1, Math.round(controls.density));
    const gapScale = 1 / controls.density;

    // Cap concurrent active columns when a limit is set (ramping). `activeNow` counts
    // columns that currently have at least one stream, recounted each frame.
    const limited = Number.isFinite(this.activeColumnLimit);
    let activeNow = 0;
    if (limited) for (let c = 0; c < cols; c++) if (this.streams[c]!.length > 0) activeNow++;

    for (let col = 0; col < cols; col++) {
      const streams = this.streams[col]!;

      // --- spawn a new stream when the gap timer elapses ---
      this.respawnTimer[col] = this.respawnTimer[col]! - dt;
      if (this.respawnTimer[col]! <= 0 && streams.length < maxStreams) {
        const opensColumn = streams.length === 0;
        if ((!limited || !opensColumn || activeNow < this.activeColumnLimit) && this.rng() < respawnProb) {
          this.spawnStream(col);
          if (limited && opensColumn) activeNow++;
          this.respawnTimer[col] = (cfg.respawnDelayMin + this.rng() * cfg.respawnDelayJitter) * gapScale;
        }
      }

      // --- advance every stream, dropping those past the bottom ---
      const hadStreams = streams.length > 0;
      for (let s = streams.length - 1; s >= 0; s--) {
        const stream = streams[s]!;
        const prevRow = Math.floor(stream.y);
        stream.y += stream.speed * speedMul * dt;
        const newRow = Math.floor(stream.y);
        for (let r = Math.max(prevRow + 1, 0); r <= newRow; r++) {
          if (r < rows) this.lightHeadCell(col, r);
        }
        if (stream.y - cfg.tailMargin > rows) streams.splice(s, 1);
      }
      if (limited && hadStreams && streams.length === 0) activeNow--;

      // --- mark this column's head rows for the cell pass ---
      for (const stream of streams) {
        const headRow = Math.floor(stream.y);
        if (headRow >= 0 && headRow < rows) this.headMark[headRow]! |= stream.white ? 0b11 : 0b01;
      }

      // --- decay, mutate, (pin), pack each cell ---
      for (let r = 0; r < rows; r++) {
        const idx = r * cols + col;
        let b = this.bright[idx]!;
        if (b > MIN_BRIGHT) {
          b *= decayMul;
          if (b < MIN_BRIGHT) b = 0;
          this.bright[idx] = b;
        } else if (b !== 0) {
          this.bright[idx] = 0;
          b = 0;
        }

        if (this.phase[idx]! < 1) {
          this.phase[idx] = Math.min(1, this.phase[idx]! + crossfadeStep);
        }

        const mark = this.headMark[r]!;
        this.headMark[r] = 0; // clear scratch for the next column
        const isHead = (mark & 0b01) !== 0;
        const white = (mark & 0b10) !== 0;
        if (!isHead && b > 0.05 && this.rng() < mutChance) {
          this.glyphOld[idx] = this.glyphNew[idx]!;
          this.glyphNew[idx] = this.glyph.randomGlyphIndex(this.rng);
          this.phase[idx] = 0;
        }

        const o = idx * 4;
        this.state[o] = this.glyphNew[idx]!;
        this.state[o + 1] = Math.round(clamp(b, 0, 1) * 255);
        this.state[o + 2] =
          (isHead ? FLAG_IS_HEAD : 0) |
          (white ? FLAG_WHITE_HEAD : 0) |
          (Math.round(this.phase[idx]! * PHASE_MASK) & PHASE_MASK);
        this.state[o + 3] = this.glyphOld[idx]!;
      }
    }
  }
}

// ---- Pure helpers (exported for unit tests) ----

export function decayBrightness(b: number, decayPerSecond: number, dt: number): number {
  return b * Math.pow(decayPerSecond, dt);
}

export interface UnpackedCell {
  glyphNew: number;
  brightness: number;
  isHead: boolean;
  whiteHead: boolean;
  phase: number;
  glyphOld: number;
}

export function packCell(
  glyphNew: number,
  brightness: number,
  isHead: boolean,
  whiteHead: boolean,
  phase: number,
  glyphOld: number,
): [number, number, number, number] {
  return [
    glyphNew & 0xff,
    Math.round(clamp(brightness, 0, 1) * 255),
    (isHead ? FLAG_IS_HEAD : 0) |
      (whiteHead ? FLAG_WHITE_HEAD : 0) |
      (Math.round(clamp(phase, 0, 1) * PHASE_MASK) & PHASE_MASK),
    glyphOld & 0xff,
  ];
}

export function unpackCell(r: number, g: number, b: number, a: number): UnpackedCell {
  return {
    glyphNew: r,
    brightness: g / 255,
    isHead: (b & FLAG_IS_HEAD) !== 0,
    whiteHead: (b & FLAG_WHITE_HEAD) !== 0,
    phase: (b & PHASE_MASK) / PHASE_MASK,
    glyphOld: a,
  };
}
