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
