import { describe, it, expect } from "vitest";
import { RainSim, packCell, unpackCell, decayBrightness } from "../src/sim/rainSim.ts";
import { createGlyphSet } from "../src/sim/glyphSet.ts";
import { DEFAULT_SIM_CONFIG } from "../src/config/simConfig.ts";
import { FLAG_IS_HEAD } from "../src/types.ts";
import type { Controls } from "../src/types.ts";

const CONTROLS: Controls = {
  speed: 1,
  trailLength: 0.08,
  density: 1,
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
    sim.warmUp(CONTROLS, 2);
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
    sim.warmUp(CONTROLS, 2);
    sim.reset();
    sim.warmUp(CONTROLS, 2);
    let lit = 0;
    for (let i = 0; i < sim.cols * sim.rows; i++) if (sim.state[i * 4 + 1]! > 0) lit++;
    expect(lit).toBeGreaterThan(0);
  });
});

describe("RainSim.activeColumnLimit", () => {
  const litFrac = (s: RainSim): number => {
    let n = 0;
    for (let i = 0; i < s.cols * s.rows; i++) if (s.state[i * 4 + 1]! > 0) n++;
    return n / (s.cols * s.rows);
  };

  it("defaults to no cap", () => {
    expect(makeSim().activeColumnLimit).toBe(Number.POSITIVE_INFINITY);
  });

  it("never lets more columns rain than the limit", () => {
    const sim = makeSim(60, 50);
    sim.activeColumnLimit = 5;
    let maxHeads = 0;
    for (let i = 0; i < 1500; i++) {
      sim.update(1 / 60, CONTROLS);
      let heads = 0;
      for (let j = 0; j < sim.cols * sim.rows; j++) if (sim.state[j * 4 + 2]! & FLAG_IS_HEAD) heads++;
      if (heads > maxHeads) maxHeads = heads;
    }
    // A head only appears for an active column whose head is on-screen, so heads <= active <= limit.
    expect(maxHeads).toBeGreaterThan(0);
    expect(maxHeads).toBeLessThanOrEqual(5);
  });

  it("makes rain sparser with a low limit, but still present", () => {
    const capped = makeSim(60, 50);
    capped.activeColumnLimit = 6;
    const full = makeSim(60, 50);
    for (let i = 0; i < 600; i++) {
      capped.update(1 / 60, CONTROLS);
      full.update(1 / 60, CONTROLS);
    }
    expect(litFrac(capped)).toBeGreaterThan(0);
    expect(litFrac(capped)).toBeLessThan(litFrac(full));
  });

  it("fills in roughly monotonically as the limit ramps up (no late burst)", () => {
    // Reproduces the user-facing intent: ramping the column limit 0→full over 10s should
    // produce a gradual build, unlike scaling spawn probability (which stayed ~empty then surged).
    const sim = makeSim(60, 50);
    const dt = 1 / 60;
    const rampS = 10;
    const at: Record<number, number> = {};
    for (let i = 0; i <= Math.round(rampS / dt); i++) {
      const t = i * dt;
      const f = Math.min(t / rampS, 1);
      sim.activeColumnLimit = f >= 1 ? Number.POSITIVE_INFINITY : Math.ceil(f * sim.cols);
      sim.update(dt, CONTROLS);
      const sec = Math.round(t);
      if (Math.abs(t - sec) < dt / 2) at[sec] = litFrac(sim);
    }
    // Visible rain well before the end of the ramp (the old density-scaling bug showed ~0% here).
    expect(at[3]!).toBeGreaterThan(0.015);
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
    sim.activeColumnLimit = 0; // no column ever opens → no rain at all
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
});
