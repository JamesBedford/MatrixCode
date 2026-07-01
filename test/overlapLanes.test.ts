import { describe, it, expect } from "vitest";
import {
  computeLanes,
  vanDerCorput,
  seedForLayer,
  tierCap,
  OVERLAP_ONSET_DENSITY,
  MAX_LANES,
  type Lane,
} from "../src/sim/overlapLanes.ts";

const HIGH = tierCap("high"); // 8

const offsets = (lanes: Lane[]): number[] => lanes.map((l) => l.offset).sort((a, b) => a - b);
const evenlySpaced = (xs: number[]): boolean => {
  // xs already sorted; the first entry is 0 (the base column) and the pitch is 1/xs.length.
  const pitch = 1 / xs.length;
  return xs.every((x, i) => Math.abs(x - i * pitch) < 1e-9);
};

describe("vanDerCorput", () => {
  it("produces the base-2 radical inverse (bisection order)", () => {
    const expected = [0, 0.5, 0.25, 0.75, 0.125, 0.625, 0.375, 0.875];
    expected.forEach((v, i) => expect(vanDerCorput(i)).toBeCloseTo(v, 12));
  });

  it("the first 2^k values are the evenly-spaced k-bit fractions", () => {
    for (const k of [1, 2, 3]) {
      const n = 2 ** k;
      const xs = Array.from({ length: n }, (_, i) => vanDerCorput(i)).sort((a, b) => a - b);
      expect(evenlySpaced(xs)).toBe(true);
    }
  });
});

describe("seedForLayer", () => {
  it("returns the base seed unchanged for layer 0", () => {
    expect(seedForLayer(0x1a2b3c, 0)).toBe(0x1a2b3c);
  });

  it("gives every layer a distinct seed", () => {
    const seeds = new Set<number>();
    for (let i = 0; i < MAX_LANES; i++) seeds.add(seedForLayer(0x1a2b3c, i));
    expect(seeds.size).toBe(MAX_LANES);
  });
});

describe("tierCap", () => {
  it("caps lanes per quality tier (powers of two)", () => {
    expect(tierCap("low")).toBe(2);
    expect(tierCap("med")).toBe(4);
    expect(tierCap("high")).toBe(8);
  });
});

describe("computeLanes", () => {
  it("returns a single base lane fed the raw density when overlap is off, at every density", () => {
    for (const d of [2, 20, 50, 100]) {
      const lanes = computeLanes(d, false, HIGH);
      expect(lanes).toHaveLength(1);
      expect(lanes[0]).toMatchObject({ index: 0, offset: 0, density: d, weight: 1 });
    }
  });

  it("returns a single base lane fed the raw density at or below the onset (today's behaviour)", () => {
    for (const d of [0.5, 2, 10, OVERLAP_ONSET_DENSITY]) {
      const lanes = computeLanes(d, true, HIGH);
      expect(lanes).toHaveLength(1);
      expect(lanes[0]).toMatchObject({ index: 0, offset: 0, density: d, weight: 1 });
    }
  });

  it("default density (2) with overlap on is exactly one base lane at its raw density (byte-identical base)", () => {
    expect(computeLanes(2, true, HIGH)).toEqual([{ index: 0, offset: 0, density: 2, weight: 1 }]);
  });

  it("above the onset, the base lane pins at the onset density and extra lanes appear", () => {
    const lanes = computeLanes(40, true, HIGH);
    expect(lanes[0]).toMatchObject({ index: 0, offset: 0, density: OVERLAP_ONSET_DENSITY, weight: 1 });
    expect(lanes.length).toBeGreaterThan(1);
    for (const l of lanes) expect(l.density).toBe(OVERLAP_ONSET_DENSITY);
  });

  it("the first inserted lane sits at the half offset (index 1.5)", () => {
    // Just past the onset: base + one fading half-offset lane.
    const lanes = computeLanes(OVERLAP_ONSET_DENSITY + 1, true, HIGH);
    expect(lanes).toHaveLength(2);
    expect(lanes[1]!.offset).toBeCloseTo(0.5, 12);
    expect(lanes[1]!.weight).toBeGreaterThan(0);
    expect(lanes[1]!.weight).toBeLessThan(1);
  });

  it("reaches the full lane count at each power-of-two level, always evenly spaced", () => {
    // level 1 → 2 lanes, level 2 → 4 lanes, level 3 → 8 lanes; onset+level*span/3.
    const span = 100 - OVERLAP_ONSET_DENSITY;
    const at = (level: number): Lane[] => computeLanes(OVERLAP_ONSET_DENSITY + (span * level) / 3, true, HIGH);
    expect(at(1)).toHaveLength(2);
    expect(at(2)).toHaveLength(4);
    expect(at(3)).toHaveLength(MAX_LANES);
    for (const level of [1, 2, 3]) {
      expect(evenlySpaced(offsets(at(level)))).toBe(true);
    }
  });

  it("reaches 8 evenly-spaced lanes at maximum density", () => {
    const lanes = computeLanes(100, true, HIGH);
    expect(lanes).toHaveLength(MAX_LANES);
    expect(evenlySpaced(offsets(lanes))).toBe(true);
  });

  it("total coverage weight is monotonic non-decreasing in density", () => {
    const total = (d: number): number => computeLanes(d, true, HIGH).reduce((s, l) => s + l.weight, 0);
    let prev = 0;
    for (let d = OVERLAP_ONSET_DENSITY; d <= 100; d += 1) {
      const t = total(d);
      expect(t).toBeGreaterThanOrEqual(prev - 1e-9);
      prev = t;
    }
  });

  it("respects the quality-tier cap, keeping the lowest (evenly-spaced) lanes", () => {
    expect(computeLanes(100, true, tierCap("low"))).toHaveLength(2);
    expect(computeLanes(100, true, tierCap("med"))).toHaveLength(4);
    expect(computeLanes(100, true, tierCap("high"))).toHaveLength(8);
    // The kept subset is still an evenly-spaced set.
    expect(evenlySpaced(offsets(computeLanes(100, true, tierCap("med"))))).toBe(true);
  });

  it("never exceeds MAX_LANES and always includes the base column", () => {
    for (let d = 0.5; d <= 100; d += 0.7) {
      const lanes = computeLanes(d, true, HIGH);
      expect(lanes.length).toBeLessThanOrEqual(MAX_LANES);
      expect(lanes[0]!.index).toBe(0);
      expect(lanes[0]!.offset).toBe(0);
    }
  });
});
