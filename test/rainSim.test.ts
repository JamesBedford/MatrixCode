import { describe, it, expect } from "vitest";
import { RainSim, packCell, unpackCell, decayBrightness } from "../src/sim/rainSim.ts";
import { createGlyphSet } from "../src/sim/glyphSet.ts";
import { DEFAULT_SIM_CONFIG } from "../src/config/simConfig.ts";
import { FLAG_IS_HEAD, PHASE_MASK } from "../src/types.ts";
import type { Controls } from "../src/types.ts";

const CONTROLS: Controls = {
  speed: 1,
  trailLength: 0.08,
  density: 1,
  rampUpMs: 0,
  glyphRate: 1,
  glyphScale: 1,
  glow: 1,
  leadBrightness: 1.6,
  preset: "classic",
  mirror: true,
  scanlines: false,
  vignette: false,
  quality: "high",
};

function makeSim(cols = 24, rows = 40, seed = 12345): RainSim {
  return new RainSim({ cols, rows, config: DEFAULT_SIM_CONFIG, glyphSet: createGlyphSet(), seed });
}

describe("pack/unpack round-trip", () => {
  it("preserves glyph indices, head flags and brightness", () => {
    const [r, g, b, a] = packCell(200, 0.5, true, true, 1, 99);
    const u = unpackCell(r, g, b, a);
    expect(u.glyphNew).toBe(200);
    expect(u.glyphOld).toBe(99);
    expect(u.isHead).toBe(true);
    expect(u.whiteHead).toBe(true);
    expect(u.brightness).toBeCloseTo(0.5, 1);
    expect(u.phase).toBeCloseTo(1, 5);
  });

  it("round-trips phase within the 6-bit quantization", () => {
    for (const phase of [0, 0.25, 0.5, 0.75, 1]) {
      const [r, g, b, a] = packCell(0, 1, false, false, phase, 0);
      const u = unpackCell(r, g, b, a);
      expect(Math.abs(u.phase - phase)).toBeLessThanOrEqual(1 / 63 + 1e-9);
    }
  });

  it("clears flags when not a head", () => {
    const [, , b] = packCell(0, 1, false, false, 0, 0);
    expect(b & FLAG_IS_HEAD).toBe(0);
  });
});

describe("decayBrightness", () => {
  it("is exponential in dt", () => {
    expect(decayBrightness(1, 0.1, 0)).toBe(1);
    expect(decayBrightness(1, 0.1, 1)).toBeCloseTo(0.1, 6);
    expect(decayBrightness(1, 0.1, 2)).toBeCloseTo(0.01, 6);
  });
});

describe("RainSim", () => {
  it("is deterministic for a given seed", () => {
    const a = makeSim();
    const b = makeSim();
    for (let i = 0; i < 120; i++) {
      a.update(1 / 60, CONTROLS);
      b.update(1 / 60, CONTROLS);
    }
    expect(Array.from(a.state)).toEqual(Array.from(b.state));
  });

  it("produces rain with lit cells, gaps, and at least one head after warm-up", () => {
    const sim = makeSim(24, 40);
    sim.warmUp(CONTROLS, 3);

    let lit = 0;
    let dark = 0;
    let heads = 0;
    const total = sim.cols * sim.rows;
    for (let i = 0; i < total; i++) {
      const g = sim.state[i * 4 + 1]!;
      const flags = sim.state[i * 4 + 2]!;
      if (g > 0) lit++;
      else dark++;
      if (flags & FLAG_IS_HEAD) heads++;
    }

    expect(lit).toBeGreaterThan(0); // rain is falling
    expect(dark).toBeGreaterThan(0); // screen stays mostly black — gaps exist
    expect(heads).toBeGreaterThanOrEqual(1);
    expect(heads).toBeLessThanOrEqual(sim.cols); // at most one head per column
  });

  it("keeps the screen mostly dark (rain is a minority)", () => {
    const sim = makeSim(40, 60);
    sim.warmUp(CONTROLS, 4);
    let lit = 0;
    const total = sim.cols * sim.rows;
    for (let i = 0; i < total; i++) if (sim.state[i * 4 + 1]! > 0) lit++;
    expect(lit / total).toBeLessThan(0.6);
  });

  it("survives resize without throwing and keeps the state buffer sized correctly", () => {
    const sim = makeSim(20, 30);
    sim.warmUp(CONTROLS, 1);
    sim.resize(35, 50);
    expect(sim.cols).toBe(35);
    expect(sim.rows).toBe(50);
    expect(sim.state.length).toBe(35 * 50 * 4);
    sim.update(1 / 60, CONTROLS); // must not throw with new dimensions
  });
});

