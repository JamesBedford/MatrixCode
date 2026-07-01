import { describe, it, expect } from "vitest";
import { RainSim } from "../src/sim/rainSim.ts";
import { createGlyphSet } from "../src/sim/glyphSet.ts";
import { DEFAULT_SIM_CONFIG } from "../src/config/simConfig.ts";
import { OVERLAP_ONSET_DENSITY } from "../src/sim/overlapLanes.ts";
import { DEFAULT_CONTROLS } from "../src/config/controls.ts";
import type { Controls } from "../src/types.ts";

// Measures, from the headless sim, the density at which every column is continuously occupied
// (never fully dark) — the "every column always has a raindrop" point the feature reports to the
// user. It also confirms the overlap onset (20) sits comfortably past that saturation point.
// Uses the real default trail/speed so the number reflects what a viewer actually sees.

const glyphSet = createGlyphSet();
const BASE: Controls = { ...DEFAULT_CONTROLS };

function makeSim(cols: number, rows: number, seed: number): RainSim {
  return new RainSim({ cols, rows, config: DEFAULT_SIM_CONFIG, glyphSet, seed });
}

// Threshold below which the screen reads as "every column basically always has rain": on average
// fewer than 2% of columns are fully dark in any frame. (The gap fraction asymptotes to ~1% rather
// than hitting exactly 0 — long trails plus random spawning always leave rare transient gaps.)
const SATURATION_THRESHOLD = 0.02;

/**
 * Mean over frames (after warm-up) of the fraction of columns that are fully dark (every cell's
 * brightness byte 0). 0 => the rain is perfectly continuous; higher => more visible vertical gaps.
 */
function meanDarkColumnFraction(density: number, cols: number, rows: number, seed: number, frames = 600): number {
  const controls: Controls = { ...BASE, density };
  const sim = makeSim(cols, rows, seed);
  sim.warmUp(controls, 3);
  let sum = 0;
  for (let f = 0; f < frames; f++) {
    sim.update(1 / 60, controls);
    let dark = 0;
    for (let c = 0; c < cols; c++) {
      let colDark = true;
      for (let r = 0; r < rows; r++) {
        if (sim.state[(r * cols + c) * 4 + 1]! > 0) {
          colDark = false;
          break;
        }
      }
      if (colDark) dark++;
    }
    sum += dark / cols;
  }
  return sum / frames;
}

describe("saturation density (every column continuously occupied)", () => {
  const sizes: ReadonlyArray<readonly [number, number]> = [
    [40, 40],
    [40, 60],
    [40, 80],
  ];
  const seeds = [0xc0ffee, 0x1234abc];
  // Averaged over grid sizes and seeds to smooth the (inherently noisy) rare-gap statistics.
  const avgDarkFraction = (d: number): number => {
    let sum = 0;
    let n = 0;
    for (const [cols, rows] of sizes) {
      for (const s of seeds) {
        sum += meanDarkColumnFraction(d, cols, rows, s + d, 700);
        n++;
      }
    }
    return sum / n;
  };

  it("is well below the overlap onset, and the base is essentially full at the onset", () => {
    const results: { d: number; frac: number }[] = [];
    let saturation = Infinity;
    for (let d = 3; d <= 20; d += 1) {
      const frac = avgDarkFraction(d);
      results.push({ d, frac });
      if (frac < SATURATION_THRESHOLD && saturation === Infinity) saturation = d;
    }
    // eslint-disable-next-line no-console
    console.log("[saturation] mean dark-column fraction by density:", results.map((r) => `${r.d}:${r.frac.toFixed(3)}`).join(" "));
    // eslint-disable-next-line no-console
    console.log(`[saturation] every column visibly full (< ${SATURATION_THRESHOLD * 100}% gaps) from density ~= ${saturation}`);

    expect(Number.isFinite(saturation)).toBe(true);
    expect(saturation).toBeLessThan(OVERLAP_ONSET_DENSITY);
    // The base layer, pinned at the overlap onset, is essentially gap-free and far fuller than sparse rain.
    expect(results.find((r) => r.d === OVERLAP_ONSET_DENSITY)!.frac).toBeLessThan(SATURATION_THRESHOLD);
    expect(results.find((r) => r.d === OVERLAP_ONSET_DENSITY)!.frac).toBeLessThan(results.find((r) => r.d === 3)!.frac);
  }, 60000);
});
