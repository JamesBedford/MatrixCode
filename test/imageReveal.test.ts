import { describe, expect, it } from "vitest";
import {
  imageCellIdentity,
  imageFallingGate,
  imageRevealGeometry,
  imageSignal,
  sampleImageMask,
} from "../src/sim/imageReveal.ts";
import type { ActiveImageFrame } from "../src/sim/imageScheduler.ts";
import type { ImagesDoc } from "../src/types.ts";

const frame: ActiveImageFrame = {
  image: { name: "wide", width: 2, height: 1, data: "AP8=" },
  mask: new Uint8Array([0, 255]),
  intensity: 1,
  scramble: 0,
  placementX: 0,
  placementY: 1,
  rainElapsed: 2,
  animationBucket: 36,
};
const doc: ImagesDoc = {
  images: [frame.image], enabled: true, frequencyMs: 1000, persistenceMs: 1000,
  appearMs: 0, disappearMs: 0, flickerOut: true, brightnessFade: false,
  imageScale: 0.5, imagePlacementJitter: 1,
};

describe("image reveal reference", () => {
  it("fits and jitters inside the full virtual grid", () => {
    expect(imageRevealGeometry(frame, doc, 100, 40)).toEqual({
      originCol: 0,
      originRow: 15,
      cols: 50,
      rows: 25,
    });
  });

  it("samples masks bilinearly in top-to-bottom row order", () => {
    expect(sampleImageMask(new Uint8Array([0, 255, 255, 0]), 2, 2, 0, 0)).toBe(0);
    expect(sampleImageMask(new Uint8Array([0, 255, 255, 0]), 2, 2, 0.5, 0.5)).toBeCloseTo(0.5);
  });

  it("extends each border and corner without changing the fitted image size", () => {
    const mask = new Uint8Array([0, 64, 128, 255]);
    for (const [u, v, expected] of [
      [-2, 0.25, 32], [3, 0.25, 111.75],
      [0.25, -2, 16], [0.25, 3, 159.75],
      [-2, -2, 0], [3, -2, 64], [-2, 3, 128], [3, 3, 255],
    ] as const) {
      expect(sampleImageMask(mask, 2, 2, u, v)).toBeCloseTo(expected / 255, 8);
    }
    expect(sampleImageMask(mask, 2, 2, -1e-8, 0.5)).toBeCloseTo(
      sampleImageMask(mask, 2, 2, 1e-8, 0.5), 7,
    );
  });

  it("extends a single pixel uniformly over the whole grid", () => {
    for (const [u, v] of [[-10, -10], [0.5, 0.5], [10, 10]] as const) {
      expect(sampleImageMask(new Uint8Array([60]), 1, 1, u, v)).toBe(60 / 255);
    }
  });

  it("rejects malformed masks and non-finite coordinates", () => {
    const mask = new Uint8Array([0, 64, 128, 255]);
    expect(sampleImageMask(mask, 0, 2, 0.5, 0.5)).toBe(0);
    expect(sampleImageMask(mask, 2, 3, 0.5, 0.5)).toBe(0);
    for (const value of [NaN, Infinity, -Infinity]) {
      expect(sampleImageMask(mask, 2, 2, value, 0.5)).toBe(0);
      expect(sampleImageMask(mask, 2, 2, 0.5, value)).toBe(0);
    }
  });

  it("keeps black border pixels active for darkening surrounding rain", () => {
    expect(imageSignal(0)).toBe(1);
    expect(imageSignal(0.08)).toBeCloseTo(0.84);
    expect(imageSignal(0.5)).toBeCloseTo(0.36);
    expect(imageSignal(1)).toBe(1);
    const black = new Uint8Array([0]);
    expect(imageSignal(sampleImageMask(black, 1, 1, -10, 10))).toBe(1);
  });

  it("locks deterministic cell and falling-wave values", () => {
    expect(imageCellIdentity(0x1a2b3c, 12, 8)).toBe(1316630523);
    expect(imageFallingGate(12, 8, 2.5, 0x1a2b3c)).toBeCloseTo(0.0509755093, 8);
  });
});
