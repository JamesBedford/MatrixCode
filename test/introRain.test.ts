import { describe, it, expect } from "vitest";
import { densityRampFactor, loadRampMs, rampEase } from "../src/sim/introRain.ts";

describe("densityRampFactor", () => {
  it("is 0 before the rain starts", () => {
    expect(densityRampFactor(100, 200, 5000)).toBe(0);
  });

  it("is 0 exactly at the start when there is a ramp", () => {
    expect(densityRampFactor(200, 200, 1000)).toBe(0);
  });

  it("is 1 immediately when there is no ramp", () => {
    expect(densityRampFactor(200, 200, 0)).toBe(1);
    expect(densityRampFactor(5000, 200, 0)).toBe(1);
  });

  it("is linear across the ramp", () => {
    expect(densityRampFactor(200 + 250, 200, 1000)).toBeCloseTo(0.25, 6);
    expect(densityRampFactor(200 + 500, 200, 1000)).toBeCloseTo(0.5, 6);
  });

  it("clamps to 1 past the end of the ramp", () => {
    expect(densityRampFactor(200 + 2000, 200, 1000)).toBe(1);
  });

  it("treats a -Infinity start as already running at full", () => {
    expect(densityRampFactor(0, Number.NEGATIVE_INFINITY, 0)).toBe(1);
    expect(densityRampFactor(0, Number.NEGATIVE_INFINITY, 5000)).toBe(1);
  });
});

describe("loadRampMs", () => {
  it("is 0 on a first visit, regardless of the configured ramp", () => {
    expect(loadRampMs(false, 5000, false)).toBe(0);
  });

  it("is 0 under reduced motion", () => {
    expect(loadRampMs(true, 5000, true)).toBe(0);
  });

  it("is 0 when the configured ramp is zero or negative", () => {
    expect(loadRampMs(true, 0, false)).toBe(0);
    expect(loadRampMs(true, -1, false)).toBe(0);
  });

  it("is the configured ramp on a repeat visit with motion allowed", () => {
    expect(loadRampMs(true, 5000, false)).toBe(5000);
  });
});

describe("rampEase", () => {
  it("pins the endpoints", () => {
    expect(rampEase(0)).toBe(0);
    expect(rampEase(1)).toBe(1);
    expect(rampEase(-1)).toBe(0);
    expect(rampEase(2)).toBe(1);
  });

  it("is the identity when edge is 0", () => {
    for (const p of [0.1, 0.37, 0.5, 0.8]) expect(rampEase(p, 0)).toBeCloseTo(p, 9);
  });

  it("eases in — the start rises slower than linear", () => {
    expect(rampEase(0.1, 0.2)).toBeLessThan(0.1);
    expect(rampEase(0.05, 0.2)).toBeLessThan(0.05);
  });

  it("eases out — the end rises slower than linear (approaches 1 gently)", () => {
    expect(rampEase(0.9, 0.2)).toBeGreaterThan(0.9);
    expect(rampEase(0.95, 0.2)).toBeGreaterThan(0.95);
  });

  it("is linear through the middle (constant slope between the eased ends)", () => {
    const s1 = rampEase(0.45, 0.2) - rampEase(0.35, 0.2);
    const s2 = rampEase(0.65, 0.2) - rampEase(0.55, 0.2);
    expect(s1).toBeCloseTo(s2, 9);
    expect(rampEase(0.5, 0.2)).toBeCloseTo(0.5, 9);
  });

  it("is symmetric: rampEase(p) + rampEase(1 - p) === 1", () => {
    for (const p of [0.05, 0.2, 0.33, 0.5]) expect(rampEase(p, 0.2) + rampEase(1 - p, 0.2)).toBeCloseTo(1, 9);
  });

  it("is monotonic and stays within [0,1]", () => {
    let prev = -1;
    for (let i = 0; i <= 100; i++) {
      const y = rampEase(i / 100, 0.2);
      expect(y).toBeGreaterThanOrEqual(0);
      expect(y).toBeLessThanOrEqual(1);
      expect(y).toBeGreaterThanOrEqual(prev);
      prev = y;
    }
  });
});
