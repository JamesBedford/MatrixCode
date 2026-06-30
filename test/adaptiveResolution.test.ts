import { describe, it, expect } from "vitest";
import { AdaptiveResolution, type AdaptiveResolutionConfig } from "../src/gl/adaptiveResolution.ts";

// Fast config so trajectories converge within a few frames in tests.
const CFG: AdaptiveResolutionConfig = {
  targetMs: 16.67,
  minScale: 0.5,
  step: 0.1,
  emaAlpha: 0.5,
  upHeadroom: 0.6, // scale up only when ema < ~10ms
  downThreshold: 1.15, // scale down when ema > ~19.2ms
  cooldownFrames: 1,
  warmFrames: 1,
};

const feed = (ar: AdaptiveResolution, frameMs: number, n: number): void => {
  for (let i = 0; i < n; i++) ar.update(frameMs);
};

describe("AdaptiveResolution", () => {
  it("starts at full scale", () => {
    expect(new AdaptiveResolution(CFG).value).toBe(1);
  });

  it("scales down under sustained slow frames", () => {
    const ar = new AdaptiveResolution(CFG);
    feed(ar, 40, 100);
    expect(ar.value).toBeLessThan(1);
  });

  it("never scales below minScale", () => {
    const ar = new AdaptiveResolution(CFG);
    feed(ar, 100, 200);
    expect(ar.value).toBeGreaterThanOrEqual(CFG.minScale - 1e-9);
    expect(ar.value).toBeCloseTo(CFG.minScale, 5);
  });

  it("never exceeds full scale on fast frames", () => {
    const ar = new AdaptiveResolution(CFG);
    feed(ar, 4, 100);
    expect(ar.value).toBe(1);
  });

  it("recovers toward full scale when load drops", () => {
    const ar = new AdaptiveResolution(CFG);
    feed(ar, 40, 100); // drive it down
    const low = ar.value;
    expect(low).toBeLessThan(1);
    feed(ar, 3, 200); // load lifts
    expect(ar.value).toBeGreaterThan(low);
    expect(ar.value).toBe(1);
  });

  it("holds steady in the dead zone (frames near target)", () => {
    const ar = new AdaptiveResolution(CFG);
    feed(ar, 16.67, 100); // between upHeadroom*target and downThreshold*target
    expect(ar.value).toBe(1);
  });

  it("ignores a single spike (does not crash to minScale)", () => {
    const ar = new AdaptiveResolution(CFG);
    feed(ar, 4, 50);
    ar.update(60); // one bad frame
    feed(ar, 4, 50);
    expect(ar.value).toBeGreaterThanOrEqual(1 - CFG.step - 1e-9); // at most one step down, then recovered
    expect(ar.value).toBe(1);
  });
});