describe("RainSim.reset", () => {
  it("empties the grid (every state byte 0)", () => {
    const sim = makeSim(20, 30);
    sim.warmUp(CONTROLS, 4);
    let litBefore = 0;
    for (let i = 0; i < sim.cols * sim.rows; i++) if (sim.state[i * 4 + 1]! > 0) litBefore++;
    expect(litBefore).toBeGreaterThan(0); // precondition: rain is present

    sim.reset();
    expect(Array.from(sim.state).every((b) => b === 0)).toBe(true);
  });

  it("matches a freshly constructed sim's empty state", () => {
    const a = makeSim(16, 24, 999);
    a.warmUp(CONTROLS, 1);
    a.reset();
    const fresh = makeSim(16, 24, 999);
    expect(Array.from(a.state)).toEqual(Array.from(fresh.state));
  });

  it("resumes producing rain after reset", () => {
    const sim = makeSim(20, 30);
    sim.warmUp(CONTROLS, 4);
    sim.reset();
    sim.warmUp(CONTROLS, 4);
    let lit = 0;
    for (let i = 0; i < sim.cols * sim.rows; i++) if (sim.state[i * 4 + 1]! > 0) lit++;
    expect(lit).toBeGreaterThan(0);
  });
});

describe("RainSim.spawnRateScale", () => {
  const litFrac = (s: RainSim): number => {
    let n = 0;
    for (let i = 0; i < s.cols * s.rows; i++) if (s.state[i * 4 + 1]! > 0) n++;
    return n / (s.cols * s.rows);
  };

  it("defaults to full spawn rate", () => {
    expect(makeSim().spawnRateScale).toBe(1);
  });

  it("produces no rain at all when zero", () => {
    const sim = makeSim(60, 50);
    sim.spawnRateScale = 0;
    for (let i = 0; i < 1500; i++) sim.update(1 / 60, CONTROLS);
    expect(litFrac(sim)).toBe(0);
  });

  it("makes rain sparser at a low spawn rate, but still present", () => {
    // Time-average the coverage over a long window: an empty start makes the first cohort of streams
    // fall and clear in lockstep, so a single-frame snapshot is noisy — the average is representative.
    const meanLit = (scale: number): number => {
      const s = makeSim(60, 50);
      s.spawnRateScale = scale;
      let sum = 0, n = 0;
      for (let i = 0; i < 1800; i++) {
        s.update(1 / 60, CONTROLS);
        if (i >= 900) { sum += litFrac(s); n++; }
      }
      return sum / n;
    };
    const slow = meanLit(0.25);
    expect(slow).toBeGreaterThan(0);
    expect(slow).toBeLessThan(meanLit(1));
  });

  it("builds up uniformly across the screen — no left-to-right sweep", () => {
    // The defining property of the spawn-rate ramp: at a partial scale the rain is spread evenly,
    // unlike the old column cap which opened columns in index order (left edge filled first).
    const sim = makeSim(80, 50);
    const half = sim.cols >> 1;
    for (let i = 0; i < 1200; i++) {
      sim.spawnRateScale = 0.4;
      sim.update(1 / 60, CONTROLS);
    }
    let left = 0, right = 0;
    for (let r = 0; r < sim.rows; r++) {
      for (let c = 0; c < sim.cols; c++) {
        if (sim.state[(r * sim.cols + c) * 4 + 1]! > 0) c < half ? left++ : right++;
      }
    }
    expect(left).toBeGreaterThan(0);
    expect(right).toBeGreaterThan(0);
    expect(Math.min(left, right) / Math.max(left, right)).toBeGreaterThan(0.65); // halves lit comparably
  });

  it("fills in monotonically as the spawn rate ramps 0→1", () => {
    const sim = makeSim(60, 50);
    const dt = 1 / 60, rampS = 10;
    const at: Record<number, number> = {};
    for (let i = 0; i <= Math.round(rampS / dt); i++) {
      const t = i * dt;
      sim.spawnRateScale = Math.min(t / rampS, 1);
      sim.update(dt, CONTROLS);
      const sec = Math.round(t);
      if (Math.abs(t - sec) < dt / 2) at[sec] = litFrac(sim);
    }
    expect(at[3]!).toBeGreaterThan(0);
    expect(at[5]!).toBeGreaterThan(at[3]!);
    expect(at[8]!).toBeGreaterThan(at[5]!);
  });
});

