import { describe, it, expect } from "vitest";
import { RainSim } from "../src/sim/rainSim.ts";
import { createGlyphSet } from "../src/sim/glyphSet.ts";
import { DEFAULT_SIM_CONFIG } from "../src/config/simConfig.ts";
import type { Controls } from "../src/types.ts";

// Golden / characterization tests: they pin the EXACT packed `state` bytes that a fixed
// deterministic scenario produces, so the CPU-side performance refactors (typed-array
// message overlay, cumulative weightedPick, index loops) can be proven byte-identical —
// any divergence flips the checksum. The constants were captured from the pre-refactor
// implementation.

const CONTROLS: Controls = {
  speed: 1,
  trailLength: 0.08,
  density: 1,
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
const DENSE: Controls = { ...CONTROLS, density: 6 };

function makeSim(cols = 24, rows = 40, seed = 12345): RainSim {
  return new RainSim({ cols, rows, config: DEFAULT_SIM_CONFIG, glyphSet: createGlyphSet(), seed });
}

/** FNV-1a 32-bit checksum over the whole packed state buffer. */
function checksum(bytes: Uint8Array): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) {
    h ^= bytes[i]!;
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

describe("RainSim golden output (locks byte-exact packing across perf refactors)", () => {
  it("pure rain, no message", () => {
    const sim = makeSim(40, 60, 0xc0ffee);
    sim.warmUp(DENSE, 3);
    for (let i = 0; i < 300; i++) sim.update(1 / 60, DENSE);
    expect(checksum(sim.state)).toBe(3658668035);
  });

  it("active message with intensity fade and flicker scramble", () => {
    const sim = makeSim(24, 40, 12345);
    sim.warmUp(DENSE, 2);
    const row = 20;
    const targets = new Map<number, number>();
    [99, 100, 101, 102, 103].forEach((g, i) => targets.set(row * sim.cols + (3 + i), g));
    sim.setMessageTargets(targets);
    for (let i = 0; i < 250; i++) {
      sim.setMessageIntensity(0.6);
      sim.setMessageScramble(0.3);
      sim.update(1 / 60, DENSE);
    }
    expect(checksum(sim.state)).toBe(597106857);
  });
});
