import { describe, it, expect } from "vitest";
import { densityRampFactor, loadRampMs } from "../src/sim/introRain.ts";

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