describe("density drives concurrent streams per column", () => {
  const headsPerColumn = (s: RainSim): number[] => {
    const counts = new Array<number>(s.cols).fill(0);
    for (let r = 0; r < s.rows; r++) {
      for (let c = 0; c < s.cols; c++) {
        if (s.state[(r * s.cols + c) * 4 + 2]! & FLAG_IS_HEAD) counts[c]!++;
      }
    }
    return counts;
  };

  const litFrac = (s: RainSim): number => {
    let n = 0;
    for (let i = 0; i < s.cols * s.rows; i++) if (s.state[i * 4 + 1]! > 0) n++;
    return n / (s.cols * s.rows);
  };

  it("keeps at most one head per column at density 1", () => {
    const sim = makeSim(30, 50);
    let maxPerCol = 0;
    for (let i = 0; i < 2000; i++) {
      sim.update(1 / 60, { ...CONTROLS, density: 1 });
      maxPerCol = Math.max(maxPerCol, ...headsPerColumn(sim));
    }
    expect(maxPerCol).toBe(1);
  });

  it("allows multiple simultaneous heads in a single column at high density", () => {
    const sim = makeSim(30, 50);
    let maxPerCol = 0;
    for (let i = 0; i < 3000; i++) {
      sim.update(1 / 60, { ...CONTROLS, density: 20 });
      maxPerCol = Math.max(maxPerCol, ...headsPerColumn(sim));
    }
    expect(maxPerCol).toBeGreaterThan(1);
  });

  it("produces visibly denser rain as density rises", () => {
    const sparse = makeSim(40, 60);
    const dense = makeSim(40, 60);
    for (let i = 0; i < 1800; i++) {
      sparse.update(1 / 60, { ...CONTROLS, density: 1 });
      dense.update(1 / 60, { ...CONTROLS, density: 30 });
    }
    expect(litFrac(dense)).toBeGreaterThan(litFrac(sparse) * 1.5);
  });
});

describe("glyphRate scales how often trail glyphs mutate", () => {
  // A trail mutation resets the cell's crossfade phase to 0, whereas a head light sets phase to 1, so a
  // lit, non-head cell still mid-crossfade (phase < 1) is unambiguous evidence of a trail mutation.
  const mutationActivity = (controls: Controls, frames = 1200, seed = 4242): number => {
    const sim = makeSim(40, 60, seed);
    let count = 0;
    for (let f = 0; f < frames; f++) {
      sim.update(1 / 60, controls);
      for (let idx = 0; idx < sim.cols * sim.rows; idx++) {
        const o = idx * 4;
        const flags = sim.state[o + 2]!;
        const lit = sim.state[o + 1]! > 12; // brightness > ~0.05, the mutation threshold
        if (lit && (flags & FLAG_IS_HEAD) === 0 && (flags & PHASE_MASK) < PHASE_MASK) count++;
      }
    }
    return count;
  };

  it("never mutates trail glyphs when glyphRate is 0 (only head passes change them)", () => {
    expect(mutationActivity({ ...CONTROLS, glyphRate: 0 })).toBe(0);
  });

  it("mutates trail glyphs more often as glyphRate rises", () => {
    const slow = mutationActivity({ ...CONTROLS, glyphRate: 0.5 });
    const fast = mutationActivity({ ...CONTROLS, glyphRate: 3 });
    expect(fast).toBeGreaterThan(slow * 1.5);
  });
});

