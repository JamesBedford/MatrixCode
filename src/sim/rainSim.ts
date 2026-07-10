import type { Controls, SimConfig } from "../types.ts";
import { FLAG_IS_HEAD, FLAG_WHITE_HEAD, PHASE_MASK } from "../types.ts";
import type { GlyphSet } from "./glyphSet.ts";
import { createRng, type Rng } from "../util/rng.ts";
import { clamp } from "../util/math.ts";

const TWO_PI = Math.PI * 2;
const MIN_BRIGHT = 0.004; // below this a cell is considered dark
// Density control is scaled down so the same slider value produces roughly half the
// on-screen rain it used to — keeps the numeric range but halves the visual effect per unit.
const DENSITY_SCALE = 0.5;

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
  /** Ramp intensity (0..1): the fraction of columns allowed to rain. Each column has a fixed random
   * activation threshold, so as this rises columns switch on in random order (uniform, not
   * left-to-right) and coverage scales linearly with it. 0 = empty, 1 = full density. */
  spawnRateScale = 1;

  private cfg: SimConfig;
  private glyph: GlyphSet;
  private rng: Rng;
  // Message-only randomness must not perturb the shared rain stream when multi-monitor windows
  // target different physical slices.
  private messageRng: Rng;
  private seed: number;
  private time = 0;

  // Per-column state. A column holds zero or more concurrently-falling streams
  // (heads); the count it sustains scales with the density control.
  private streams!: Stream[][];
  private respawnTimer!: Float32Array;
  // Per-column activation threshold in [0,1): a column rains once spawnRateScale exceeds it.
  private columnGate!: Float32Array;

  // Per-cell state.
  private bright!: Float32Array;
  private glyphNew!: Uint8Array;
  private glyphOld!: Uint8Array;
  private phase!: Float32Array;

  // Scratch: per-row head markers, reused each column during the cell pass.
  private headMark!: Uint8Array;

  // In-rain message overlay, kept as index-parallel typed arrays (no per-cell Map/Set hashing on
  // the hot path). `messageTargets[idx]` = target glyph for the active message, or -1 where there is
  // none; null when no message is active (the zero-overhead fast path). `claimed[idx]` = 1 once the
  // rain has lit that target cell this activation, so it holds the letter.
  private messageTargets: Int16Array | null = null;
  private claimed!: Uint8Array;
  // 0..1 fade envelope scaling the message hold brightness — driven by the scheduler for fade in/out.
  private messageIntensity = 1;
  // 0..1 probability a message cell shows a random glyph instead of its letter (flicker dissolve on exit).
  private messageScramble = 0;

  constructor(opts: RainSimOptions) {
    this.cols = opts.cols;
    this.rows = opts.rows;
    this.cfg = opts.config;
    this.glyph = opts.glyphSet;
    this.seed = opts.seed ?? 0x9e3779b9;
    this.rng = createRng(this.seed);
    this.messageRng = createRng((this.seed ^ 0x27d4eb2d) >>> 0);
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
    this.claimed = new Uint8Array(cols * rows);
    // Assign each column a random ramp-in threshold from a SEPARATE rng so it never perturbs the spawn
    // stream (keeps golden determinism). Random order → columns fade in uniformly, not left-to-right.
    const gateRng = createRng((this.seed ^ 0x85ebca6b) >>> 0);
    this.columnGate = new Float32Array(cols);
    for (let c = 0; c < cols; c++) this.columnGate[c] = gateRng();
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
    const g = this.glyph.randomGlyphIndex(this.rng); // always drawn so the rng stream is message-independent
    const target = this.messageTargets !== null ? this.messageTargets[idx]! : -1; // -1 = not a message cell
    this.bright[idx] = 1;
    this.glyphOld[idx] = this.glyphNew[idx]!;
    // A passing head delivers the message letter; otherwise a random glyph. During a flicker dissolve
    // the head may stamp a random glyph instead (the extra rng draw only happens while scrambling).
    this.glyphNew[idx] =
      target < 0 ? g : this.messageScramble > 0 && this.messageRng() < this.messageScramble ? g : target;
    this.phase[idx] = 1;
    if (target >= 0) this.claimed[idx] = 1;
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
    // Cell indices depend on `cols`, so any active message's targets are now stale — drop them.
    // (allocate() above already replaced `claimed` with a fresh zeroed buffer of the new size.)
    this.messageTargets = null;
    this.messageIntensity = 1;
    this.messageScramble = 0;
  }

  /** Pre-fill the screen so it doesn't start empty. */
  warmUp(controls: Controls, seconds = 2, step = 1 / 60): void {
    const steps = Math.floor(seconds / step);
    for (let i = 0; i < steps; i++) this.update(step, controls);
  }

  /**
   * Pre-fill a tall virtual grid into a deterministic steady state, then run the
   * ordinary warm-up. Normal streams always enter above row zero, so a short
   * warm-up leaves lower monitors black in a vertically stacked display wall.
   * Seeding heads across their whole lifecycle gives every physical slice rain
   * immediately without changing the normal single-display golden sequence.
   */
  warmUpDistributed(controls: Controls, seconds = 2, step = 1 / 60): void {
    const density = controls.density * DENSITY_SCALE;
    const streamCount = Math.max(1, Math.round(density));
    const activeChance = clamp(density / (density + 0.6), 0.1, 1);
    const minY = -this.cfg.startRowsAbove;
    const spanY = this.rows + this.cfg.tailMargin - minY;
    const speedMul = Math.max(controls.speed, 0.1);

    for (let col = 0; col < this.cols; col++) {
      if (this.rng() > activeChance) continue;
      for (let s = 0; s < streamCount; s++) {
        const stream: Stream = {
          y: minY + this.rng() * spanY,
          speed: this.cfg.minSpeed + this.rng() * this.cfg.speedRange,
          white: this.rng() < this.cfg.whiteHeadFraction ? 1 : 0,
        };
        this.streams[col]!.push(stream);

        // Reconstruct the still-visible stationary trail behind this head.
        const headRow = Math.min(Math.floor(stream.y), this.rows - 1);
        for (let row = headRow; row >= 0; row--) {
          const ageSeconds = (stream.y - row) / (stream.speed * speedMul);
          const brightness = Math.pow(controls.trailLength, ageSeconds / this.cfg.trailLengthScale);
          if (brightness < MIN_BRIGHT) break;
          const idx = row * this.cols + col;
          const previous = this.bright[idx]!;
          this.lightHeadCell(col, row);
          this.bright[idx] = Math.max(previous, brightness);
        }
      }
    }

    // Pack the seeded state before advancing it through the standard path.
    this.update(0, controls);
    this.warmUp(controls, seconds, step);
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
    this.messageTargets = null;
    this.claimed.fill(0);
    this.messageIntensity = 1;
    this.messageScramble = 0;
  }

  /**
   * Overlay an in-rain message: a map of cell index -> target glyph index. While set, the rain
   * reveals those glyphs wherever it naturally lights the cell (a passing head, or a lit trail cell
   * on its next mutation) and holds them legible; cells the rain never reaches stay dark. Replaces
   * any previous message and forgets which cells were revealed.
   */
  setMessageTargets(targets: Map<number, number>): void {
    const cells = this.cols * this.rows;
    const next = new Int16Array(cells).fill(-1);
    for (const [idx, glyph] of targets) {
      if (idx >= 0 && idx < cells) next[idx] = glyph;
    }
    this.messageTargets = next;
    this.claimed.fill(0);
    this.messageIntensity = 1;
    this.messageScramble = 0;
  }

  /**
   * Swap the active message's target map in place, preserving the reveal (`claimed`) state of every
   * cell whose target glyph is unchanged and clearing it only where the target changed, was added, or
   * was removed. Used to live-update a ticking message (e.g. a countdown) without re-materialising the
   * whole string each second — only the glyphs that actually changed re-reveal. The fade envelope
   * (intensity/scramble) is left untouched, since the scheduler owns it and a mid-fade swap must not
   * jump. Falls back to a from-scratch reveal when no message is currently active.
   */
  updateMessageTargets(targets: Map<number, number>): void {
    if (this.messageTargets === null) {
      this.setMessageTargets(targets);
      return;
    }
    const cells = this.cols * this.rows;
    const next = new Int16Array(cells).fill(-1);
    for (const [idx, glyph] of targets) {
      if (idx >= 0 && idx < cells) next[idx] = glyph;
    }
    for (let i = 0; i < cells; i++) {
      if (next[i] !== this.messageTargets[i]) this.claimed[i] = 0; // changed/added/removed → re-reveal
    }
    this.messageTargets = next;
  }

  /** Remove the active message so its revealed cells dissolve back into random rain. */
  clearMessageTargets(): void {
    // Hand each revealed cell off at exactly the brightness it was last displayed at
    // (max(b,floor) scaled by the fade), so the pin releasing is seamless — no flash up from a
    // faded-out message, and no flash down when the brightness fade is disabled (intensity 1).
    if (this.messageTargets !== null) {
      const floor = this.cfg.messageBrightFloor;
      const claimed = this.claimed;
      for (let idx = 0; idx < claimed.length; idx++) {
        if (claimed[idx]) this.bright[idx] = Math.max(this.bright[idx]!, floor) * this.messageIntensity;
      }
    }
    this.messageTargets = null;
    this.claimed.fill(0);
    this.messageIntensity = 1;
    this.messageScramble = 0;
  }

  /**
   * Scale the brightness a revealed message cell shows, 0..1. The scheduler ramps this to fade the
   * message in and out; the whole displayed brightness (including head flashes) is scaled, so the
   * fade is visible even when dense rain keeps re-lighting the letters.
   */
  setMessageIntensity(intensity: number): void {
    this.messageIntensity = clamp(intensity, 0, 1);
  }

  /**
   * Probability (0..1) that a message cell shows a random glyph instead of its letter. Ramped up over
   * the fade-out for a "flicker dissolve" where the letters scramble back into the rain.
   */
  setMessageScramble(p: number): void {
    this.messageScramble = clamp(p, 0, 1);
  }

  /** Whether an in-rain message is currently active. */
  hasMessageTargets(): boolean {
    return this.messageTargets !== null;
  }

  /** Advance the simulation by `dt` seconds and pack the result into `state`. */
  update(dt: number, controls: Controls): void {
    dt = clamp(dt, 0, 1 / 15);
    this.time += dt;
    const { cols, rows, cfg } = this;

    const decayMul = Math.pow(controls.trailLength, dt / cfg.trailLengthScale);
    const crossfadeStep = dt / cfg.crossfadeDuration;
    // Global mutation-sync: swaps cluster loosely in time (a film tell). The glyphRate control scales
    // how often trail glyphs change, independent of fall speed (glyphRate 0 = trail cells never mutate).
    const sync = Math.max(0, 1 + cfg.globalSyncAmount * Math.sin(this.time * cfg.globalSyncHz * TWO_PI));
    const mutChance = 1 - Math.exp(-cfg.mutationRate * controls.glyphRate * sync * dt);
    const density = controls.density * DENSITY_SCALE;
    const respawnProb = 1 - Math.exp(-cfg.respawnChance * density * dt);
    const speedMul = controls.speed;
    // Density controls how many streams a column sustains at once, and how
    // quickly it refills toward that count (the inter-stream gap shrinks).
    const maxStreams = Math.max(1, Math.round(density));
    const gapScale = 1 / density;
    const floor = cfg.messageBrightFloor;
    const targets = this.messageTargets; // null when no message is active (zero-overhead fast path)

    for (let col = 0; col < cols; col++) {
      const streams = this.streams[col]!;

      // --- spawn a new stream when the gap timer elapses ---
      this.respawnTimer[col] = this.respawnTimer[col]! - dt;
      // A column rains only once the ramp level passes its fixed random threshold (spawnRateScale = 1
      // opens every column). rng is drawn first so the full-rain path stays bit-identical.
      if (this.respawnTimer[col]! <= 0 && streams.length < maxStreams) {
        if (this.rng() < respawnProb && this.spawnRateScale > this.columnGate[col]!) {
          this.spawnStream(col);
          this.respawnTimer[col] = (cfg.respawnDelayMin + this.rng() * cfg.respawnDelayJitter) * gapScale;
        }
      }

      // --- advance every stream, dropping those past the bottom ---
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

      // --- mark this column's head rows for the cell pass ---
      for (let s = 0; s < streams.length; s++) {
        const st = streams[s]!;
        const headRow = Math.floor(st.y);
        if (headRow >= 0 && headRow < rows) this.headMark[headRow]! |= st.white ? 0b11 : 0b01;
      }

      // --- decay, mutate, (pin), pack each cell ---
      for (let r = 0; r < rows; r++) {
        const idx = r * cols + col;
        const target = targets !== null ? targets[idx]! : -1; // -1 = not a message cell
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
          const g = this.glyph.randomGlyphIndex(this.rng); // always drawn so the rng stream is message-independent
          if (target >= 0) {
            // A lit message cell resolves to its letter on this mutation and holds it (revealed via mutation).
            // During a flicker dissolve it may instead resolve to a random glyph (extra rng only while scrambling).
            this.claimed[idx] = 1;
            const next = this.messageScramble > 0 && this.messageRng() < this.messageScramble ? g : target;
            if (next !== this.glyphNew[idx]) {
              this.glyphOld[idx] = this.glyphNew[idx]!;
              this.glyphNew[idx] = next;
              this.phase[idx] = 0;
            }
          } else {
            this.glyphOld[idx] = this.glyphNew[idx]!;
            this.glyphNew[idx] = g;
            this.phase[idx] = 0;
          }
        }

        const o = idx * 4;
        // A revealed (claimed) message cell holds at least the floor brightness so the letter stays
        // legible between head passes. The whole held brightness is scaled by the fade envelope
        // (messageIntensity) — including head flashes — so the fade is visible even in dense rain. The
        // underlying `bright` is untouched, so the rng stays message-independent.
        const packB =
          target >= 0 && this.claimed[idx] === 1 ? Math.max(b, floor) * this.messageIntensity : b;
        this.state[o] = this.glyphNew[idx]!;
        this.state[o + 1] = Math.round(clamp(packB, 0, 1) * 255);
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