describe("RainSim — message injection", () => {
  const DENSE: Controls = { ...CONTROLS, density: 6 };
  const FLOOR255 = Math.round(DEFAULT_SIM_CONFIG.messageBrightFloor * 255);
  // Dedicated message-charset glyph indices (99+) are never produced by the random rain,
  // so seeing one in a cell unambiguously proves the message pinned it.
  const MSG_GLYPHS = [99, 100, 101, 102, 103];

  const rowTargets = (sim: RainSim, row: number, startCol: number, glyphs: number[]): Map<number, number> => {
    const t = new Map<number, number>();
    glyphs.forEach((g, i) => t.set(row * sim.cols + (startCol + i), g));
    return t;
  };
  const glyphAt = (s: RainSim, col: number, row: number): number => s.state[(row * s.cols + col) * 4]!;
  const brightAt = (s: RainSim, col: number, row: number): number => s.state[(row * s.cols + col) * 4 + 1]!;

  it("reveals message glyphs where rain falls and holds them at the brightness floor", () => {
    const sim = makeSim(16, 40);
    const row = 20, start = 2;
    sim.setMessageTargets(rowTargets(sim, row, start, MSG_GLYPHS));
    for (let i = 0; i < 2500; i++) sim.update(1 / 60, DENSE);
    let held = 0;
    MSG_GLYPHS.forEach((g, i) => {
      if (glyphAt(sim, start + i, row) === g && brightAt(sim, start + i, row) >= FLOOR255 - 1) held++;
    });
    expect(held).toBe(MSG_GLYPHS.length);
  });

  it("never reveals a letter in a column with no rain (no fabrication)", () => {
    const sim = makeSim(16, 40);
    sim.spawnRateScale = 0; // spawn rate zero → no rain at all
    const row = 20, start = 2;
    sim.setMessageTargets(rowTargets(sim, row, start, MSG_GLYPHS));
    for (let i = 0; i < 1000; i++) sim.update(1 / 60, DENSE);
    MSG_GLYPHS.forEach((_g, i) => {
      expect(brightAt(sim, start + i, row)).toBe(0);
      expect(glyphAt(sim, start + i, row)).toBe(0);
    });
  });

  it("pins a revealed letter steadily, then releases it to mutate after clear", () => {
    const sim = makeSim(16, 40);
    const row = 20, start = 2;
    sim.setMessageTargets(rowTargets(sim, row, start, MSG_GLYPHS));
    for (let i = 0; i < 1500; i++) sim.update(1 / 60, DENSE);
    MSG_GLYPHS.forEach((g, i) => expect(glyphAt(sim, start + i, row)).toBe(g));

    // While active, the letters stay pinned for many frames.
    let pinnedAlways = true;
    for (let i = 0; i < 300; i++) {
      sim.update(1 / 60, DENSE);
      MSG_GLYPHS.forEach((g, j) => { if (glyphAt(sim, start + j, row) !== g) pinnedAlways = false; });
    }
    expect(pinnedAlways).toBe(true);

    // After clearing, the cells are freed and the rain mutates them away from the letter.
    sim.clearMessageTargets();
    let sawNonLetter = false;
    for (let i = 0; i < 600; i++) {
      sim.update(1 / 60, DENSE);
      MSG_GLYPHS.forEach((g, j) => { if (glyphAt(sim, start + j, row) !== g) sawNonLetter = true; });
    }
    expect(sawNonLetter).toBe(true);
  });

  it("leaves every non-target cell byte-identical to a no-message sim (rng-preserving)", () => {
    const plain = makeSim(20, 40, 4242);
    const withMsg = makeSim(20, 40, 4242);
    const targets = rowTargets(withMsg, 10, 5, MSG_GLYPHS);
    withMsg.setMessageTargets(targets);
    for (let i = 0; i < 300; i++) {
      plain.update(1 / 60, DENSE);
      withMsg.update(1 / 60, DENSE);
    }
    for (let idx = 0; idx < withMsg.cols * withMsg.rows; idx++) {
      if (targets.has(idx)) continue;
      for (let k = 0; k < 4; k++) {
        expect(withMsg.state[idx * 4 + k]).toBe(plain.state[idx * 4 + k]);
      }
    }
  });

  it("is deterministic for a given seed and target set", () => {
    const a = makeSim(20, 40, 77);
    const b = makeSim(20, 40, 77);
    a.setMessageTargets(rowTargets(a, 10, 4, MSG_GLYPHS));
    b.setMessageTargets(rowTargets(b, 10, 4, MSG_GLYPHS));
    for (let i = 0; i < 400; i++) { a.update(1 / 60, DENSE); b.update(1 / 60, DENSE); }
    expect(Array.from(a.state)).toEqual(Array.from(b.state));
  });

  it("clears targets on reset and resize", () => {
    const sim = makeSim(16, 40);
    sim.setMessageTargets(rowTargets(sim, 20, 2, MSG_GLYPHS));
    expect(sim.hasMessageTargets()).toBe(true);
    sim.reset();
    expect(sim.hasMessageTargets()).toBe(false);

    const sim2 = makeSim(16, 40);
    sim2.setMessageTargets(rowTargets(sim2, 20, 2, MSG_GLYPHS));
    sim2.resize(30, 50);
    expect(sim2.hasMessageTargets()).toBe(false);
  });

  it("ignores out-of-range target indices without throwing", () => {
    const sim = makeSim(8, 8);
    sim.setMessageTargets(new Map<number, number>([[5, 99], [99999, 100], [-3, 101]]));
    for (let i = 0; i < 200; i++) sim.update(1 / 60, DENSE);
    expect(sim.hasMessageTargets()).toBe(true);
  });

  it("the fade intensity dims a held message and never brightens it", () => {
    // Intensity is display-only (it doesn't touch `bright` or the rng), so two identically-seeded
    // sims evolve the same rain; only the packed brightness of held message cells differs.
    const full = makeSim(16, 40, 555);
    const faded = makeSim(16, 40, 555);
    full.setMessageTargets(rowTargets(full, 20, 2, MSG_GLYPHS));
    faded.setMessageTargets(rowTargets(faded, 20, 2, MSG_GLYPHS));
    let sumFull = 0, sumFaded = 0;
    for (let i = 0; i < 1500; i++) {
      full.update(1 / 60, DENSE);
      faded.setMessageIntensity(0.3);
      faded.update(1 / 60, DENSE);
      MSG_GLYPHS.forEach((_g, j) => {
        const bf = brightAt(full, 2 + j, 20);
        const bd = brightAt(faded, 2 + j, 20);
        expect(bd).toBeLessThanOrEqual(bf); // a lower intensity is never brighter
        sumFull += bf;
        sumFaded += bd;
      });
    }
    expect(sumFaded).toBeLessThan(sumFull); // and is dimmer overall
  });

  it("scrambles message cells back to random glyphs when scramble is high", () => {
    const sim = makeSim(16, 40);
    const row = 20, start = 2;
    sim.setMessageTargets(rowTargets(sim, row, start, MSG_GLYPHS));
    for (let i = 0; i < 1500; i++) sim.update(1 / 60, DENSE); // reveal & hold; scramble 0 → letters pinned
    MSG_GLYPHS.forEach((g, i) => expect(glyphAt(sim, start + i, row)).toBe(g));

    // Full scramble: every head/mutation roll picks a random glyph, so the letters flicker away.
    sim.setMessageScramble(1);
    let sawRandom = false;
    for (let i = 0; i < 300; i++) {
      sim.update(1 / 60, DENSE);
      MSG_GLYPHS.forEach((g, j) => { if (glyphAt(sim, start + j, row) !== g) sawRandom = true; });
    }
    expect(sawRandom).toBe(true);
  });
});
